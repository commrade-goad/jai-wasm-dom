#import "Basic";

// Worker side of the Async module: write the body of a Web Worker in Jai.
//
// A Jai worker is its own wasm module. `web/worker-glue.js` (generic, no app
// code) instantiates it inside a module Worker and forwards messages. A worker
// program looks like this (full example: examples/selftest/echo_worker.jai):
//
//     #import "Web";
//
//     worker_main :: () { worker_on_message(on_message); }   // runs once at start
//     on_message :: (message: string, is_binary: bool) { worker_reply_text(message); }
//
//     #program_export "worker_init"
//     worker_init :: () #c_call #no_context { with_wasm_context(#code { worker_main(); }); }
//
// The page starts it with `worker_spawn("./my-worker.wasm", callback)`.

Worker_Callback :: #type (message: string, is_binary: bool);

// Foreign host functions (see worker-glue.js).
js_worker_reply :: (bytes: *u8, length: s64, binary: s32) #foreign;
js_worker_close :: () #foreign;

// Sets the function run for every message the page posts.
// `message` points at a host buffer that is only valid during the call; copy it
// (copy_string) if you need to keep it.
worker_on_message :: (callback: Worker_Callback) {
    worker_keep_exports();
    message_handler = callback;
}

// Sends a message to the page (it arrives as WORKER_MESSAGE).
worker_reply_text :: (text: string) {
    js_worker_reply(text.data, text.count, 0);
}

worker_reply_binary :: (bytes: [] u8) {
    js_worker_reply(bytes.data, bytes.count, 1);
}

// Stops this worker (like self.close()).
worker_exit :: () {
    js_worker_close();
}

// Called from the jai_worker_dispatch export.
worker_dispatch :: (data: *u8, length: s64, is_binary: bool) {
    if !message_handler return;
    message: string;
    message.data = data;
    message.count = length;
    message_handler(message, is_binary);
}

#scope_file

message_handler: Worker_Callback;

// Keeps the dispatcher export alive; reached through the worker callbacks.
worker_keep_exports :: () #no_context {
    a := jai_worker_dispatch;
}

#program_export "jai_worker_dispatch"
jai_worker_dispatch :: (data: *u8, length: s64, is_binary: s32) #c_call #no_context {
    with_wasm_context(#code { worker_dispatch(data, length, is_binary != 0); });
}
