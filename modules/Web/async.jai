#import "Basic";

// Async host bridge for the browser: fetch, WebSocket, timers, animation
// frames and Web Workers.
//
// WASM has no event loop of its own, so every operation is started here and
// finished later by the host calling back into Jai. The program must export
// the dispatcher (see main.jai):
//
//     #program_export "jai_async_dispatch"
//     jai_async_dispatch :: (callback: Async_Callback, handle: Async_Handle, event: s32, data: *void) #c_call #no_context { ... }
//
// Every operation returns an Async_Handle. The handle is passed back to the
// callback together with the event kind. Results stay on the JS side until
// Jai asks for them (length probe, then read), exactly like the Dom module.

Async_Handle :: #type,distinct s32;
ASYNC_NULL :: cast(Async_Handle) 0;

// Keep this order in sync with `EVENT` in web/glue.js.
Async_Event :: enum s32 {
    HTTP_DONE;
    HTTP_ERROR;
    WS_OPEN;
    WS_MESSAGE;
    WS_CLOSE;
    WS_ERROR;
    TIMER;
    FRAME;
    WORKER_MESSAGE;
    WORKER_ERROR;
    CUSTOM;        // your own JS called host.handle(...).emit(); read it with custom_read_message
    CUSTOM_ERROR;  // host.handle(...).fail(); read it with async_read_error
}

Async_Callback :: #type (handle: Async_Handle, event: Async_Event, data: *void);

// ---------------------------------------------------------------------------
// Foreign host functions
// ---------------------------------------------------------------------------

js_http_fetch :: (url: *u8, url_length: s64, method: *u8, method_length: s64, headers: *u8, headers_length: s64, body: *u8, body_length: s64, timeout_ms: s32, callback: Async_Callback, data: *void) -> Async_Handle #foreign;
js_http_status :: (handle: Async_Handle) -> s32 #foreign;
js_http_body_length :: (handle: Async_Handle) -> s64 #foreign;
js_http_body_read :: (handle: Async_Handle, output: *u8, capacity: s64) -> s64 #foreign;
js_http_header_length :: (handle: Async_Handle, name: *u8, name_length: s64) -> s64 #foreign;
js_http_header_read :: (handle: Async_Handle, name: *u8, name_length: s64, output: *u8, capacity: s64) -> s64 #foreign;

js_ws_open :: (url: *u8, url_length: s64, protocols: *u8, protocols_length: s64, callback: Async_Callback, data: *void) -> Async_Handle #foreign;
js_ws_send_text :: (handle: Async_Handle, text: *u8, length: s64) -> s32 #foreign;
js_ws_send_binary :: (handle: Async_Handle, bytes: *u8, length: s64) -> s32 #foreign;
js_ws_close :: (handle: Async_Handle, code: s32, reason: *u8, reason_length: s64) #foreign;
js_ws_ready_state :: (handle: Async_Handle) -> s32 #foreign;
js_ws_close_code :: (handle: Async_Handle) -> s32 #foreign;

js_timer_set :: (milliseconds: s32, repeat: s32, callback: Async_Callback, data: *void) -> Async_Handle #foreign;
js_frame_request :: (callback: Async_Callback, data: *void) -> Async_Handle #foreign;
js_now_ms :: () -> float64 #foreign;

js_worker_spawn :: (url: *u8, url_length: s64, callback: Async_Callback, data: *void) -> Async_Handle #foreign;
js_worker_post :: (handle: Async_Handle, bytes: *u8, length: s64, binary: s32) -> s32 #foreign;

// Shared by WebSocket and Worker: a queue of received messages.
js_msg_length :: (handle: Async_Handle) -> s64 #foreign;
js_msg_is_binary :: (handle: Async_Handle) -> s32 #foreign;
js_msg_read :: (handle: Async_Handle, output: *u8, capacity: s64) -> s64 #foreign;

// Shared by HTTP, WebSocket and Worker: the last error text.
js_error_length :: (handle: Async_Handle) -> s64 #foreign;
js_error_read :: (handle: Async_Handle, output: *u8, capacity: s64) -> s64 #foreign;

