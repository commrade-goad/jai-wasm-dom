// Browser self-test for the Async module. Runs when the page is opened with
// ?selftest. It expects test/server.py (HTTP + WebSocket echo) and prints
// "SELFTEST ..." lines to the console; test/run.py reads them.

selftest_passed: s32;
selftest_failed: s32;
selftest_pending: s32;

selftest_check :: (ok: bool, name: string) {
    if ok {
        selftest_passed += 1;
        print("SELFTEST PASS %\n", name);
    } else {
        selftest_failed += 1;
        print("SELFTEST FAIL %\n", name);
    }
}

selftest_begin :: () {
    selftest_pending += 1;
}

selftest_end :: () {
    selftest_pending -= 1;
    if selftest_pending == 0 {
        print("SELFTEST DONE passed=% failed=%\n", selftest_passed, selftest_failed);
    }
}

// --- HTTP ------------------------------------------------------------------

st_http_get :: (handle: Async_Handle, event: Async_Event, data: *void) {
    selftest_check(event == .HTTP_DONE, "http get: done event");
    selftest_check(http_status(handle) == 200, "http get: status 200");
    body := http_read_body(handle);
    selftest_check(body.count > 8 && body[0] == 0 && body[1] == #char "a" && body[2] == #char "s" && body[3] == #char "m", "http get: binary body is wasm");
    content_type, has_type := http_read_header(handle, "Content-Type");
    selftest_check(has_type && contains(content_type, "wasm"), "http get: response header");
    missing_value, has_missing := http_read_header(handle, "X-Not-There");
    selftest_check(!has_missing, "http get: missing header");
    http_free(handle);
    selftest_end();
}

st_http_404 :: (handle: Async_Handle, event: Async_Event, data: *void) {
    selftest_check(event == .HTTP_DONE && http_status(handle) == 404, "http 404 is DONE with status 404");
    http_free(handle);
    selftest_end();
}

st_http_refused :: (handle: Async_Handle, event: Async_Event, data: *void) {
    selftest_check(event == .HTTP_ERROR, "http network failure is HTTP_ERROR");
    selftest_check(async_read_error(handle).count > 0, "http error has text");
    http_free(handle);
    selftest_end();
}

st_http_post :: (handle: Async_Handle, event: Async_Event, data: *void) {
    selftest_check(event == .HTTP_DONE && http_status(handle) == 200, "http post: done");
    body := http_read_body(handle);
    selftest_check(body == "{\"a\":1,\"é\":\"ü\"}", "http post: body round trip (utf-8)");
    echoed, ok := http_read_header(handle, "X-Echo-Content-Type");
    selftest_check(ok && echoed == "application/json", "http post: request header arrived");
    http_free(handle);
    selftest_end();
}

st_http_timeout :: (handle: Async_Handle, event: Async_Event, data: *void) {
    selftest_check(event == .HTTP_ERROR, "http timeout: error event");
    selftest_check(async_read_error(handle) == "timeout", "http timeout: error text");
    http_free(handle);
    selftest_end();
}

abort_fired: bool;
st_http_must_not_fire :: (handle: Async_Handle, event: Async_Event, data: *void) {
    abort_fired = true;
}

// --- Timers and frames -----------------------------------------------------

timer_started_at: float64;
st_timer_after :: (handle: Async_Handle, event: Async_Event, data: *void) {
    elapsed := now_ms() - timer_started_at;
    selftest_check(event == .TIMER && elapsed >= 40, "timer_after fires after the delay");
    selftest_end();
}

every_count: s32;
st_timer_every :: (handle: Async_Handle, event: Async_Event, data: *void) {
    every_count += 1;
    if every_count == 3 {
        timer_cancel(handle);
        selftest_check(true, "timer_every fires repeatedly, then cancels");
        selftest_end();
    }
}

cancelled_fired: bool;
st_timer_must_not_fire :: (handle: Async_Handle, event: Async_Event, data: *void) {
    cancelled_fired = true;
}

st_frame :: (handle: Async_Handle, event: Async_Event, data: *void) {
    selftest_check(event == .FRAME, "frame_request fires");
    selftest_end();
}

st_check_cancellations :: (handle: Async_Handle, event: Async_Event, data: *void) {
    selftest_check(!cancelled_fired, "cancelled timer never fires");
    selftest_check(!abort_fired, "aborted request never calls back");
    selftest_end();
}

// --- WebSocket -------------------------------------------------------------

ws_stage: s32;
st_ws :: (handle: Async_Handle, event: Async_Event, data: *void) {
    if event == .WS_OPEN {
        selftest_check(ws_ready_state(handle) == WS_OPEN, "ws: open");
        ws_send_text(handle, "hello ü");
    } else if event == .WS_MESSAGE {
        message, is_binary, ok := ws_read_message(handle);
        while ok {
            if ws_stage == 0 {
                selftest_check(!is_binary && message == "hello ü", "ws: text echo");
                ws_stage = 1;
                ws_send_binary(handle, u8.[1, 2, 3, 255]);
            } else if ws_stage == 1 {
                selftest_check(is_binary && message.count == 4 && message[3] == 255, "ws: binary echo");
                ws_stage = 2;
                ws_close(handle, 1000, "bye");
            }
            message, is_binary, ok = ws_read_message(handle);
        }
    } else if event == .WS_CLOSE {
        selftest_check(ws_close_code(handle) == 1000, "ws: clean close code");
        ws_free(handle);
        selftest_end();
    }
}

st_ws_bad :: (handle: Async_Handle, event: Async_Event, data: *void) {
    if event == .WS_ERROR {
        selftest_check(true, "ws: bad url reports WS_ERROR");
    } else if event == .WS_CLOSE {
        selftest_check(ws_ready_state(handle) == WS_CLOSED, "ws: bad url ends CLOSED");
        ws_free(handle);
        selftest_end();
    }
}

// --- Worker ----------------------------------------------------------------

st_worker_phase: s32;

st_worker :: (handle: Async_Handle, event: Async_Event, data: *void) {
    if event == .WORKER_MESSAGE {
        message, is_binary, ok := worker_read_message(handle);
        if st_worker_phase == 0 {
            selftest_check(ok && !is_binary && message == "echo:ping ü", "worker (Jai): text round trip");
            st_worker_phase = 1;
            worker_post_binary(handle, .[1, 2, 255]);
        } else {
            selftest_check(ok && is_binary && message.count == 3 && message[0] == 2 && message[1] == 3 && message[2] == 0, "worker (Jai): binary round trip");
            worker_terminate(handle);
            selftest_end();
        }
    } else if event == .WORKER_ERROR {
        selftest_check(false, tprint("worker: error event: %", async_read_error(handle)));
        selftest_end();
    }
}

st_worker_bad :: (handle: Async_Handle, event: Async_Event, data: *void) {
    if event == .WORKER_ERROR {
        selftest_check(true, "worker: missing wasm reports WORKER_ERROR");
        worker_terminate(handle);
        selftest_end();
    }
}

// --- Event info ------------------------------------------------------------

st_key :: (data: *void) {
    key, ok := dom_read_event_key();
    selftest_check(ok && key == "x", "event: key readable");
    dom_event_prevent_default();
}

st_window :: (data: *void) {
    selftest_check(true, "window listener: hashchange handler ran");
}

// ---------------------------------------------------------------------------

async_selftest :: () {
    // Window listeners (popstate/hashchange/resize) share the DOM_Callback signature.
    dom_on_window("hashchange", st_window);

    // localStorage (synchronous).
    selftest_check(storage_set("selftest", "héllo"), "storage: set");
    value, found := storage_read("selftest");
    selftest_check(found && value == "héllo", "storage: read");
    storage_remove("selftest");
    removed_value, still_found := storage_read("selftest");
    selftest_check(!still_found, "storage: remove");

    // Event info.
    main := dom_find("#main");
    if main != DOM_NULL dom_on(main, "keydown", st_key);

    // HTTP.
    selftest_begin(); http_get("./main.wasm", st_http_get);
    selftest_begin(); http_get("./does-not-exist", st_http_404);
    selftest_begin(); http_get("http://127.0.0.1:1/", st_http_refused);
    selftest_begin(); http_post("./echo", "{\"a\":1,\"é\":\"ü\"}", "application/json", st_http_post);
    selftest_begin(); http_fetch(.{ url = "./slow", timeout_ms = 100 }, st_http_timeout);

    aborted := http_get("./slow", st_http_must_not_fire);
    http_abort(aborted);

    // Timers and frames.
    timer_started_at = now_ms();
    selftest_begin(); timer_after(50, st_timer_after);
    selftest_begin(); timer_every(20, st_timer_every);
    cancelled := timer_after(30, st_timer_must_not_fire);
    timer_cancel(cancelled);
    selftest_begin(); frame_request(st_frame);
    selftest_begin(); timer_after(400, st_check_cancellations);

    // WebSocket.
    selftest_begin(); ws_open("ws://127.0.0.1:8765/", st_ws);
    selftest_begin(); ws_open("ws://127.0.0.1:8765/#fragment", st_ws_bad);  // fragments make the constructor throw
    selftest_begin(); ws_open("ws://127.0.0.1:1/", st_ws_bad);

    // Worker.
    worker := worker_spawn("./echo-worker.wasm", st_worker);
    selftest_begin(); worker_post_text(worker, "ping ü");
    selftest_begin(); worker_spawn("./no-such-worker.wasm", st_worker_bad);
}
