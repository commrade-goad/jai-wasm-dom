// Ready made middleware. Each use_*() adds a route (see "routes and middleware" in module.jai),
// so ORDER MATTERS: call them before the routes they should protect, and before static().
//
//   http_listen(port = 8000);
//   use_logger();
//   use_security_headers();
//   use_cors(.{ allow_origins = "https://example.com" }, "/api/*");
//   use_rate_limit(.{ max_requests = 60, window_seconds = 60 }, "/api/*");
//   use_basic_auth("admin", "hunter2", path = "/admin/*");
//   get("/api/hello", ...);
//   static("public");
//
// The second argument of use_cors / use_rate_limit / use_basic_auth is the path they apply to ("*" is everything).


// --- logger ----------------------------------------------------------------------------

// One line per response: METHOD /path status bytes time
use_logger :: () {
  http_options.log_requests = true;
}


// --- security headers --------------------------------------------------------------------

// X-Content-Type-Options, X-Frame-Options and Referrer-Policy on every response
use_security_headers :: (path: string = "*") {
  any(path, (request: *Request) {;
    set_header(request, "X-Content-Type-Options", "nosniff");
    set_header(request, "X-Frame-Options", "SAMEORIGIN");
    set_header(request, "Referrer-Policy", "strict-origin-when-cross-origin");
  });
}


// --- CORS ------------------------------------------------------------------------------

Cors_Config :: struct {
  // "*", or the allowed origins separated by commas: "https://a.com, https://b.com"
  allow_origins     : string = "*";
  allow_methods     : string = "GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS";
  // empty: allow whatever headers the browser asks for in its preflight request
  allow_headers     : string = "";
  expose_headers    : string = "";
  allow_credentials : bool   = false;
  max_age           : s32    = 600; // seconds a browser may remember the answer to a preflight
}

// Sets the CORS headers, and answers preflight (OPTIONS) requests by itself with 204.
// A request from an origin that is not allowed gets no CORS headers, which makes the browser refuse it.
use_cors :: (config: Cors_Config = .{}, path: string = "*") {
  stored := New(Cors_Config); // lives as long as the server
  stored.* = config;
  stored.allow_origins = copy_string(config.allow_origins);
  stored.allow_methods = copy_string(config.allow_methods);
  stored.allow_headers = copy_string(config.allow_headers);
  stored.expose_headers = copy_string(config.expose_headers);
  any(path, cors_handler, stored);
}

cors_handler :: (request: *Request) {
  config := cast(*Cors_Config) request.data;

  origin, has_origin := get_header(request, "origin");
  if !has_origin return; // not a cross origin request

  allow_any := false;
  allowed := false;
  for raw_entry: split(config.allow_origins, ",") {
    entry := trim(raw_entry, " ");
    if entry == "*" { allow_any = true; allowed = true; break; }
    if entry == origin { allowed = true; break; }
  }
  if !allowed return;

  // "*" is not allowed together with credentials, so the origin is echoed back in that case
  if allow_any && !config.allow_credentials {
    set_header(request, "Access-Control-Allow-Origin", "*");
  } else {
    set_header(request, "Access-Control-Allow-Origin", origin);
    set_header(request, "Vary", "Origin");
  }
  if config.allow_credentials   set_header(request, "Access-Control-Allow-Credentials", "true");
  if config.expose_headers.count > 0  set_header(request, "Access-Control-Expose-Headers", config.expose_headers);

  _, is_preflight := get_header(request, "access-control-request-method");
  if request.method == .OPTIONS && is_preflight {
    set_header(request, "Access-Control-Allow-Methods", config.allow_methods);

    requested_headers, has_requested_headers := get_header(request, "access-control-request-headers");
    allow_headers := ifx config.allow_headers.count > 0 then config.allow_headers else requested_headers;
    if allow_headers.count > 0  set_header(request, "Access-Control-Allow-Headers", allow_headers);

    set_header(request, "Access-Control-Max-Age", tprint("%", config.max_age));
    send_empty(request, 204);
  }
}


// --- rate limiting -----------------------------------------------------------------------

Rate_Limit_Config :: struct {
  max_requests : s32     = 100;  // per client, per window
  window_seconds : float64 = 60;
  // behind a reverse proxy every request comes from the proxy's address. With this set the client is
  // taken from the X-Forwarded-For header instead. ONLY enable it when a proxy you control sets that header,
  // otherwise any client can pick its own address.
  trust_proxy  : bool    = false;
  message      : string  = "Too many requests. Slow down.";
}

Rate_Limit_Bucket :: struct { count: s32; window_start: float64; }

Rate_Limit_State :: struct {
  config       : Rate_Limit_Config;
  lock         : Mutex; // the epoll threads share the buckets
  buckets      : Table(u64, Rate_Limit_Bucket);
  last_cleanup : float64;
}

