// Chat client in Jai/wasm. Talks to examples/server:
//   GET  /api/hello/:name   greeting on load
//   POST /api/echo          the "Echo" button
//   WS   /ws                chat, with automatic reconnect

#import "Basic";
#import "String";
#import "Web";

socket: Async_Handle;
status_node, log_node, input_node: DOM_Node;

app_main :: () {
    app := dom_find("#app");

    status_node = dom_create("p", .{ id = "status", text = "connecting..." });
    log_node    = dom_create("ul", .{ id = "log" });
    input_node  = dom_create("input", .{ id = "message" });
    dom_set_attribute(input_node, "placeholder", "say something");
    dom_on(input_node, "keydown", on_key);

    row := dom_create("div", .{ class = "row" });
    dom_insert(row, input_node);
    dom_insert(row, dom_create("button", .{ id = "send", text = "Send", onclick = on_send }));
    dom_insert(row, dom_create("button", .{ id = "echo", text = "Echo (POST)", onclick = on_echo }));

    dom_insert(app, status_node);
    dom_insert(app, log_node);
    dom_insert(app, row);

    http_get("/api/hello/jai", on_hello);
    connect();
}

add_line :: (text: string) {
    dom_insert(log_node, dom_create("li", .{ text = text }));
}

set_status :: (text: string) {
    dom_text(status_node, text);
}

// WebSocket URL for the page's own origin: http://host:port/... -> ws://host:port/ws
socket_url :: () -> string {
    url := dom_read_url();
    scheme_end := find_index_from_left(url, "://");
    if scheme_end < 0 return "ws://localhost/ws";
    rest := slice(url, scheme_end + 3, url.count - scheme_end - 3);
    host_end := find_index_from_left(rest, "/");
    host := ifx host_end < 0 then rest else slice(rest, 0, host_end);
    scheme := ifx begins_with(url, "https") then "wss" else "ws";
    return tprint("%://%/ws", scheme, host);
}

connect :: () {
    socket = ws_open(socket_url(), on_socket);
}

on_socket :: (handle: Async_Handle, event: Async_Event, data: *void) {
    if event == .WS_OPEN {
        set_status("connected");
    } else if event == .WS_MESSAGE {
        message, is_binary, ok := ws_read_message(handle);
        while ok {
            add_line(message);
            message, is_binary, ok = ws_read_message(handle);
        }
    } else if event == .WS_CLOSE {
        set_status("disconnected, retrying...");
        ws_free(handle);
        socket = ASYNC_NULL;
        timer_after(1000, on_retry);
    }
}

on_retry :: (handle: Async_Handle, event: Async_Event, data: *void) {
    connect();
}

on_hello :: (handle: Async_Handle, event: Async_Event, data: *void) {
    defer http_free(handle);
    if event == .HTTP_ERROR return;
    add_line(tprint("api: %", http_read_body(handle)));
}

on_echo_reply :: (handle: Async_Handle, event: Async_Event, data: *void) {
    defer http_free(handle);
    if event == .HTTP_ERROR return;
    add_line(tprint("api: %", http_read_body(handle)));
}

take_input :: () -> string, bool {
    text, ok := dom_read_value(input_node);
    if !ok || text.count == 0 return "", false;
    dom_set_value(input_node, "");
    return text, true;
}

on_send :: (data: *void) {
    text, ok := take_input();
    if ok && socket != ASYNC_NULL ws_send_text(socket, text);
}

on_echo :: (data: *void) {
    text, ok := take_input();
    if ok http_post("/api/echo", text, "text/plain", on_echo_reply);
}

on_key :: (data: *void) {
    key, ok := dom_read_event_key();
    if ok && key == "Enter" on_send(null);
}

#program_export "app_init"
app_init :: () #c_call #no_context { with_wasm_context(#code { app_main(); }); }