// Aborts a request, closes a socket, terminates a worker, clears a timer or
// frame request, and forgets the handle. Safe on an already-finished handle.
js_async_cancel :: (handle: Async_Handle) #foreign;

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

Http_Request :: struct {
    url: string;
    method: string = "GET";
    // Request headers as lines of "Name: value" separated by newlines.
    headers: string;
    body: string;
    // 0 means no timeout.
    timeout_ms: s32;
}

// Starts a request. The callback gets HTTP_DONE (any HTTP status, including
// 404/500) or HTTP_ERROR (network failure, CORS, timeout, bad URL).
http_fetch :: (request: Http_Request, callback: Async_Callback, data: *void = null) -> Async_Handle {
    method := request.method;
    if method.count == 0 method = "GET";
    return js_http_fetch(
        request.url.data, request.url.count,
        method.data, method.count,
        request.headers.data, request.headers.count,
        request.body.data, request.body.count,
        request.timeout_ms, callback, data);
}

http_get :: (url: string, callback: Async_Callback, data: *void = null) -> Async_Handle {
    return http_fetch(.{ url = url }, callback, data);
}

http_post :: (url: string, body: string, content_type: string, callback: Async_Callback, data: *void = null) -> Async_Handle {
    headers := tprint("Content-Type: %", content_type);
    return http_fetch(.{ url = url, method = "POST", headers = headers, body = body }, callback, data);
}

http_status :: (handle: Async_Handle) -> s32 {
    return js_http_status(handle);
}

// Context-allocated; the caller frees it.
http_read_body :: (handle: Async_Handle) -> string {
    length := js_http_body_length(handle);
    if length <= 0 return "";

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_http_body_read(handle, space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder);
}

// Header names are case-insensitive. `ok` is false when the header is missing.
http_read_header :: (handle: Async_Handle, name: string) -> (value: string, ok: bool) {
    length := js_http_header_length(handle, name.data, name.count);
    if length < 0 return "", false;
    if length == 0 return "", true;

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_http_header_read(handle, name.data, name.count, space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder), true;
}

// Cancels an in-flight request, or releases a finished one. No callback fires
// after this. Always call it once you are done with a response.
http_free :: (handle: Async_Handle) {
    js_async_cancel(handle);
}
http_abort :: http_free;

// ---------------------------------------------------------------------------
// Errors (HTTP_ERROR, WS_ERROR, WORKER_ERROR)
// ---------------------------------------------------------------------------

async_read_error :: (handle: Async_Handle) -> string {
    length := js_error_length(handle);
    if length <= 0 return "";

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_error_read(handle, space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder);
}

// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

WS_CONNECTING :: 0;
WS_OPEN       :: 1;
WS_CLOSING    :: 2;
WS_CLOSED     :: 3;

// Events: WS_OPEN, WS_MESSAGE (then call ws_read_message), WS_ERROR, WS_CLOSE.
// `protocols` is a comma-separated list.
ws_open :: (url: string, callback: Async_Callback, data: *void = null, protocols: string = "") -> Async_Handle {
    return js_ws_open(url.data, url.count, protocols.data, protocols.count, callback, data);
}

ws_send_text :: (handle: Async_Handle, text: string) -> bool {
    return js_ws_send_text(handle, text.data, text.count) != 0;
}

ws_send_binary :: (handle: Async_Handle, bytes: [] u8) -> bool {
    return js_ws_send_binary(handle, bytes.data, bytes.count) != 0;
}

ws_close :: (handle: Async_Handle, code: s32 = 1000, reason: string = "") {
    js_ws_close(handle, code, reason.data, reason.count);
}

ws_ready_state :: (handle: Async_Handle) -> s32 {
    return js_ws_ready_state(handle);
}

ws_close_code :: (handle: Async_Handle) -> s32 {
    return js_ws_close_code(handle);
}

