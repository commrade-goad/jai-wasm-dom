Runtime :: #import "Runtime_Support";

wasm_context: *#Context;

ensure_wasm_context :: () -> bool #no_context {
    if !wasm_context wasm_context = Runtime.__jai_runtime_init(0, null);
    return wasm_context != null;
}

with_wasm_context :: (body: Code) #expand {
    if !ensure_wasm_context() return;
    push_context wasm_context.* {
        defer reset_temporary_storage();
        #insert body;
    }
}

