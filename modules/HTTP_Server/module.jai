

#load "websocket.jai";
#load "http_util.jai";
#load "request.jai";
#load "static.jai";
#load "middleware.jai";
#load "extras.jai";
#load "router.jai";

#if OS == .WINDOWS #load "windows.jai";
#if OS == .LINUX   #load "linux.jai";

// the main entry point is http_listen, which is defined in linux.jai and windows.jai


// Settings that can be changed before http_listen().
Server_Options :: struct {
  // head + body of a single request. Anything bigger is answered with 413 and the connection is dropped.
  max_request_bytes      : s64     = 1024 * 1024;
  // a request that has started but is not complete after this many seconds is dropped (slow clients)
  header_timeout_seconds : float64 = 15;
  // a keep-alive connection that sends nothing for this long is closed. 0 disables the timeout.
  idle_timeout_seconds   : float64 = 120;
  // print one line per response: METHOD /path status bytes time
  log_requests           : bool    = false;
}
http_options: Server_Options;

// set by http_shutdown(): requests that are still running finish, and every response closes its connection
shutting_down: bool;

// called by http_listen
http_common_init :: () {
  init(*routes_lock);
  init(*file_cache_lock);
  init(*ws_lock);
  init(*sessions_lock);
}


// ---------------------------------------------------------------------------------------
// routes and middleware
//
// A route is a method + path + handler. For each request, the routes run in the order they were
// added, and every one that matches gets called, until one of them sends a response. So a route
// that doesn't respond acts as middleware: it can look at the request, call set_header(), and
// let the request fall through to the next route.
//
//   path: "/users/:id"  matches /users/42, and get_param(request, "id") is "42"
//         "/api/*"      matches /api and everything below it
//         "*"           matches everything
//
// `data` is handed back to the handler as request.data, which lets one handler function serve
// several routes with different settings.
// ---------------------------------------------------------------------------------------

middlewares: [..]Middleware;
routes_lock: Mutex; // routes may be added while the server threads are already running

Middleware :: struct {
  method: METHOD;
  path: string;
  cb: (*Request)->();
  data: *void;
}

add_route :: (method: METHOD, path: string, cb: (*Request)->(), data: *void) {
  lock(*routes_lock);
  defer unlock(*routes_lock);
  array_add(*middlewares, .{method=method, cb=cb, path=normalize_path(path), data=data});
  router_insert(cast(s32) (middlewares.count - 1), middlewares[middlewares.count - 1].path);
}

get     :: (path: string, cb: (*Request)->(), data: *void = null) { add_route(.GET,     path, cb, data); }
post    :: (path: string, cb: (*Request)->(), data: *void = null) { add_route(.POST,    path, cb, data); }
put     :: (path: string, cb: (*Request)->(), data: *void = null) { add_route(.PUT,     path, cb, data); }
delete  :: (path: string, cb: (*Request)->(), data: *void = null) { add_route(.DELETE,  path, cb, data); }
patch   :: (path: string, cb: (*Request)->(), data: *void = null) { add_route(.PATCH,   path, cb, data); }
head    :: (path: string, cb: (*Request)->(), data: *void = null) { add_route(.HEAD,    path, cb, data); }
options :: (path: string, cb: (*Request)->(), data: *void = null) { add_route(.OPTIONS, path, cb, data); }
any     :: (path: string, cb: (*Request)->(), data: *void = null) { add_route(.ANY,     path, cb, data); }
// a HEAD request is answered by the matching get route, with the body left off


// ---------------------------------------------------------------------------------------
// responses
// ---------------------------------------------------------------------------------------

send_html     :: #bake_arguments send_response(content_type="text/html");
send_text     :: #bake_arguments send_response(content_type="text/plain");
send_json     :: #bake_arguments send_response(content_type="application/json");

send_response :: (request: *Request, content: string, status_code: u16 = 200, content_type: string = "text/plain", content_encoding: string = "") {
  push_allocator(temp);

  charset := ifx begins_with(content_type, "text/") || content_type == "application/json" then "; charset=UTF-8" else "";
  no_body := status_code == 204 || status_code == 304 || status_code < 200;

  // use_compress(): compress what is not a file (files are compressed once, by static())
  body := content;
  encoding := content_encoding;
  if !no_body && content_encoding.count == 0 {
    compressed, did_compress := maybe_compress(request, content, content_type, status_code);
    if did_compress { body = compressed; encoding = "br"; }
  }

  builder: String_Builder;
  print_to_builder(*builder, "HTTP/1.1 % %\r\n", status_code, status_code_to_string(status_code));
  if !no_body {
    print_to_builder(*builder, "Content-Length: %\r\n", body.count);
    print_to_builder(*builder, "Content-Type: %%\r\n", content_type, charset);
  }
  if encoding.count > 0  print_to_builder(*builder, "Content-Encoding: %\r\n", encoding);
  for request.res_headers  print_to_builder(*builder, "%: %\r\n", it.name, it.value);
  if request.close_after  append(*builder, "Connection: close\r\n");
  append(*builder, "\r\n");
  head := builder_to_string(*builder);

  // a HEAD response has the headers of the GET response, but no body
  http_response := ifx no_body || request.method == .HEAD then head else tprint("%%", head, body);

  write_response(request, http_response, status_code, body.count);
}

