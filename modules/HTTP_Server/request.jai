// Parsing of the request line and headers. This is independent of how the bytes
// were read, so it works on whatever is in request.raw once the blank line that
// ends the head ("\r\n\r\n") has arrived.

MAX_HEAD_BYTES :: 16 * 1024; // request line + all headers
MAX_HEADERS    :: 100;

find_crlf :: (s: string, from: s64) -> s64 {
  for i: from .. s.count - 2 {
    if s[i] == #char "\r" && s[i + 1] == #char "\n" return i;
  }
  return -1;
}

// Index of the "\r\n\r\n" that ends the head, or -1.
find_head_end :: (raw: string, from: s64) -> s64 {
  for i: from .. raw.count - 4 {
    if raw[i] == #char "\r" && raw[i + 1] == #char "\n" && raw[i + 2] == #char "\r" && raw[i + 3] == #char "\n" return i;
  }
  return -1;
}

// Fills in method, path, query, headers, content_length ... from request.raw.
// `head_end` is the offset just past the blank line. Returns 0 if the request
// is fine, otherwise the status code to answer with. Never reads outside raw.
//
// Header names are lowercased IN PLACE (raw is the connection's own buffer), so
// request.headers is keyed by lowercase names. Values are slices into raw.
parse_request_head :: (request: *Request, head_end: s64) -> u16 {
  request.method          = .ANY;
  request.path            = "";
  request.query           = "";
  request.content_length  = 0;
  request.websocket_key   = "";
  request.accept_encoding = "";
  request.close_after     = false;
  request.expects_continue = false;
  table_reset(*request.headers);
  table_reset(*request.params);

  // everything up to and including the CRLF that ends the last header line
  head := request.raw;
  head.count = head_end - 2;

  // --- request line:  METHOD SP target SP HTTP/1.x
  line_end := find_crlf(head, 0);
  if line_end == -1 return 400;
  request_line := slice(head, 0, line_end);

  space1 := find_index_from_left(request_line, #char " ");
  if space1 <= 0 return 400;
  rest := slice(request_line, space1 + 1, request_line.count - space1 - 1);
  space2 := find_index_from_left(rest, #char " ");
  if space2 <= 0 return 400;

  method_text := slice(request_line, 0, space1);
  target      := slice(rest, 0, space2);
  version     := slice(rest, space2 + 1, rest.count - space2 - 1);

  if version != "HTTP/1.1" && version != "HTTP/1.0" {
    return ifx begins_with(version, "HTTP/") then cast(u16) 505 else cast(u16) 400;
  }

  request.method = to_METHOD(method_text);
  if request.method == .ANY return 501; // a method we don't know (TRACE, CONNECT, ...)

  if target.count == 0 || target[0] != #char "/" return 400;
  question := find_index_from_left(target, #char "?");
  if question == -1 {
    request.path = target;
  } else {
    request.path  = slice(target, 0, question);
    request.query = slice(target, question + 1, target.count - question - 1);
  }

  // --- headers
  saw_close := false;
  saw_keep_alive := false;
  saw_content_length := false;
  header_count := 0;

  cursor := line_end + 2;
  while cursor < head.count {
    eol := find_crlf(head, cursor);
    if eol == -1 break;
    line := slice(head, cursor, eol - cursor);
    cursor = eol + 2;
    if line.count == 0 continue;

    header_count += 1;
    if header_count > MAX_HEADERS return 431;

    colon := find_index_from_left(line, #char ":");
    if colon <= 0 return 400; // no colon, or an empty name

    name := slice(line, 0, colon);
    for i: 0 .. name.count - 1 {
      c := name.data[i];
      if c == #char " " || c == #char "\t" return 400; // whitespace before the colon is how request smuggling starts
      if c >= #char "A" && c <= #char "Z" name.data[i] = c + 32;
    }
    value := trim(slice(line, colon + 1, line.count - colon - 1), " \t");

    table_set(*request.headers, name, value);

    if name == {
      case "content-length";
        if value.count == 0 || value.count > 12 return 400;
        for i: 0 .. value.count - 1 {
          if value[i] < #char "0" || value[i] > #char "9" return 400;
        }
        length, length_ok := to_integer(value);
        if !length_ok return 400;
        if saw_content_length && length != request.content_length return 400; // two different lengths: refuse
        if length > http_options.max_request_bytes return 413;
        request.content_length = xx length;
        saw_content_length = true;

      case "transfer-encoding";
        // chunked request bodies are not supported. Answering 501 is the correct reply.
        if compare_nocase(value, "identity") != 0 return 501;

      case "sec-websocket-key";
        request.websocket_key = value;

      case "accept-encoding";
        request.accept_encoding = value;

      case "connection";
        {
          push_allocator(temp);
          lowered := to_lower_copy(value);
          if contains(lowered, "close")      saw_close = true;
          if contains(lowered, "keep-alive") saw_keep_alive = true;
        }

      case "expect";
        if compare_nocase(value, "100-continue") != 0 return 417;
        request.expects_continue = true;
    }
  }

  // HTTP/1.1 connections persist unless told otherwise, HTTP/1.0 ones close unless told otherwise
  request.close_after = ifx version == "HTTP/1.0" then !saw_keep_alive else saw_close;

  return 0;
}