// Pops the oldest queued message. Call it until `ok` is false so none are
// left behind. Context-allocated; the caller frees `data`.
ws_read_message :: (handle: Async_Handle) -> (data: string, is_binary: bool, ok: bool) {
    return msg_read(handle);
}

// Releases the socket (closing it if still open). No callback fires after this.
ws_free :: (handle: Async_Handle) {
    js_async_cancel(handle);
}

// ---------------------------------------------------------------------------
// Timers and frames
// ---------------------------------------------------------------------------

// Fires TIMER once.
timer_after :: (milliseconds: s32, callback: Async_Callback, data: *void = null) -> Async_Handle {
    return js_timer_set(milliseconds, 0, callback, data);
}

// Fires TIMER repeatedly until timer_cancel.
timer_every :: (milliseconds: s32, callback: Async_Callback, data: *void = null) -> Async_Handle {
    return js_timer_set(milliseconds, 1, callback, data);
}

// Fires FRAME once before the next repaint (requestAnimationFrame).
frame_request :: (callback: Async_Callback, data: *void = null) -> Async_Handle {
    return js_frame_request(callback, data);
}

// Safe on a timer that already fired once or was already cancelled.
timer_cancel :: (handle: Async_Handle) {
    js_async_cancel(handle);
}
frame_cancel :: timer_cancel;

// Milliseconds on a monotonic clock (performance.now).
now_ms :: () -> float64 {
    return js_now_ms();
}

// ---------------------------------------------------------------------------
// Workers
// ---------------------------------------------------------------------------
//
// There are no OS threads in WASM, so a worker is a separate wasm module run
// in a module Worker. Its body is written in Jai (see the Worker module and
// echo_worker.jai); the page and the worker talk by copied messages.
// Events: WORKER_MESSAGE (then call worker_read_message) and WORKER_ERROR.

// `wasm_url` is the worker's wasm file, e.g. "./echo-worker.wasm".
worker_spawn :: (wasm_url: string, callback: Async_Callback, data: *void = null) -> Async_Handle {
    return js_worker_spawn(wasm_url.data, wasm_url.count, callback, data);
}

worker_post_text :: (handle: Async_Handle, text: string) -> bool {
    return js_worker_post(handle, text.data, text.count, 0) != 0;
}

worker_post_binary :: (handle: Async_Handle, bytes: [] u8) -> bool {
    return js_worker_post(handle, bytes.data, bytes.count, 1) != 0;
}

worker_read_message :: (handle: Async_Handle) -> (data: string, is_binary: bool, ok: bool) {
    return msg_read(handle);
}

worker_terminate :: (handle: Async_Handle) {
    js_async_cancel(handle);
}

// ---------------------------------------------------------------------------
// Custom host code (your own JavaScript)
// ---------------------------------------------------------------------------
//
// Declare your own foreign procedures and implement them in JS with
// start("./main.wasm", { env: host => ({ ... }) }) (see web/glue.js and
// examples/custom-js). A function that returns an Async_Handle gives Jai
// either a value to read once (host.value) or a stream of CUSTOM events
// (host.handle). Read each message with custom_read_message, errors with
// async_read_error, and release the handle with custom_free.

custom_read_message :: (handle: Async_Handle) -> (data: string, is_binary: bool, ok: bool) {
    return msg_read(handle);
}

custom_free :: (handle: Async_Handle) {
    js_async_cancel(handle);
}

// ---------------------------------------------------------------------------

#scope_file

msg_read :: (handle: Async_Handle) -> (data: string, is_binary: bool, ok: bool) {
    length := js_msg_length(handle);
    if length < 0 return "", false, false;
    binary := js_msg_is_binary(handle) != 0;
    if length == 0 {
        js_msg_read(handle, null, 0);  // pops the empty message
        return "", binary, true;
    }

    builder: String_Builder;
    space := ensure_contiguous_space_and_return_available_range(*builder, length);
    js_msg_read(handle, space.data, length);
    advance_through_ensured_space(*builder, length);
    return builder_to_string(*builder), binary, true;
}
