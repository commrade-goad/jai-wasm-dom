# jaidom

Write browser apps in Jai: DOM, HTTP, WebSocket, timers, frames and Web Workers
from one import, compiled to wasm64 with [Jacket](https://github.com/matteopolak/jacket).
Demo: https://commrade-goad.github.io/jai-wasm-dom/

## Layout

```
modules/Web/        the library: #import "Web" gives you dom_*, http_*, ws_*, timer_*, worker_*
modules/Web_Build/  build-time helper: build_wasm(...)
modules/Template/   .jaix templates -> Jai (used by Web_Build)
web/                JS host: glue.js (page), worker-glue.js (workers), runtime.js (shared)
examples/hello      smallest app: one HTTP request
examples/custom-js   calling your own JavaScript (window.*, navigator.*) from Jai
examples/todos      counter + todo list with .jaix templates
examples/selftest   Async/Worker self-test (python3 examples/selftest/test/run.py)
```

## A new app in three files

`main.jai`
```jai
#import "Basic";
#import "Web";

app_main :: () {                                   // runs once after the wasm loads
    http_get("./data.txt", on_response);
}

on_response :: (handle: Async_Handle, event: Async_Event, data: *void) {
    defer http_free(handle);
    if event == .HTTP_ERROR return;
    dom_text(dom_find("#out"), http_read_body(handle));
}

#program_export "app_init"                         // the host calls this
app_init :: () #c_call #no_context { with_wasm_context(#code { app_main(); }); }
```

`build.jai`
```jai
#import "Web_Build";
#run build_wasm("main", "main.jai", .["view.jaix"], #filepath);   // jaix list is optional
```

`index.html`
```html
<main id="main"></main>
<script type="module">
    import { start } from "/path/to/web/glue.js";
    start("./main.wasm");
</script>
```

Build: `cd myapp && jaic build.jai -import_dir /path/to/jaidom/modules`
(`JAIC_WASM_LD=/usr/lib/llvm-20/bin/wasm-ld`). `./build.sh [dir...]` builds the examples.
Older `wasm-ld` emits a 32-bit function table that browsers reject for wasm64.

## What `#import "Web"` gives you

| Area | Calls |
|---|---|
| DOM | `dom_find`, `dom_find_in`, `dom_create`, `dom_insert`, `dom_text`, `dom_set_attribute`, `dom_on`, `dom_on_window`, `dom_read_value`, `dom_read_param`, `dom_event_prevent_default`, `dom_read_event_key`, `storage_set/read/remove`, ... |
| Templates | `.jaix` files become procedures such as `TodoRow(id, text, done)` returning a `DOM_Node` |
| HTTP | `http_get`, `http_post`, `http_fetch(Http_Request{url, method, headers, body, timeout_ms})`, `http_status`, `http_read_body`, `http_read_header`, `http_abort`/`http_free` |
| WebSocket | `ws_open`, `ws_send_text`, `ws_send_binary`, `ws_close`, `ws_ready_state`, `ws_close_code`, `ws_read_message` (loop until `ok` is false), `ws_free` |
| Timers | `timer_after`, `timer_every`, `timer_cancel`, `frame_request`, `now_ms` |
| Workers | `worker_spawn(wasm_url)`, `worker_post_text/binary`, `worker_read_message`, `worker_terminate` |
| Your own JS | `custom_read_message`, `custom_free`, events `CUSTOM` / `CUSTOM_ERROR` (see below) |

Async callbacks are `(handle, event: Async_Event, data: *void)`. Results stay on the JS side until
read, so call `http_free` / `ws_free` / `worker_terminate` when done. The module exports its own
callback dispatchers; the one export your program writes is `app_init`.

## Workers in Jai

A worker is its own wasm program in a module Worker. `web/worker-glue.js` is a generic host with no app code.

```jai
#import "Basic";
#import "Web";

worker_main :: () { worker_on_message(on_message); }

on_message :: (message: string, is_binary: bool) {   // `message` is only valid during the call
    worker_reply_text(tprint("echo:%", message));
}

#program_export "worker_init"
worker_init :: () #c_call #no_context { with_wasm_context(#code { worker_main(); }); }
```
Build it with another `build_wasm("echo-worker", "echo_worker.jai", ...)` line and start it from the page
with `worker_spawn("./echo-worker.wasm", callback)`. Workers share no memory with the page and exchange copied messages.

## Your own JavaScript (`window.*`, `navigator.*`, anything)

Instead of an `eval`, you write host functions in JS and call them from Jai as `#foreign` procedures.
`start()` takes them in `env`; names that clash with built-ins are rejected. See `examples/custom-js`.

```js
// host.js
export default host => ({
    js_set_title(text, length) { document.title = host.string(text, length); },       // void
    js_window_size() { return host.value(`${innerWidth}x${innerHeight}`); },          // value -> Async_Handle
    js_window_on_resize(callback, data) {                                             // stream -> Async_Handle
        const h = host.handle(callback, data);
        const on = () => h.emit(`${innerWidth}x${innerHeight}`);
        addEventListener("resize", on);
        h.onClose = () => removeEventListener("resize", on);                          // runs on custom_free()
        return h.id;
    },
});
// index.html:  import host from "./host.js";  start("./main.wasm", { env: host });
```
```jai
js_set_title        :: (text: *u8, length: s64) #foreign;
js_window_size      :: () -> Async_Handle #foreign;
js_window_on_resize :: (callback: Async_Callback, data: *void = null) -> Async_Handle #foreign;

size, is_binary, ok := custom_read_message(js_window_size());   // then custom_free(handle)
// streams call your Async_Callback with .CUSTOM (read it) or .CUSTOM_ERROR (async_read_error)
```

`host` gives you `string(ptr, len)`, `bytes(ptr, len)` (a copy), `dom(id)` / `domId(element)` to convert Jai DOM handles,
`value(payload)`, `handle(callback, data)` (`emit`, `fail`, `onClose`) and `exports` (the program's wasm exports).
Pointers and `s64` cross the boundary as `BigInt`, `s32` as `Number`; this applies to what you return too.
A payload is a string, bytes, or anything JSON-able. Promises map to `h.emit(...)` / `h.fail(error)`.
