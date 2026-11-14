// Static file serving: static(), send_file(), the file cache and MIME types.

Static_Options :: struct {
  index_file     : string = "index.html";
  // when a path has no file extension and no such file exists, answer with
  // index_file instead of 404. This is what a single page app needs for client-side routes.
  spa_fallback   : bool   = false;
  // "no-cache" means: the browser may keep the file but must revalidate each time,
  // which is cheap thanks to the ETag (a 304 with no body). Use e.g. "public, max-age=3600" for assets.
  cache_control  : string = "no-cache";
  etag           : bool   = true;
  brotli         : bool   = true;
  brotli_quality : s32    = 5;     // 1 to 11. 11 is smallest but slow, bad while you rebuild often
  // files and folders whose name starts with a "." (.git, .env ...) are answered with 404 unless this is set
  allow_dotfiles : bool   = false;
}

cwd: string;
the_static_folder_to_serve: string;
static_options: Static_Options;

// Serves the files of `folder` (relative to the working directory, or absolute) for every GET
// that no earlier route answered, so call it after your routes.
static :: (folder: string, options: Static_Options = .{}) {
  assert(folder.count > 0, "folder to serve can't be an empty string");
  assert(the_static_folder_to_serve.count == 0, "you can't currently static serve more than 1 folder");

  cwd = copy_string(get_working_directory());
  the_static_folder_to_serve = copy_string(folder);
  static_options = options;

  get("*", static_handler);
}

