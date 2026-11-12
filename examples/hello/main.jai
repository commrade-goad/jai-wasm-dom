// Smallest useful app: fetch a file over HTTP and show it.
#import "Basic";
#import "Web";

app_main :: () {
    dom_text(dom_find("#out"), "loading…");
    http_get("./index.html", on_response);
}

on_response :: (handle: Async_Handle, event: Async_Event, data: *void) {
    defer http_free(handle);

    out := dom_find("#out");
    if event == .HTTP_ERROR {
        dom_text(out, tprint("network error: %", async_read_error(handle)));
        return;
    }

    body := http_read_body(handle);
    defer free(body);
    dom_text(out, tprint("HTTP % — % bytes", http_status(handle), body.count));
}

#program_export "app_init"
app_init :: () #c_call #no_context { with_wasm_context(#code { app_main(); }); }
