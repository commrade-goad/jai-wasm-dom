Runtime :: #import "Runtime_Support";

// The Jai runtime context that every callback from the host runs inside.
// It is created lazily on the first call from JavaScript and then reused.
wasm_context: *#Context;

ensure_wasm_context :: () -> bool #no_context {
    if !wasm_context wasm_context = Runtime.__jai_runtime_init(0, null);
    return wasm_context != null;
}

// Runs `body` with the persistent context and frees temporary storage after.
// Use it in any #c_call #no_context entry point.
with_wasm_context :: (body: Code) #expand {
    web_keep_exports();
    if !ensure_wasm_context() return;
    push_context wasm_context.* {
        defer reset_temporary_storage();
        #insert body;
    }
}

// Entry points the JavaScript host calls for the callbacks you register.
// (The program itself only exports `app_init`; see module.jai.)
#program_export "jai_dom_event_dispatch"
jai_dom_event_dispatch :: (callback: DOM_Callback, element: DOM_Node, data: *void) #c_call #no_context {
    with_wasm_context(#code { callback(data); });
}

#program_export "jai_async_dispatch"
jai_async_dispatch :: (callback: Async_Callback, handle: Async_Handle, event: s32, data: *void) #c_call #no_context {
    with_wasm_context(#code { callback(handle, cast(Async_Event) event, data); });
}

// Referencing the dispatchers keeps their #program_export alive; every program
// reaches this through with_wasm_context.
web_keep_exports :: () #no_context {
    a := jai_dom_event_dispatch;
    b := jai_async_dispatch;
}