static_handler :: (request: *Request) {
  options := static_options;

  // 1. decode, 2. resolve "." and "..", 3. refuse to leave the folder. In that order.
  decoded, decode_ok := percent_decode(request.path);
  if !decode_ok {
    send_error(request, 400, "Bad request.");
    return;
  }
  clean, status := clean_static_path(decoded, options.allow_dotfiles);
  if status == 403 { send_error(request, 403, "Forbidden path traversal."); return; }
  if status == 400 { send_error(request, 400, "Bad request."); return; }
  if status == 404 return; // hidden file: act as if it doesn't exist

  root := ifx begins_with(the_static_folder_to_serve, "/") then the_static_folder_to_serve else tjoin(cwd, "/", the_static_folder_to_serve);
  full := ifx clean.count > 0 then tjoin(root, "/", clean) else root;

  wants_folder := clean.count == 0 || ends_with(decoded, "/");
  if wants_folder full = tjoin(full, "/", options.index_file);

  info := stat_file(full); // the only stat of this request: serve_file gets it too
  if !wants_folder && info.is_dir {
    // /examples/hello -> /examples/hello/ , otherwise the relative URLs inside its index.html resolve against the wrong folder.
    // Built from the cleaned path, never from the raw one: "//host" must not become a redirect to another site.
    location := tjoin("/", clean, "/", ifx request.query.count > 0 then "?" else "", request.query);
    redirect(request, location, 301);
    return;
  }

  if serve_file(request, full, options, info) return;

  if options.spa_fallback {
    last_slash := find_index_from_right(decoded, #char "/");
    last_segment := substr(decoded, last_slash + 1, decoded.count - last_slash - 1);
    if find_index_from_left(last_segment, #char ".") == -1 {
      if serve_file(request, tjoin(root, "/", options.index_file), options) return;
    }
  }
  // not found: leave it to the 404 at the end of handle_request
}

// Sends a file from disk, with caching headers. `raw_filename` is a path chosen by
// YOUR code, so it is not checked against any folder. Never build it from request.path.
send_file :: (request: *Request, raw_filename: string) {
  serve_file(request, normalize_filename(raw_filename), static_options_or_defaults());
}

static_options_or_defaults :: () -> Static_Options {
  if the_static_folder_to_serve.count > 0 return static_options;
  return .{};
}

// returns false (and sends nothing) if the file can't be read
serve_file :: (request: *Request, filename: string, options: Static_Options, known: File_Stat = .{}) -> bool {
  record, success := file_cache_get(filename, options, known);
  if !success return false;

  content_type := extension2contenttype(filename);

  // Range: bytes=...  one range, of the file as it is: a ranged answer is never compressed
  range_kind  : s32;  // 0: no range, 1: send range_start to range_end, 2: not satisfiable
  range_start : s64;
  range_end   : s64;
  size := record.rawcontent.count;
  range_header, has_range := get_header(request, "range");
  if has_range {
    if_range, has_if_range := get_header(request, "if-range");
    if !has_if_range || (options.etag && if_range == record.etag)  range_kind, range_start, range_end = parse_range(range_header, size);
  }
  set_header(request, "Accept-Ranges", "bytes");

  // for very small files, it's possible that brotli encoding is longer than the raw content.
  // in that case there is no brotli version and we send the raw content, even though the client accepts br
  are_we_returning_br := range_kind == 0 && options.brotli && record.brotli.count > 0 && does_request_accept_encoding(request, "br");

  if options.etag {
    etag := ifx are_we_returning_br then record.etag_br else record.etag;
    set_header(request, "ETag", etag);
    set_header(request, "Vary", "Accept-Encoding");
    if options.cache_control.count > 0  set_header(request, "Cache-Control", options.cache_control);

    if_none_match, has_condition := get_header(request, "if-none-match");
    if has_condition && (if_none_match == "*" || contains(if_none_match, etag)) {
      send_empty(request, 304);
      return true;
    }
  } else {
    if options.cache_control.count > 0  set_header(request, "Cache-Control", options.cache_control);
  }

  if range_kind == 2 {
    set_header(request, "Content-Range", tprint("bytes */%", size));
    send_empty(request, 416);
    return true;
  }
  if range_kind == 1 {
    set_header(request, "Content-Range", tprint("bytes %-%/%", range_start, range_end, size));
    send_response(request, slice(record.rawcontent, range_start, range_end - range_start + 1), status_code = 206, content_type = content_type);
    return true;
  }

  content := ifx are_we_returning_br then record.brotli else record.rawcontent;
  content_encoding := ifx are_we_returning_br then "br" else "";
  send_response(request, content, content_type = content_type, content_encoding = content_encoding);
  return true;
}


// What static needs to know about a path, from ONE stat() call. It used to be two: is_directory() in
// static_handler and file_modtime_and_size() in file_cache_get(), each of them making a C string and freeing it.
File_Stat :: struct {
  known      : bool; // stat_file() was called: hand the result on, nobody has to ask again
  exists     : bool;
  is_dir     : bool;
  size       : s64;
  modtime_ms : s64;
}

#if OS == .LINUX {
  stat_file :: (path: string) -> File_Stat {
    result: File_Stat;
    result.known = true;
    if path.count == 0 || path.count >= 4096 return result;

    buffer: [4096] u8 = ---; // not zeroed: only the end is set
    memcpy(buffer.data, path.data, path.count);
    buffer[path.count] = 0;

    info: stat_t;
    if stat(buffer.data, *info) != 0 return result;

    result.exists     = true;
    result.is_dir     = S_ISDIR(info.st_mode);
    result.size       = info.st_size;
    result.modtime_ms = info.st_mtime.tv_sec * 1000 + info.st_mtime.tv_nsec / 1000000;
    return result;
  }
} else {
  stat_file :: (path: string) -> File_Stat {
    result: File_Stat;
    result.known = true;
    modtime, size, found := file_modtime_and_size(path);
    if !found return result;
    directory, _ := is_directory(path);
    result.exists     = true;
    result.is_dir     = directory;
    result.size       = size;
    result.modtime_ms = to_milliseconds(modtime);
    return result;
  }
}

// when we cache a file, we store both the raw content and also the brotli compressed version of it.
// A record is only valid for the size and modification time it was read with, so editing or
// rebuilding a file on disk is picked up by the very next request.
File_Cache_Record :: struct {
  rawcontent : string;
  brotli     : string;
  etag       : string;
  etag_br    : string;
  size       : s64;
  modtime    : s64;
}
file_cache: Table(string, File_Cache_Record);
file_cache_lock: Mutex; // the epoll threads all share this cache

