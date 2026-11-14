// The conveniences on top of the router: groups, form and multipart bodies, cookies, sessions,
// locals, error handlers, response compression, request ids.
//
// Everything that returns a string without saying otherwise returns it in temporary storage: it
// is valid until the request is done, so copy_string() it if it has to live longer.


// ---------------------------------------------------------------------------------------
// groups: a path prefix shared by a set of routes
//
//   api := group("/api");
//   group_use(api, auth_handler);                 // runs for everything under /api
//   group_get(api, "/users/:id", user_handler);   // GET /api/users/:id
//   v1 := sub_group(api, "/v1");                  // /api/v1
//
// As everywhere else, routes run in the order they were added, so group_use() only affects the
// routes that are added after it.
// ---------------------------------------------------------------------------------------

Group :: struct { prefix: string; }

// "/api" + "/users" is "api/users". The result is a copy that lives as long as the server.
join_path :: (a: string, b: string) -> string {
  return copy_string(normalize_path(tprint("%/%", a, b)));
}

group     :: (prefix: string) -> Group { return .{prefix = copy_string(normalize_path(prefix))}; }
sub_group :: (parent: Group, prefix: string) -> Group { return .{prefix = join_path(parent.prefix, prefix)}; }

group_route   :: (g: Group, method: METHOD, path: string, cb: (*Request)->(), data: *void = null) { add_route(method, join_path(g.prefix, path), cb, data); }
group_get     :: (g: Group, path: string, cb: (*Request)->(), data: *void = null) { group_route(g, .GET,     path, cb, data); }
group_post    :: (g: Group, path: string, cb: (*Request)->(), data: *void = null) { group_route(g, .POST,    path, cb, data); }
group_put     :: (g: Group, path: string, cb: (*Request)->(), data: *void = null) { group_route(g, .PUT,     path, cb, data); }
group_delete  :: (g: Group, path: string, cb: (*Request)->(), data: *void = null) { group_route(g, .DELETE,  path, cb, data); }
group_patch   :: (g: Group, path: string, cb: (*Request)->(), data: *void = null) { group_route(g, .PATCH,   path, cb, data); }
group_head    :: (g: Group, path: string, cb: (*Request)->(), data: *void = null) { group_route(g, .HEAD,    path, cb, data); }
group_options :: (g: Group, path: string, cb: (*Request)->(), data: *void = null) { group_route(g, .OPTIONS, path, cb, data); }
group_any     :: (g: Group, path: string, cb: (*Request)->(), data: *void = null) { group_route(g, .ANY,     path, cb, data); }

// middleware for everything in the group. For the built-in ones, pass the path instead:
// use_cors(.{}, join_path(api.prefix, "*"))
group_use :: (g: Group, cb: (*Request)->(), data: *void = null) { group_route(g, .ANY, "*", cb, data); }


// ---------------------------------------------------------------------------------------
// request bodies: forms, uploads
// ---------------------------------------------------------------------------------------

body_content_type :: (request: *Request) -> string {
  value, found := get_header(request, "content-type");
  return ifx found then value else "";
}

