// Web: everything a Jai program needs to run in the browser as wasm64.
//
//     #import "Web";
//
//     app_main :: () {                      // your entry point
//         http_get("/api/items", on_items);
//     }
//
//     #program_export "app_init"            // the one line of glue the host calls
//     app_init :: () #c_call #no_context { with_wasm_context(#code { app_main(); }); }
//
// One import gives you the DOM (dom_*), HTTP/WebSocket/timers/frames/workers
// (http_get, ws_open, timer_after, worker_spawn, ...), and the runtime
// plumbing (with_wasm_context and the callback dispatchers, which the module
// exports itself). Programs that run inside a Web Worker use the same module;
// see worker.jai.

#import "Basic";

#load "context.jai";
#load "dom.jai";
#load "async.jai";
#load "worker.jai";
