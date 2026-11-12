// Your own host functions. Each name here is declared `#foreign` in main.jai.
// Pointers and s64 arrive as BigInt; s32 as Number. Strings: host.string(ptr, len).
export default host => ({
    // void: fire and forget.
    js_set_title(text, length) {
        document.title = host.string(text, length);
    },

    // A value Jai reads once: returns an Async_Handle.
    js_window_size() {
        return host.value(`${innerWidth}x${innerHeight}`);
    },

    // A stream: every resize becomes a CUSTOM event for the Jai callback.
    js_window_on_resize(callback, data) {
        const h = host.handle(callback, data);
        const listener = () => h.emit(`${innerWidth}x${innerHeight}`);
        window.addEventListener("resize", listener);
        h.onClose = () => window.removeEventListener("resize", listener);   // custom_free()
        return h.id;
    },

    // A one-shot async call: a promise becomes CUSTOM (done) or CUSTOM_ERROR.
    js_clipboard_write(text, length, callback, data) {
        const h = host.handle(callback, data);
        navigator.clipboard.writeText(host.string(text, length))
            .then(() => h.emit("copied"), error => h.fail(error));
        return h.id;
    },
});
