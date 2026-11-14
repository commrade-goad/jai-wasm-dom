// Small helpers shared by the rest of the module: status text, URL decoding,
// the static-file path guard, and query string access.


status_code_to_string :: (status_code: u16) -> string {
  if status_code == {
    case 100; return "Continue";
    case 101; return "Switching Protocols";
    case 200; return "OK";
    case 201; return "Created";
    case 202; return "Accepted";
    case 204; return "No Content";
    case 206; return "Partial Content";
    case 301; return "Moved Permanently";
    case 302; return "Found";
    case 303; return "See Other";
    case 304; return "Not Modified";
    case 307; return "Temporary Redirect";
    case 308; return "Permanent Redirect";
    case 400; return "Bad Request";
    case 401; return "Unauthorized";
    case 403; return "Forbidden";
    case 404; return "Not Found";
    case 405; return "Method Not Allowed";
    case 408; return "Request Timeout";
    case 409; return "Conflict";
    case 411; return "Length Required";
    case 413; return "Content Too Large";
    case 414; return "URI Too Long";
    case 415; return "Unsupported Media Type";
    case 416; return "Range Not Satisfiable";
    case 422; return "Unprocessable Content";
    case 429; return "Too Many Requests";
    case 431; return "Request Header Fields Too Large";
    case 500; return "Internal Server Error";
    case 501; return "Not Implemented";
    case 502; return "Bad Gateway";
    case 503; return "Service Unavailable";
    case 504; return "Gateway Timeout";
    case 505; return "HTTP Version Not Supported";
  }
  // an unknown code still has to produce a valid status line
  if status_code >= 500 return "Server Error";
  if status_code >= 400 return "Client Error";
  if status_code >= 300 return "Redirect";
  if status_code >= 200 return "Success";
  return "Informational";
}


hex_value :: (c: u8) -> s32 {
  if c >= #char "0" && c <= #char "9" return xx (c - #char "0");
  if c >= #char "a" && c <= #char "f" return xx (c - #char "a" + 10);
  if c >= #char "A" && c <= #char "F" return xx (c - #char "A" + 10);
  return -1;
}

// Decodes %xx (and optionally + as a space) into a new temporary string. The
// input is never modified. Returns false for a truncated or non-hex escape, and
// for an encoded NUL byte, which has no business in a path.
percent_decode :: (s: string, plus_is_space := false) -> string, bool {
  if find_index_from_left(s, #char "%") == -1 && (!plus_is_space || find_index_from_left(s, #char "+") == -1) {
    return s, true; // nothing to decode, nothing allocated
  }

  result := talloc_string(s.count);
  count := 0;
  i := 0;
  while i < s.count {
    c := s[i];
    if c == #char "%" {
      if i + 2 >= s.count return "", false; // truncated escape: %, or %4 at the end
      high := hex_value(s[i + 1]);
      low  := hex_value(s[i + 2]);
      if high < 0 || low < 0 return "", false;
      byte: u8 = xx (high * 16 + low);
      if byte == 0 return "", false;
      result[count] = byte;
      count += 1;
      i += 3;
    } else {
      if plus_is_space && c == #char "+" c = #char " ";
      result[count] = c;
      count += 1;
      i += 1;
    }
  }
  result.count = count;
  return result, true;
}


MAX_PATH_DEPTH :: 64;

// Turns the (already percent-decoded) path of a request into a path that is
// relative to the static folder, like "examples/hello/main.wasm". "." and ".."
// segments are resolved lexically, so a path can never climb out of the folder.
//
//   returns the clean path ("" for the root), and a status:
//     0    ok
//     400  malformed (NUL or backslash in the path, absurdly deep)
//     403  tried to escape the static folder with ..
//     404  names a hidden file (a segment starting with ".") and those are not served
//
// Always decode FIRST and clean SECOND. Checking the raw text for "../" before
// decoding is bypassed by %2e%2e/ and ..%2f.
clean_static_path :: (decoded: string, allow_dotfiles: bool) -> string, u16 {
  push_allocator(temp); // everything here is per-request garbage
  segments: [MAX_PATH_DEPTH] string;
  depth := 0;

  start := 0;
  for i: 0 .. decoded.count {
    at_end := i == decoded.count;
    if !at_end {
      c := decoded[i];
      if c == #char "\\" || c == 0 return "", 400;
      if c != #char "/" continue;
    }

    segment := slice(decoded, start, i - start);
    start = i + 1;

    if segment.count == 0 || segment == "." continue;

    if segment == ".." {
      if depth == 0 return "", 403;
      depth -= 1;
      continue;
    }

    if !allow_dotfiles && segment[0] == #char "." && segment != ".well-known" return "", 404;

    if depth >= MAX_PATH_DEPTH return "", 400;
    segments[depth] = segment;
    depth += 1;
  }

  builder: String_Builder;
  for 0 .. depth - 1 {
    if it > 0 append(*builder, "/");
    append(*builder, segments[it]);
  }
  return builder_to_string(*builder), 0;
}


// The value of one query string parameter: /search?q=jai&page=2
// Names and values are percent-decoded ("+" is a space). `found` is false when
// the parameter is missing; `?flag` without a value is found with an empty value.
get_query :: (request: *Request, name: string) -> string, bool {
  return find_urlencoded(request.query, name);
}

// the same lookup in any key=value&key=value text, like a form body
find_urlencoded :: (text: string, name: string) -> string, bool {
  query := text;
  while query.count > 0 {
    amp := find_index_from_left(query, #char "&");
    pair := query;
    if amp != -1 {
      pair.count = amp;
      query = slice(query, amp + 1, query.count - amp - 1);
    } else {
      query.count = 0;
    }
    if pair.count == 0 continue;

    equals := find_index_from_left(pair, #char "=");
    key   := pair;
    value := "";
    if equals != -1 {
      key.count = equals;
      value = slice(pair, equals + 1, pair.count - equals - 1);
    }

    decoded_key, key_ok := percent_decode(key, plus_is_space = true);
    if !key_ok || decoded_key != name continue;

    decoded_value, value_ok := percent_decode(value, plus_is_space = true);
    if !value_ok return "", false;
    return decoded_value, true;
  }
  return "", false;
}

// A request header. Names are stored lowercase, but this accepts any case.
get_header :: (request: *Request, name: string) -> string, bool {
  push_allocator(temp);
  found, value := table_find(*request.headers, to_lower_copy(name));
  if !found return "", false;
  return value, true;
}