// The part of a header value like `form-data; name="avatar"; filename="me.png"` after `name=`.
header_param :: (value: string, name: string) -> string, bool {
  needle := tprint("%=", name);
  from := 0;
  while from < value.count {
    index := find_index_from_left(value, needle, from);
    if index == -1 return "", false;
    from = index + 1;
    // `name=` must start a parameter: filename= does not count as name=
    if index > 0 && value[index - 1] != #char " " && value[index - 1] != #char ";" continue;

    result := slice(value, index + needle.count, value.count - index - needle.count);
    if result.count > 0 && result[0] == #char "\"" {
      result = slice(result, 1, result.count - 1);
      close := find_index_from_left(result, #char "\"");
      if close != -1  result.count = close;
    } else {
      end := find_index_from_left(result, #char ";");
      if end != -1  result.count = end;
      result = trim(result, " \t");
    }
    return result, true;
  }
  return "", false;
}

// One field of an application/x-www-form-urlencoded body, or of a multipart/form-data body (file
// parts are not included, see get_file). Names and values are decoded. `found` is false when the field is missing.
get_form :: (request: *Request, name: string) -> string, bool {
  content_type := body_content_type(request);
  if begins_with_nocase(content_type, "application/x-www-form-urlencoded") {
    return find_urlencoded(request.body, name);
  }
  if begins_with_nocase(content_type, "multipart/form-data") {
    parts, ok := parse_multipart(request);
    if !ok return "", false;
    for parts {
      if it.name == name && it.filename.count == 0  return it.data, true;
    }
  }
  return "", false;
}

// One part of a multipart/form-data body. The strings point into the request body, nothing is copied.
Multipart_Part :: struct {
  name         : string;
  filename     : string; // "" for an ordinary field
  content_type : string;
  data         : string;
}

parse_multipart :: (request: *Request) -> [] Multipart_Part, bool {
  push_allocator(temp);
  parts: [..] Multipart_Part;

  boundary, has_boundary := header_param(body_content_type(request), "boundary");
  if !has_boundary || boundary.count == 0 || boundary.count > 200 return parts, false;

  body      := request.body;
  delimiter := tprint("--%", boundary);
  closing   := tprint("\r\n%", delimiter);

  position := find_index_from_left(body, delimiter);
  if position == -1 return parts, false;
  position += delimiter.count;

  while true {
    if position + 1 >= body.count return parts, false;
    if body[position] == #char "-" && body[position + 1] == #char "-" break; // the closing delimiter
    if body[position] != #char "\r" || body[position + 1] != #char "\n" return parts, false;
    position += 2;

    head_end := find_index_from_left(body, "\r\n\r\n", position);
    if head_end == -1 return parts, false;
    head := slice(body, position, head_end - position);

    data_start := head_end + 4;
    next := find_index_from_left(body, closing, data_start);
    if next == -1 return parts, false;

    part: Multipart_Part;
    part.data = slice(body, data_start, next - data_start);
    for line: split(head, "\r\n") {
      colon := find_index_from_left(line, #char ":");
      if colon == -1 continue;
      header_name  := to_lower_copy(slice(line, 0, colon));
      header_value := trim(slice(line, colon + 1, line.count - colon - 1), " \t");
      if header_name == "content-disposition" {
        part.name     = header_param(header_value, "name");
        part.filename = header_param(header_value, "filename");
      } else if header_name == "content-type" {
        part.content_type = header_value;
      }
    }
    array_add(*parts, part);
    if parts.count > 1000 return parts, false;

    position = next + closing.count;
  }
  return parts, true;
}

// An uploaded file of a multipart/form-data body:
//   file, found := get_file(request, "avatar");   file.filename, file.content_type, file.data
get_file :: (request: *Request, name: string) -> Multipart_Part, bool {
  parts, ok := parse_multipart(request);
  if !ok return .{}, false;
  for parts {
    if it.name == name && it.filename.count > 0  return it, true;
  }
  return .{}, false;
}

// A string as a JSON string literal, quotes included. Use it when building a send_json() body by hand.
json_quote :: (s: string) -> string {
  push_allocator(temp);
  builder: String_Builder;
  append(*builder, "\"");
  run_start := 0;
  for i: 0 .. s.count - 1 {
    c := s[i];
    if c >= 0x20 && c != #char "\"" && c != #char "\\" continue;
    append(*builder, slice(s, run_start, i - run_start));
    run_start = i + 1;
    if c == {
      case #char "\"";  append(*builder, "\\\"");
      case #char "\\";  append(*builder, "\\\\");
      case #char "\n";  append(*builder, "\\n");
      case #char "\r";  append(*builder, "\\r");
      case #char "\t";  append(*builder, "\\t");
      case;             print_to_builder(*builder, "\\u00%%", ifx c >= 16 then "1" else "0", "0123456789abcdef"[c & 15]);
    }
  }
  append(*builder, slice(s, run_start, s.count - run_start));
  append(*builder, "\"");
  return builder_to_string(*builder);
}


// ---------------------------------------------------------------------------------------
// cookies
// ---------------------------------------------------------------------------------------

Cookie_Options :: struct {
  path            : string = "/";
  domain          : string;
  max_age_seconds : s64    = -1;    // -1: a session cookie, gone when the browser closes
  http_only       : bool   = true;  // not readable by javascript
  secure          : bool   = false; // only sent over https
  same_site       : string = "Lax"; // "Strict", "Lax", "None", or "" to leave it out
}

get_cookie :: (request: *Request, name: string) -> string, bool {
  header, found := get_header(request, "cookie");
  if !found return "", false;

  for part: split(header, ";") {
    token  := trim(part, " \t");
    equals := find_index_from_left(token, #char "=");
    if equals == -1 continue;
    if slice(token, 0, equals) != name continue;

    value := slice(token, equals + 1, token.count - equals - 1);
    if value.count >= 2 && value[0] == #char "\"" && value[value.count - 1] == #char "\""  value = slice(value, 1, value.count - 2);
    decoded, ok := percent_decode(value);
    if ok return decoded, true;
    return value, true;
  }
  return "", false;
}

// Adds a Set-Cookie header to the response, so call it before the response is sent.
// The value is percent-encoded, get_cookie() decodes it again.
set_cookie :: (request: *Request, name: string, value: string, options: Cookie_Options = .{}) {
  push_allocator(temp);
  builder: String_Builder;
  print_to_builder(*builder, "%=%", name, percent_encode(value));
  if options.path.count > 0    print_to_builder(*builder, "; Path=%", options.path);
  if options.domain.count > 0  print_to_builder(*builder, "; Domain=%", options.domain);
  if options.max_age_seconds >= 0  print_to_builder(*builder, "; Max-Age=%", options.max_age_seconds);
  if options.http_only  append(*builder, "; HttpOnly");
  if options.secure     append(*builder, "; Secure");
  if options.same_site.count > 0  print_to_builder(*builder, "; SameSite=%", options.same_site);
  add_header(request, "Set-Cookie", builder_to_string(*builder));
}

// Tells the browser to drop the cookie. Path and domain have to be the ones it was set with.
clear_cookie :: (request: *Request, name: string, options_in: Cookie_Options = .{}) {
  options := options_in;
  options.max_age_seconds = 0;
  set_cookie(request, name, "", options);
}

// Like set_header, but adds another header with the same name instead of replacing the first (Set-Cookie)
add_header :: (request: *Request, name: string, value: string) {
  array_add(*request.res_headers, .{name, value});
}

// everything except letters, digits and - . _ ~ becomes %XX
percent_encode :: (s: string) -> string {
  hex := "0123456789ABCDEF";
  result := talloc_string(s.count * 3);
  count := 0;
  for i: 0 .. s.count - 1 {
    c := s[i];
    keep := (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") || (c >= #char "0" && c <= #char "9")
         || c == #char "-" || c == #char "." || c == #char "_" || c == #char "~";
    if keep {
      result[count] = c;
      count += 1;
    } else {
      result[count]     = #char "%";
      result[count + 1] = hex[c >> 4];
      result[count + 2] = hex[c & 15];
      count += 3;
    }
  }
  result.count = count;
  return result;
}


// ---------------------------------------------------------------------------------------
// sessions: values kept on the server, found again through a cookie.
//
//   session_set(request, "user", "alice");    // starts the session if there is none: call before sending the response
//   user, logged_in := session_get(request, "user");
//   session_destroy(request);                 // log out
//
// They live in memory: a restart forgets them, and so do several server processes that don't share them.
// ---------------------------------------------------------------------------------------

Session_Options :: struct {
  cookie_name     : string = "sid";
  max_age_seconds : s64    = 24 * 60 * 60; // idle time after which a session is dropped
  cookie          : Cookie_Options;        // set secure = true when serving https
}
session_options: Session_Options; // change before http_listen()

Session :: struct {
  id        : string;
  values    : Table(string, string);
  last_used : float64;
}

sessions       : Table(string, *Session);
sessions_lock  : Mutex;
sessions_swept : float64;

// the session of this request. With create, starts a new one (and sets its cookie) when there is none.
session_find :: (request: *Request, create: bool) -> *Session {
  if request.session return request.session;

  now := seconds_since_init();
  cookie_value, has_cookie := get_cookie(request, session_options.cookie_name);

  lock(*sessions_lock);
  defer unlock(*sessions_lock);

  if now - sessions_swept > 60 {
    sessions_swept = now;
    session_sweep(now);
  }

  if has_cookie {
    found, session := table_find(*sessions, cookie_value);
    if found && now - session.last_used <= xx session_options.max_age_seconds {
      session.last_used = now;
      request.session = session;
      return session;
    }
  }
  if !create return null;

  session := New(Session);
  session.id = new_random_id();
  session.last_used = now;
  table_add(*sessions, session.id, session);

  options := session_options.cookie;
  options.max_age_seconds = session_options.max_age_seconds;
  set_cookie(request, session_options.cookie_name, session.id, options);

  request.session = session;
  return session;
}

// sessions_lock must be held
session_sweep :: (now: float64) {
  push_allocator(temp);
  expired: [..] string;
  for sessions {
    if now - it.last_used > xx session_options.max_age_seconds  array_add(*expired, it_index);
  }
  for id: expired {
    found, session := table_find(*sessions, id);
    if !found continue;
    table_remove(*sessions, id);
    session_free(session);
  }
}

session_free :: (session: *Session) {
  for session.values { free(it_index.data); free(it.data); }
  table_reset(*session.values);
  free(session.id.data);
  free(session);
}

session_get :: (request: *Request, key: string) -> string, bool {
  session := session_find(request, false);
  if !session return "", false;

  lock(*sessions_lock);
  defer unlock(*sessions_lock);
  found, value := table_find(*session.values, key);
  if !found return "", false;
  push_allocator(temp);
  return copy_string(value), true;
}

session_set :: (request: *Request, key: string, value: string) {
  session := session_find(request, true);

  lock(*sessions_lock);
  defer unlock(*sessions_lock);
  existing := table_find_pointer(*session.values, key);
  if existing {
    free(existing.data);
    existing.* = copy_string(value);
  } else {
    table_add(*session.values, copy_string(key), copy_string(value));
  }
}

session_delete :: (request: *Request, key: string) {
  session := session_find(request, false);
  if !session return;

  lock(*sessions_lock);
  defer unlock(*sessions_lock);
  found, value := table_find(*session.values, key);
  if !found return;
  free(value.data);
  // the key string is leaked: the table does not hand it back
  table_remove(*session.values, key);
}

// ends the session and asks the browser to forget its cookie
session_destroy :: (request: *Request) {
  session := session_find(request, false);
  if !session return;
  request.session = null;

  lock(*sessions_lock);
  table_remove(*sessions, session.id);
  unlock(*sessions_lock);
  session_free(session);

  options := session_options.cookie;
  clear_cookie(request, session_options.cookie_name, options);
}

// 16 random bytes as 32 hex characters, on the heap
new_random_id :: () -> string {
  bytes: [16] u8;
  random_bytes(bytes.data, bytes.count);
  hex := "0123456789abcdef";
  id := alloc_string(32);
  for i: 0 .. 15 {
    id[i * 2]     = hex[bytes[i] >> 4];
    id[i * 2 + 1] = hex[bytes[i] & 15];
  }
  return id;
}

random_bytes :: (buffer: *u8, count: s64) {
  file, opened := file_open("/dev/urandom");
  assert(opened, "cannot read /dev/urandom");
  success, total := file_read(file, buffer, count);
  file_close(*file);
  assert(success && total == count, "cannot read /dev/urandom");
}


// ---------------------------------------------------------------------------------------
// locals: pass something from a middleware to the handlers after it
//
//   set_local(request, "user", user_pointer);    // in the middleware
//   user := cast(*User) get_local(request, "user");
// ---------------------------------------------------------------------------------------

set_local :: (request: *Request, key: string, value: *void) { table_set(*request.locals, key, value); }
get_local :: (request: *Request, key: string) -> *void {
  found, value := table_find(*request.locals, key);
  return ifx found then value else null;
}


// ---------------------------------------------------------------------------------------
// errors
//
// Every error the server makes itself (404, 405, 400, 413, ...) goes through send_error(), so one
// handler can give all of them the look of the site. If the handler sends no response, the
// default plain text one is sent.
//
//   set_error_handler((request: *Request, status_code: u16, message: string) {;
//     send_json(request, tprint("{\"error\":%}", json_quote(message)), status_code = status_code);
//   });
//
// There is no recover middleware: a crash in a handler is a crash of the process, there are no
// exceptions to catch. Check what a handler can get wrong, and use send_error() for it.
// ---------------------------------------------------------------------------------------

Error_Handler :: #type (request: *Request, status_code: u16, message: string) -> ();
error_handler: Error_Handler;

set_error_handler :: (cb: Error_Handler) { error_handler = cb; }

send_error :: (request: *Request, status_code: u16, message: string = "") {
  text := ifx message.count > 0 then message else status_code_to_string(status_code);
  if error_handler {
    error_handler(request, status_code, text);
    if request.response_sent return;
  }
  send_text(request, text, status_code = status_code);
}


// ---------------------------------------------------------------------------------------
// compression of responses that are not files (those are compressed once, and cached, by static())
//
//   use_compress();                                  // brotli for every text/json/... response over 512 bytes
//   use_compress(.{quality = 3}, "/api/*");
//
// Only brotli is supported, which every browser sends in Accept-Encoding.
// ---------------------------------------------------------------------------------------

Compress_Config :: struct {
  quality   : s32 = 4;   // 1 to 11. Higher is smaller and slower: for every response, keep it low
  min_bytes : s64 = 512; // smaller bodies are sent as they are
}

use_compress :: (config: Compress_Config = .{}, path: string = "*") {
  stored := New(Compress_Config);
  stored.* = config;
  any(path, compress_handler, stored);
}

compress_handler :: (request: *Request) {
  config := cast(*Compress_Config) request.data;
  request.compress_quality   = config.quality;
  request.compress_min_bytes = config.min_bytes;
}

// the content (still in temporary storage) as it should be sent: maybe compressed
maybe_compress :: (request: *Request, content: string, content_type: string, status_code: u16) -> string, bool {
  if request.compress_quality <= 0 return content, false;
  if status_code == 206 || content.count < request.compress_min_bytes return content, false;
  if !is_compressible(content_type) return content, false;
  set_header(request, "Vary", "Accept-Encoding");
  if !does_request_accept_encoding(request, "br") return content, false;

  mode := ifx begins_with(content_type, "text/") then BROTLI_MODE_TEXT else BROTLI_MODE_GENERIC;
  compressed := brotli_compress(content, quality = request.compress_quality, mode = mode);
  if compressed.count == 0 || compressed.count >= content.count return content, false;
  return compressed, true;
}


// ---------------------------------------------------------------------------------------
// a unique id for every request: X-Request-ID of the client if it sent a sane one, a random one if not.
// The id is in request.request_id, and in the response.
// ---------------------------------------------------------------------------------------

use_request_id :: (path: string = "*") { any(path, request_id_handler); }

request_id_handler :: (request: *Request) {
  incoming, found := get_header(request, "x-request-id");
  if found && is_sane_request_id(incoming) {
    request.request_id = incoming;
  } else {
    bytes: [8] u8;
    random_bytes(bytes.data, bytes.count);
    hex := "0123456789abcdef";
    id := talloc_string(16);
    for i: 0 .. 7 {
      id[i * 2]     = hex[bytes[i] >> 4];
      id[i * 2 + 1] = hex[bytes[i] & 15];
    }
    request.request_id = id;
  }
  set_header(request, "X-Request-ID", request.request_id);
}

is_sane_request_id :: (id: string) -> bool {
  if id.count == 0 || id.count > 64 return false;
  for i: 0 .. id.count - 1 {
    c := id[i];
    ok := (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") || (c >= #char "0" && c <= #char "9") || c == #char "-" || c == #char "_" || c == #char ".";
    if !ok return false;
  }
  return true;
}


// ---------------------------------------------------------------------------------------
// which routes there are, and which methods a path answers (for 405 and OPTIONS)
// ---------------------------------------------------------------------------------------

print_routes :: () {
  lock(*routes_lock);
  defer unlock(*routes_lock);
  for middlewares  print("%  /%\n", it.method, it.path);
}

method_bit :: (method: METHOD) -> u32 {
  bit: u32 = 1;
  return bit << cast(u32) method;
}

// the methods of the routes that match the path. Routes for any method are middleware, they don't count.
allowed_methods :: (path: string) -> u32 {
  mask: u32;
  for router_find(path) {
    if it.method == .ANY || it.path == "*" continue;
    mask |= method_bit(it.method);
  }
  return mask;
}

allow_header_value :: (mask: u32) -> string {
  push_allocator(temp);
  builder: String_Builder;
  first := true;
  for method: METHOD.[.GET, .HEAD, .POST, .PUT, .DELETE, .PATCH, .OPTIONS] {
    allowed := (mask & method_bit(method)) != 0 || (method == .HEAD && (mask & method_bit(.GET)) != 0) || method == .OPTIONS;
    if !allowed continue;
    if !first  append(*builder, ", ");
    first = false;
    print_to_builder(*builder, "%", method);
  }
  return builder_to_string(*builder);
}


// ---------------------------------------------------------------------------------------
// Range: bytes=0-99 | bytes=100- | bytes=-500        (one range only: with several, the whole file is sent)
// returns 0 when there is nothing to do with it, 1 for start..end (both included), 2 for "not satisfiable"
// ---------------------------------------------------------------------------------------

parse_range :: (header: string, size: s64) -> s32, s64, s64 {
  if !begins_with(header, "bytes=") return 0, 0, 0;
  spec := slice(header, 6, header.count - 6);
  if find_index_from_left(spec, #char ",") != -1 return 0, 0, 0;
  dash := find_index_from_left(spec, #char "-");
  if dash == -1 return 0, 0, 0;

  first := slice(spec, 0, dash);
  last  := slice(spec, dash + 1, spec.count - dash - 1);

  if first.count == 0 { // the last N bytes
    n, ok := parse_decimal(last);
    if !ok return 0, 0, 0;
    if n == 0 || size == 0 return 2, 0, 0;
    if n > size  n = size;
    return 1, size - n, size - 1;
  }

  start, start_ok := parse_decimal(first);
  if !start_ok return 0, 0, 0;
  if start >= size return 2, 0, 0;
  end := size - 1;
  if last.count > 0 {
    value, end_ok := parse_decimal(last);
    if !end_ok || value < start return 0, 0, 0; // not a valid range: a server ignores it
    if value < end  end = value;
  }
  return 1, start, end;
}

parse_decimal :: (s: string) -> s64, bool {
  if s.count == 0 || s.count > 15 return 0, false;
  value: s64;
  for i: 0 .. s.count - 1 {
    c := s[i];
    if c < #char "0" || c > #char "9" return 0, false;
    value = value * 10 + cast(s64) (c - #char "0");
  }
  return value, true;
}
