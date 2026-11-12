// Calling your own JavaScript (window.*, navigator.*, any browser API) from Jai.
// The JS side is host.js; index.html passes it to start().
#import "Basic";
#import "Web";

// Implemented in host.js. Same name, same argument order; s64/pointers are BigInt there.
js_set_title        :: (text: *u8, length: s64) #foreign;
js_window_size      :: () -> Async_Handle #foreign;
js_window_on_resize :: (callback: Async_Callback, data: *void = null) -> Async_Handle #foreign;
js_clipboard_write  :: (text: *u8, length: s64, callback: Async_Callback, data: *void = null) -> Async_Handle #foreign;

resize_handle: Async_Handle;

show :: (id: string, text: string) {
    dom_text(dom_find(id), text);
}

app_main :: () {
    title := "jaidom custom-js";
    js_set_title(title.data, title.count);

    // A value: read it once, then free the handle.
    size_handle := js_window_size();
    size, binary, ok := custom_read_message(size_handle);
    custom_free(size_handle);
    show("#size", tprint("window: %", size));

    // A stream: CUSTOM events until custom_free.
    resize_handle = js_window_on_resize(on_resize);

    dom_on(dom_find("#copy"), "click", on_copy_clicked);
}

on_resize :: (handle: Async_Handle, event: Async_Event, data: *void) {
    if event != .CUSTOM return;
    size, binary, ok := custom_read_message(handle);
    show("#size", tprint("window: % (resized)", size));
}

on_copy_clicked :: (data: *void) {
    text := "hello from Jai";
    js_clipboard_write(text.data, text.count, on_copied);
}

on_copied :: (handle: Async_Handle, event: Async_Event, data: *void) {
    defer custom_free(handle);
    if event == .CUSTOM {
        message, binary, ok := custom_read_message(handle);
        show("#status", message);
    } else if event == .CUSTOM_ERROR {
        show("#status", tprint("failed: %", async_read_error(handle)));
    }
}

#program_export "app_init"
app_init :: () #c_call #no_context { with_wasm_context(#code { app_main(); }); }