// Fixed window limit per client address: after max_requests in a window the client gets 429 with a
// Retry-After header until the window ends. Every response also carries X-RateLimit-Limit, -Remaining and -Reset.
use_rate_limit :: (config: Rate_Limit_Config = .{}, path: string = "*") {
  state := New(Rate_Limit_State);
  state.config = config;
  state.config.message = copy_string(config.message);
  init(*state.lock);
  any(path, rate_limit_handler, state);
}

rate_limit_handler :: (request: *Request) {
  state := cast(*Rate_Limit_State) request.data;
  config := state.config;

  key := rate_limit_key(request, config.trust_proxy);
  now := seconds_since_init();

  allowed: bool;
  remaining: s32;
  reset_in: float64;

  lock(*state.lock);
  bucket := find_or_add(*state.buckets, key);
  if bucket.window_start == 0 || now - bucket.window_start >= config.window_seconds {
    bucket.window_start = now;
    bucket.count = 0;
  }
  bucket.count += 1;
  allowed   = bucket.count <= config.max_requests;
  remaining = cast(s32) max(0, cast(s64) config.max_requests - cast(s64) bucket.count);
  reset_in  = config.window_seconds - (now - bucket.window_start);

  // forget clients whose window is over, otherwise the table grows with every address ever seen
  if now - state.last_cleanup > config.window_seconds {
    state.last_cleanup = now;
    expired: [..] u64;
    expired.allocator = temp;
    for state.buckets {
      if now - it.window_start >= config.window_seconds  array_add(*expired, it_index);
    }
    for expired  table_remove(*state.buckets, it);
  }
  unlock(*state.lock);

  seconds_left := cast(s64) ceil(reset_in);
  set_header(request, "X-RateLimit-Limit", tprint("%", config.max_requests));
  set_header(request, "X-RateLimit-Remaining", tprint("%", remaining));
  set_header(request, "X-RateLimit-Reset", tprint("%", seconds_left));

  if !allowed {
    set_header(request, "Retry-After", tprint("%", seconds_left));
    send_text(request, config.message, status_code = 429);
  }
}

// the address of the client, as a number to use as a table key
rate_limit_key :: (request: *Request, trust_proxy: bool) -> u64 {
  if trust_proxy {
    forwarded, has_forwarded := get_header(request, "x-forwarded-for");
    if has_forwarded {
      first := forwarded;
      comma := find_index_from_left(first, #char ",");
      if comma != -1 first.count = comma;
      return fnv1a(trim(first, " "));
    }
  }
  return client_address(request);
}

// the IPv4 address of the connection
client_address :: (request: *Request) -> u64 {
  #if OS == .LINUX {
    return get_sockaddr_in_from_socket(request.socket.socket).sin_addr.s_addr;
  } else {
    return 0; // todo: not implemented on windows, every client counts as the same one
  }
}

fnv1a :: (text: string) -> u64 {
  hash: u64 = 0xcbf29ce484222325;
  for i: 0 .. text.count - 1 {
    hash = (hash ^ text[i]) * 0x100000001b3;
  }
  return hash;
}


// --- basic auth --------------------------------------------------------------------------

Basic_Auth_Config :: struct { username: string; password: string; realm: string; }

// HTTP basic auth: the browser shows its own login dialog. Only use it over https or on localhost,
// the password travels in clear text otherwise.
use_basic_auth :: (username: string, password: string, realm: string = "Restricted", path: string = "*") {
  stored := New(Basic_Auth_Config);
  stored.username = copy_string(username);
  stored.password = copy_string(password);
  stored.realm    = copy_string(realm);
  any(path, basic_auth_handler, stored);
}

basic_auth_handler :: (request: *Request) {
  config := cast(*Basic_Auth_Config) request.data;

  authorization, has_authorization := get_header(request, "authorization");
  if has_authorization && begins_with(authorization, "Basic ") {
    decoded, ok := base64_decode(trim(slice(authorization, 6, authorization.count - 6), " "));
    if ok {
      expected := tprint("%:%", config.username, config.password);
      if constant_time_equals(decoded, expected) return; // let the request through to the routes below
    }
  }

  set_header(request, "WWW-Authenticate", tprint("Basic realm=\"%\", charset=\"UTF-8\"", config.realm));
  send_text(request, "Unauthorized", status_code = 401);
}

// compares without stopping at the first difference, so the time taken doesn't reveal how much matched
constant_time_equals :: (a: string, b: string) -> bool {
  difference: u8 = ifx a.count == b.count then 0 else 1;
  for i: 0 .. min(a.count, b.count) - 1 {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

#import "Base64";
#import "Math";