// the status line and headers only: 304 Not Modified, 204 No Content, ...
send_empty :: (request: *Request, status_code: u16) {
  send_response(request, "", status_code = status_code);
}

// a plain text response with the standard text of the status: send_status(request, 404) says "Not Found"
send_status :: (request: *Request, status_code: u16) {
  send_error(request, status_code);
}

redirect :: (request: *Request, location: string, status_code: u16 = 302) {
  set_header(request, "Location", location);
  send_response(request, "", status_code = status_code);
}

// Adds a header to the response of this request. Both strings are used when the response is
// sent, which happens during the same request, so literals and tprint() results are fine.
Header_Pair :: struct { name: string; value: string; }
set_header :: (request: *Request, name: string, value: string) {
  // replace instead of adding a second one
  for * request.res_headers {
    if compare_nocase(it.name, name) == 0 { it.value = value; return; }
  }
  array_add(*request.res_headers, .{name, value});
}

write_response :: (request: *Request, http_response: string, status_code: u16, body_bytes: s64) {
  request.response_sent = true;

  #if OS == .WINDOWS {
    mysocket_write(request.socket, http_response);
  } else {
    bytes_sent := mysocket_write(request.socket, http_response);
    if bytes_sent < 0  bytes_sent = 0; // would block (or the client is gone, which the read side will notice)
    if bytes_sent < http_response.count {
      write_data := alloc_string(http_response.count - bytes_sent);
      memcpy(write_data.data, http_response.data + bytes_sent, write_data.count);
      request.write_data       = write_data;
      request.write_bytes_sent = 0;
      continue_write(request);
    }
  }

  if http_options.log_requests {
    microseconds := cast(s64) ((seconds_since_init() - request.start_time) * 1000000);
    print("% % % % %us\n", request.method, request.path, status_code, body_bytes, microseconds);
  }
}


parseheaders :: true;
Request :: struct {
  #as socket      : MySocket;

  raw             : string; // the bytes read for this request (and maybe the start of the next one)
  body            : string; // pointer into raw
  path            : string; // pointer into raw. Just the path: the ?query is in request.query
  query           : string; // pointer into raw. What follows the ? (not decoded), or ""

  content_length  : u32;
  method          : METHOD;
  websocket_key   : string;
  accept_encoding : string;

  params          : Table(string, string);
  #if parseheaders {
    headers       : Table(string, string); // the names are lowercase: get_header() takes any case
  }

  res_headers     : [..] Header_Pair; // see set_header()
  locals          : Table(string, *void); // see set_local()
  request_id      : string;           // see use_request_id()
  session         : *Session;         // see session_get()
  compress_quality   : s32;           // see use_compress(): 0 is off
  compress_min_bytes : s64;
  data            : *void;            // the `data` of the route that is currently running
  start_time      : float64;

  response_sent   : bool;
  err             : bool;
  close_after     : bool; // answer, then close the connection (Connection: close, HTTP/1.0)
  upgraded        : bool; // this connection became a websocket
  connected       : bool;
  expects_continue: bool;

  #if OS == .LINUX {
    raw_capacity     : s64;  // allocated size of raw
    head_end         : s64;  // offset of the body: set once the head is parsed
    head_parsed      : bool;
    continue_sent    : bool;
    search_from      : s64;
    request_len      : s64;  // head + body of the finished request, anything after it in raw is the next one
    last_activity    : float64;
    thread_id        : s32;

    write_data       : string;
    write_bytes_sent : int;

    epoll_fd         : s32;
  }

  // the value of a :name in the route. "" if the route has no such parameter.
  get_param :: (request: *Request, name: string) -> string {
    found, val := table_find(*request.params, name);
    if !found return "";
    decoded, ok := percent_decode(val);
    return ifx ok then decoded else val;
  }
}
operator == :: inline (a: Request, b: Request) -> bool {return a.socket == b.socket; }