file_cache_get :: (filename: string, options: Static_Options, known: File_Stat = .{}) -> File_Cache_Record, bool {
  info := known;
  if !info.known  info = stat_file(filename);
  if !info.exists || info.is_dir return .{}, false;
  size := info.size;
  modtime_ms := info.modtime_ms;

  lock(*file_cache_lock);
  found, record := table_find(*file_cache, filename);
  unlock(*file_cache_lock);
  if found && record.size == size && record.modtime == modtime_ms return record, true;

  filetext, success := read_entire_file(filename);
  if !success return .{}, false;

  // Buffers of a replaced record are intentionally not freed: another thread may be
  // sending them right now. A dev server rebuilding files leaks a little per rebuild.
  new_record: File_Cache_Record;
  new_record.rawcontent = filetext;
  new_record.size       = size;
  new_record.modtime    = modtime_ms;
  new_record.etag       = copy_string(tprint("\"%-%\"", filetext.count, modtime_ms));
  new_record.etag_br    = copy_string(tprint("\"%-%-br\"", filetext.count, modtime_ms));

  content_type := extension2contenttype(filename);
  if options.brotli && is_compressible(content_type) && filetext.count >= 256 {
    mode := ifx begins_with(content_type, "text/") then BROTLI_MODE_TEXT else BROTLI_MODE_GENERIC;
    new_record.brotli = brotli_compress(filetext, quality = options.brotli_quality, mode = mode);
  }

  lock(*file_cache_lock);
  existing := table_find_pointer(*file_cache, filename);
  if existing {
    existing.* = new_record;
  } else {
    // the key must outlive this request: filename is probably in temporary storage
    table_add(*file_cache, copy_string(filename), new_record);
  }
  unlock(*file_cache_lock);

  return new_record, true;
}

is_compressible :: (content_type: string) -> bool {
  if begins_with(content_type, "text/") return true;
  if content_type == {
    case "application/json";       return true;
    case "application/wasm";       return true;
    case "application/xml";        return true;
    case "image/svg+xml";          return true;
    case "application/javascript"; return true;
  }
  return false; // png, jpg, webp, woff2, mp4 ... are already compressed
}


// Content-Type aka MIME type
extension2contenttype :: (filename: string) -> string {
  last_slash := find_index_from_right(filename, #char "/");
  index_of_dot := find_index_from_right(filename, #char ".");
  // no extension (or the only dot is in a folder name)
  if index_of_dot == -1 || index_of_dot < last_slash return "application/octet-stream";

  push_allocator(temp);
  extension := to_lower_copy(substr(filename, index_of_dot, filename.count - index_of_dot));

  if extension == {
    case ".html";  return "text/html";
    case ".htm";   return "text/html";
    case ".css";   return "text/css";
    case ".js";    return "text/javascript";
    case ".mjs";   return "text/javascript";
    case ".json";  return "application/json";
    case ".map";   return "application/json";
    case ".wasm";  return "application/wasm";
    case ".xml";   return "application/xml";
    case ".txt";   return "text/plain";
    case ".ini";   return "text/plain";
    case ".md";    return "text/plain";
    case ".csv";   return "text/csv";
    case ".jai";   return "text/plain";
    case ".jaix";  return "text/plain";
    case ".svg";   return "image/svg+xml";
    case ".png";   return "image/png";
    case ".jpg";   return "image/jpeg";
    case ".jpeg";  return "image/jpeg";
    case ".gif";   return "image/gif";
    case ".webp";  return "image/webp";
    case ".avif";  return "image/avif";
    case ".ico";   return "image/x-icon";
    case ".woff";  return "font/woff";
    case ".woff2"; return "font/woff2";
    case ".ttf";   return "font/ttf";
    case ".otf";   return "font/otf";
    case ".mp3";   return "audio/mpeg";
    case ".mps";   return "audio/mpeg";
    case ".wav";   return "audio/wav";
    case ".ogg";   return "audio/ogg";
    case ".mp4";   return "video/mp4";
    case ".webm";  return "video/webm";
    case ".pdf";   return "application/pdf";
    case ".zip";   return "application/zip";
    case ".exe";   return "application/octet-stream";
  }

  // an unknown type must NOT default to text/html: that lets any uploaded file run as a web page
  return "application/octet-stream";
}


normalize_path :: (path: string) -> string { return trim(path, "/"); }

// For paths given to send_file(): drops a ?query and decodes %xx. Never modifies its input.
// (static() does not use this, it has its own stricter pipeline)
normalize_filename :: (raw_filename: string) -> string {
  filename := raw_filename;

  questionmark_location_in_filename := find_index_from_left(filename, #char "?");
  if questionmark_location_in_filename != -1  filename.count = questionmark_location_in_filename;

  decoded, ok := percent_decode(filename);
  if !ok return filename; // not a valid escape sequence, so it was just a filename with a % in it
  return decoded;
}


#import "File_Utilities";
#import,dir "modules/brotli";
