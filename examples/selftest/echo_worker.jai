#import "Basic";
#import "Web";

// Example worker written in Jai, used by selftest.jai.
//   text message   -> replies "echo:" + text
//   binary message -> replies the same bytes, each incremented by one

worker_main :: () {
    worker_on_message(on_message);
}

on_message :: (message: string, is_binary: bool) {
    if !is_binary {
        worker_reply_text(tprint("echo:%", message));
        return;
    }

    bytes: [] u8 = .{ count = message.count, data = message.data };
    result := NewArray(bytes.count, u8);
    defer array_free(result);
    for bytes result[it_index] = it + 1;
    worker_reply_binary(result);
}

#program_export "worker_init"
worker_init :: () #c_call #no_context { with_wasm_context(#code { worker_main(); }); }