does_request_accept_encoding :: (request: *Request, encoding: string) -> bool {
  if !request.accept_encoding return false;
  for part: split(request.accept_encoding, ",") {
    token := trim(part, " \t");
    // "br;q=0.8": the part after the ; is the preference. q=0 means "never".
    semicolon := find_index_from_left(token, #char ";");
    if semicolon != -1 {
      parameters := slice(token, semicolon + 1, token.count - semicolon - 1);
      token.count = semicolon;
      if trim(parameters, " ") == "q=0" || trim(parameters, " ") == "q=0.0" continue;
    }
    if compare_nocase(token, encoding) == 0 return true;
  }
  return false;
}


// splits the next /segment off the front of s
next_segment :: (s: *string) -> string, bool {
  str := s.*;
  while str.count > 0 && str[0] == #char "/" { str.data += 1; str.count -= 1; }
  if str.count == 0 { s.* = str; return "", false; }
  end := 0;
  while end < str.count && str[end] != #char "/"  end += 1;
  segment := str;
  segment.count = end;
  str.data  += end;
  str.count -= end;
  s.* = str;
  return segment, true;
}

// does the route pattern match the path? With `request` set, also stores the :params
match_route :: (pattern: string, path: string, request: *Request) -> bool {
  if pattern == "*" return true;

  pattern_rest := pattern;
  path_rest := path;
  while true {
    pattern_segment, has_pattern_segment := next_segment(*pattern_rest);
    if !has_pattern_segment {
      _, has_more_path := next_segment(*path_rest);
      return !has_more_path; // both ran out together
    }
    if pattern_segment == "*" return true; // "/api/*" matches everything below /api (and /api itself)

    path_segment, has_path_segment := next_segment(*path_rest);
    if !has_path_segment return false;

    if pattern_segment[0] == #char ":" {
      if request {
        name := pattern_segment;
        name.data += 1;
        name.count -= 1;
        table_set(*request.params, name, path_segment);
      }
    } else if pattern_segment != path_segment {
      return false;
    }
  }
  return false;
}

handle_request :: (request: *Request) {
  request.start_time = seconds_since_init();
  request.res_headers.count = 0;
  request.data = null;
  if shutting_down  request.close_after = true;

  path_normal := normalize_path(request.path);

  if request.websocket_key {
    if websocket_server_listening(path_normal) {
      websocket_handle_request(request);
    } else {
      // todo: received a websocket request for a path we're not listening to. maybe some kind of notification, send a proper decline response?
    }
  }

  // the routes that match this path, in the order they were added. A route that doesn't respond is
  // middleware: the request goes on to the next one.
  for router_find(path_normal) {
    if request.response_sent break; // once a route handles the request, we stop. this is first because webhook could've handled it already

    method_matches := it.method == .ANY || it.method == request.method || (request.method == .HEAD && it.method == .GET);
    if !method_matches continue;

    table_reset(*request.params); // maybe this should happen somewhere else?
    if contains(it.path, ":") match_route(it.path, path_normal, request);

    request.data = it.data;
    it.cb(request);
  }

  // if none of the middleware responded to this request, 404
  if !request.response_sent {
    // the path exists, but not for this method?
    mask := allowed_methods(path_normal);
    wanted := ifx request.method == .HEAD then METHOD.GET else request.method;
    if request.method == .OPTIONS && mask != 0 {
      set_header(request, "Allow", allow_header_value(mask));
      send_empty(request, 204);
    } else if mask != 0 && (mask & method_bit(wanted)) == 0 {
      set_header(request, "Allow", allow_header_value(mask));
      send_error(request, 405, tprint("Cannot % %", request.method, request.path));
    } else {
      send_error(request, 404, tprint("Cannot % %", request.method, request.path));
    }
  }
}


METHOD :: enum u8 {ANY; GET; POST; PUT; DELETE; PATCH; HEAD; OPTIONS;}
to_METHOD :: (str: string) -> METHOD {
  if str == {
    case "GET";     return .GET;
    case "POST";    return .POST;
    case "PUT";     return .PUT;
    case "DELETE";  return .DELETE;
    case "PATCH";   return .PATCH;
    case "HEAD";    return .HEAD;
    case "OPTIONS"; return .OPTIONS;
    case;           return .ANY;
  }
}


mysocket_read :: (socket: Socket, buffer: *u8, bufferlen: s32) -> s64 {

  #if OS == .LINUX
    if ssl_is_socket_ssl(socket) // perf hash table lookup
      return ssl_read(socket, buffer, xx bufferlen);

  return recv(socket, buffer, xx bufferlen, 0);
}

mysocket_write :: (socket: Socket, buffer: string) -> s64 {

  #if OS == .LINUX
    if ssl_is_socket_ssl(socket) // perf hash table lookup
      return ssl_write(socket, buffer.data, xx buffer.count);

  return send(socket, buffer.data, xx buffer.count, 0);
}



#import "String";
#import "Thread";
