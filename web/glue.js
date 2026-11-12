import { createRuntime } from "./runtime.js";

const rt = createRuntime();
const { offset, view, stringAt, writeStringResult, writeBytesResult, encoder } = rt;
const domNodes = new Map();
const domNodeIds = new WeakMap();
let nextDomId = 1;
let api = null;   // exports of the running Jai program, set by start()

function commitUrl(url, replace) {
    const target = url.pathname + url.search + url.hash;
    if (replace) history.replaceState(null, "", target);
    else history.pushState(null, "", target);
}

function node(id) {
    const result = domNodes.get(id);
    if (!result) throw new Error(`Unknown Jai DOM handle ${id}`);
    return result;
}

function registerNode(element) {
    const existing = domNodeIds.get(element);
    if (existing !== undefined) return existing;
    const id = nextDomId++;
    domNodes.set(id, element);
    domNodeIds.set(element, id);
    return id;
}

// ---------------------------------------------------------------------------
// Async host: fetch, WebSocket, timers, frames, workers.
// Every operation is an entry in `asyncHandles`, addressed by an s32 handle.
// Results stay here until Jai asks for them (length probe, then read).
// ---------------------------------------------------------------------------

// Keep this order in sync with Async_Event in modules/Web/async.jai.
const EVENT = {
    HTTP_DONE: 0, HTTP_ERROR: 1, WS_OPEN: 2, WS_MESSAGE: 3, WS_CLOSE: 4,
    WS_ERROR: 5, TIMER: 6, FRAME: 7, WORKER_MESSAGE: 8, WORKER_ERROR: 9,
    CUSTOM: 10, CUSTOM_ERROR: 11,
};

const asyncHandles = new Map();
let nextAsyncId = 1;
let currentEvent = null;

function newAsync(entry) {
    const id = nextAsyncId++;
    asyncHandles.set(id, entry);
    return id;
}

function asyncEntry(id, kind) {
    const entry = asyncHandles.get(id);
    return entry && (kind === undefined || entry.kind === kind) ? entry : null;
}

// Callbacks never fire for a handle that was cancelled or freed.
function asyncDispatch(callback, id, event, data) {
    if (!asyncHandles.has(id)) return;
    try {
        api.jai_async_dispatch(callback, id, event, data);
    } catch (error) {
        console.error("Jai async callback failed:", error);
    }
}

function parseHeaderBlock(text) {
    const headers = new Headers();
    for (const line of text.split("\n")) {
        const colon = line.indexOf(":");
        if (colon <= 0) continue;
        headers.append(line.slice(0, colon).trim(), line.slice(colon + 1).trim());
    }
    return headers;
}

function toBytes(data) {
    if (typeof data === "string") return { binary: false, bytes: encoder.encode(data) };
    if (data instanceof ArrayBuffer) return { binary: true, bytes: new Uint8Array(data) };
    if (ArrayBuffer.isView(data)) return { binary: true, bytes: new Uint8Array(data.buffer, data.byteOffset, data.byteLength) };
    return { binary: false, bytes: encoder.encode(JSON.stringify(data)) };
}

function errorText(error) {
    return encoder.encode(String((error && error.message) || error || "unknown error"));
}

const asyncImports = {
    js_http_fetch(url, urlLength, method, methodLength, headers, headersLength, body, bodyLength, timeoutMs, callback, data) {
        const controller = new AbortController();
        const entry = { kind: "http", status: 0, headers: null, body: null, error: null, timedOut: false };
        const id = newAsync(entry);

        const init = { method: stringAt(method, methodLength) || "GET", signal: controller.signal };
        const headerText = stringAt(headers, headersLength);
        if (headerText) init.headers = parseHeaderBlock(headerText);
        // Copy now: WASM memory may move before the request is sent.
        if (offset(bodyLength) > 0) init.body = view(body, bodyLength).slice();
        entry.controller = controller;

        let timer = 0;
        if (timeoutMs > 0) {
            timer = setTimeout(() => { entry.timedOut = true; controller.abort(); }, timeoutMs);
        }

        fetch(stringAt(url, urlLength), init)
            .then(async response => {
                entry.status = response.status;
                entry.headers = response.headers;
                entry.body = new Uint8Array(await response.arrayBuffer());
                return EVENT.HTTP_DONE;
            })
            .catch(error => {
                entry.error = entry.timedOut ? encoder.encode("timeout") : errorText(error);
                return EVENT.HTTP_ERROR;
            })
            .then(event => {
                clearTimeout(timer);
                asyncDispatch(callback, id, event, data);
            });
        return id;
    },
    js_http_status(id) {
        const entry = asyncEntry(id, "http");
        return entry ? entry.status : 0;
    },
    js_http_body_length(id) {
        const entry = asyncEntry(id, "http");
        return entry && entry.body ? BigInt(entry.body.length) : -1n;
    },
    js_http_body_read(id, output, capacity) {
        const entry = asyncEntry(id, "http");
        return writeBytesResult(entry && entry.body, output, capacity);
    },
    js_http_header_length(id, name, nameLength) {
        const entry = asyncEntry(id, "http");
        const value = entry && entry.headers ? entry.headers.get(stringAt(name, nameLength)) : null;
        return value === null ? -1n : BigInt(encoder.encode(value).length);
    },
    js_http_header_read(id, name, nameLength, output, capacity) {
        const entry = asyncEntry(id, "http");
        const value = entry && entry.headers ? entry.headers.get(stringAt(name, nameLength)) : null;
        return writeBytesResult(value === null ? null : encoder.encode(value), output, capacity);
    },

    js_ws_open(url, urlLength, protocols, protocolsLength, callback, data) {
        const entry = { kind: "ws", socket: null, queue: [], closeCode: 0, error: null };
        const id = newAsync(entry);
        const list = stringAt(protocols, protocolsLength).split(",").map(p => p.trim()).filter(Boolean);
        try {
            const socket = list.length ? new WebSocket(stringAt(url, urlLength), list) : new WebSocket(stringAt(url, urlLength));
            socket.binaryType = "arraybuffer";
            entry.socket = socket;
            socket.addEventListener("open", () => asyncDispatch(callback, id, EVENT.WS_OPEN, data));
            socket.addEventListener("message", e => {
                entry.queue.push(toBytes(e.data));
                asyncDispatch(callback, id, EVENT.WS_MESSAGE, data);
            });
            socket.addEventListener("error", () => {
                entry.error = encoder.encode("WebSocket error");
                asyncDispatch(callback, id, EVENT.WS_ERROR, data);
            });
            socket.addEventListener("close", e => {
                entry.closeCode = e.code;
                asyncDispatch(callback, id, EVENT.WS_CLOSE, data);
            });
        } catch (error) {
            // Bad URL or protocol: report asynchronously, like a failed connect.
            entry.error = errorText(error);
            entry.closeCode = 1006;
            setTimeout(() => {
                asyncDispatch(callback, id, EVENT.WS_ERROR, data);
                asyncDispatch(callback, id, EVENT.WS_CLOSE, data);
            }, 0);
        }
        return id;
    },
    js_ws_send_text(id, text, length) {
        const entry = asyncEntry(id, "ws");
        if (!entry || !entry.socket || entry.socket.readyState !== 1) return 0;
        entry.socket.send(stringAt(text, length));
        return 1;
    },
    js_ws_send_binary(id, bytes, length) {
        const entry = asyncEntry(id, "ws");
        if (!entry || !entry.socket || entry.socket.readyState !== 1) return 0;
        entry.socket.send(view(bytes, length).slice());
        return 1;
    },
    js_ws_close(id, code, reason, reasonLength) {
        const entry = asyncEntry(id, "ws");
        if (!entry || !entry.socket) return;
        try {
            const text = stringAt(reason, reasonLength);
            if (text) entry.socket.close(code, text);
            else entry.socket.close(code);
        } catch (error) {
            console.error("WebSocket close failed:", error);
        }
    },
    js_ws_ready_state(id) {
        const entry = asyncEntry(id, "ws");
        return entry && entry.socket ? entry.socket.readyState : 3;
    },
    js_ws_close_code(id) {
        const entry = asyncEntry(id, "ws");
        return entry ? entry.closeCode : 0;
    },

    js_timer_set(milliseconds, repeat, callback, data) {
        const entry = { kind: "timer", native: 0, repeat: repeat !== 0 };
        const id = newAsync(entry);
        const fire = () => {
            if (!entry.repeat) asyncHandles.delete(id);
            else if (!asyncHandles.has(id)) return;
            try {
                api.jai_async_dispatch(callback, id, EVENT.TIMER, data);
            } catch (error) {
                console.error("Jai async callback failed:", error);
            }
        };
        entry.native = entry.repeat ? setInterval(fire, milliseconds) : setTimeout(fire, milliseconds);
        return id;
    },
    js_frame_request(callback, data) {
        const entry = { kind: "frame", native: 0 };
        const id = newAsync(entry);
        entry.native = requestAnimationFrame(() => {
            if (!asyncHandles.has(id)) return;
            asyncDispatch(callback, id, EVENT.FRAME, data);
            asyncHandles.delete(id);
        });
        return id;
    },
    js_now_ms() { return performance.now(); },

    js_worker_spawn(url, urlLength, callback, data) {
        const entry = { kind: "worker", worker: null, queue: [], error: null };
        const id = newAsync(entry);
        try {
            // The worker body is a Jai wasm module; worker-glue.js just hosts it.
            const wasmUrl = new URL(stringAt(url, urlLength), location.href).href;
            const worker = new Worker(new URL("./worker-glue.js", import.meta.url), { type: "module", name: wasmUrl });
            entry.worker = worker;
            worker.onmessage = e => {
                entry.queue.push(toBytes(e.data));
                asyncDispatch(callback, id, EVENT.WORKER_MESSAGE, data);
            };
            worker.onerror = e => {
                entry.error = errorText(e.message || "worker error");
                asyncDispatch(callback, id, EVENT.WORKER_ERROR, data);
            };
        } catch (error) {
            entry.error = errorText(error);
            setTimeout(() => asyncDispatch(callback, id, EVENT.WORKER_ERROR, data), 0);
        }
        return id;
    },
    js_worker_post(id, bytes, length, binary) {
        const entry = asyncEntry(id, "worker");
        if (!entry || !entry.worker) return 0;
        if (binary !== 0) {
            const copy = view(bytes, length).slice();
            entry.worker.postMessage(copy.buffer, [copy.buffer]);
        } else {
            entry.worker.postMessage(stringAt(bytes, length));
        }
        return 1;
    },

    // Message queue shared by WebSocket and Worker handles.
    js_msg_length(id) {
        const entry = asyncHandles.get(id);
        return entry && entry.queue && entry.queue.length ? BigInt(entry.queue[0].bytes.length) : -1n;
    },
    js_msg_is_binary(id) {
        const entry = asyncHandles.get(id);
        return entry && entry.queue && entry.queue.length && entry.queue[0].binary ? 1 : 0;
    },
    js_msg_read(id, output, capacity) {
        const entry = asyncHandles.get(id);
        if (!entry || !entry.queue || !entry.queue.length) return -1n;
        const message = entry.queue[0];
        const result = writeBytesResult(message.bytes, output, capacity);
        // Only pop when the caller's buffer was big enough.
        if (offset(capacity) >= message.bytes.length) entry.queue.shift();
        return result;
    },

    js_error_length(id) {
        const entry = asyncHandles.get(id);
        return entry && entry.error ? BigInt(entry.error.length) : -1n;
    },
    js_error_read(id, output, capacity) {
        const entry = asyncHandles.get(id);
        return writeBytesResult(entry && entry.error, output, capacity);
    },

    js_async_cancel(id) {
        const entry = asyncHandles.get(id);
        if (!entry) return;
        asyncHandles.delete(id);
        switch (entry.kind) {
            case "http": entry.controller.abort(); break;
            case "ws": if (entry.socket) { try { entry.socket.close(); } catch {} } break;
            case "worker": if (entry.worker) entry.worker.terminate(); break;
            case "timer": (entry.repeat ? clearInterval : clearTimeout)(entry.native); break;
            case "frame": cancelAnimationFrame(entry.native); break;
            case "custom": if (entry.onClose) { try { entry.onClose(); } catch (e) { console.error(e); } } break;
        }
    },

    // Current-event access: only valid while a DOM handler is running.
    js_event_prevent_default() { if (currentEvent) currentEvent.preventDefault(); },
    js_event_key_length() {
        const key = currentEvent && currentEvent.key;
        return typeof key === "string" ? BigInt(encoder.encode(key).length) : -1n;
    },
    js_event_key_read(output, capacity) {
        const key = currentEvent && currentEvent.key;
        return writeStringResult(typeof key === "string" ? key : null, output, capacity);
    },

    // localStorage. Failures (disabled storage, quota) read as "missing".
    js_storage_length(key, keyLength) {
        try {
            const value = localStorage.getItem(stringAt(key, keyLength));
            return value === null ? -1n : BigInt(encoder.encode(value).length);
        } catch { return -1n; }
    },
    js_storage_get(key, keyLength, output, capacity) {
        try {
            return writeStringResult(localStorage.getItem(stringAt(key, keyLength)), output, capacity);
        } catch { return -1n; }
    },
    js_storage_set(key, keyLength, value, valueLength) {
        try {
            localStorage.setItem(stringAt(key, keyLength), stringAt(value, valueLength));
            return 1;
        } catch { return 0; }
    },
    js_storage_remove(key, keyLength) {
        try { localStorage.removeItem(stringAt(key, keyLength)); } catch {}
    },
};

function withCurrentEvent(event, run) {
    const previous = currentEvent;
    currentEvent = event;
    try { run(); } finally { currentEvent = previous; }
}

const imports = {
    env: {
        ...asyncImports,
        ...rt.libc,
        js_dom_find(selector, length) {
            const element = document.querySelector(stringAt(selector, length));
            return element ? registerNode(element) : 0;
        },
        js_dom_find_in(parent, selector, length) {
            const element = node(parent).querySelector(stringAt(selector, length));
            return element ? registerNode(element) : 0;
        },
        js_dom_create(tag, tagLength) {
            return registerNode(document.createElement(stringAt(tag, tagLength)));
        },
        js_dom_insert(parent, child, before) {
            const parentNode = node(parent);
            parentNode.insertBefore(node(child), before === 0 ? null : node(before));
        },
        js_dom_remove(id) {
            const element = domNodes.get(id);
            if (!element || !element.parentNode || element === document.body || element === document.documentElement) return 0;
            element.remove();
            domNodes.delete(id);
            domNodeIds.delete(element);
            return 1;
        },
        js_dom_set_text(id, text, textLength) {
            node(id).textContent = stringAt(text, textLength);
        },
        js_dom_get_value(id, output, capacity) {
            const value = node(id).value;
            if (value === undefined || value === null) return -1n;
            const bytes = encoder.encode(String(value));
            const available = offset(capacity);
            if (available < bytes.length) return BigInt(bytes.length);
            view(output, bytes.length).set(bytes);
            return BigInt(bytes.length);
        },
        js_dom_set_value(id, value, valueLength) {
            node(id).value = stringAt(value, valueLength);
        },
        js_dom_set_attribute(id, name, nameLength, value, valueLength) {
            node(id).setAttribute(stringAt(name, nameLength), stringAt(value, valueLength));
        },
        js_dom_get_attribute(id, name, nameLength, output, capacity) {
            const value = node(id).getAttribute(stringAt(name, nameLength));
            if (value === null) return -1n;
            const bytes = encoder.encode(value);
            const available = offset(capacity);
            if (available < bytes.length) return BigInt(bytes.length);
            view(output, bytes.length).set(bytes);
            return BigInt(bytes.length);
        },
        js_dom_remove_attribute(id, name, nameLength) {
            const element = node(id);
            const key = stringAt(name, nameLength);
            if (!element.hasAttribute(key)) return 0;
            element.removeAttribute(key);
            return 1;
        },
        js_dom_set_style(id, name, nameLength, value, valueLength) {
            const property = stringAt(name, nameLength).replace(/[A-Z]/g, c => `-${c.toLowerCase()}`);
            node(id).style.setProperty(property, stringAt(value, valueLength));
        },
        js_dom_add_event_listener(id, eventName, eventNameLength, callbackIndex, data) {
            const event = stringAt(eventName, eventNameLength);
            node(id).addEventListener(event, e => withCurrentEvent(e, () => api.jai_dom_event_dispatch(callbackIndex, id, data)));
        },
        js_dom_add_window_event_listener(eventName, eventNameLength, callbackIndex, data) {
            const event = stringAt(eventName, eventNameLength);
            window.addEventListener(event, e => withCurrentEvent(e, () => api.jai_dom_event_dispatch(callbackIndex, 0, data)));
        },
        js_dom_clear(id) {
            const element = node(id);
            while (element.firstChild) {
                const child = element.firstChild;
                const childId = domNodeIds.get(child);
                if (childId !== undefined) {
                    domNodes.delete(childId);
                    domNodeIds.delete(child);
                }
                element.removeChild(child);
            }
        },
        js_dom_value_length(id) {
            const value = node(id).value;
            if (value === undefined || value === null) return -1n;
            return BigInt(encoder.encode(String(value)).length);
        },
        js_dom_attribute_length(id, name, nameLength) {
            const value = node(id).getAttribute(stringAt(name, nameLength));
            if (value === null) return -1n;
            return BigInt(encoder.encode(value).length);
        },
        js_dom_url_length() {
            return BigInt(encoder.encode(window.location.href).length);
        },
        js_dom_path_length() {
            return BigInt(encoder.encode(window.location.pathname).length);
        },
        js_dom_search_length() {
            return BigInt(encoder.encode(window.location.search).length);
        },
        js_dom_hash_length() {
            return BigInt(encoder.encode(window.location.hash).length);
        },
        js_dom_param_length(name, nameLength) {
            const value = new URL(window.location.href).searchParams.get(stringAt(name, nameLength));
            if (value === null) return -1n;
            return BigInt(encoder.encode(value).length);
        },
        js_dom_get_url(output, capacity) {
            return writeStringResult(window.location.href, output, capacity);
        },
        js_dom_set_url(url, length, replace) {
            const target = stringAt(url, length);
            if (replace !== 0) history.replaceState(null, "", target);
            else history.pushState(null, "", target);
        },
        js_dom_get_path(output, capacity) {
            return writeStringResult(window.location.pathname, output, capacity);
        },
        js_dom_get_search(output, capacity) {
            return writeStringResult(window.location.search, output, capacity);
        },
        js_dom_get_hash(output, capacity) {
            return writeStringResult(window.location.hash, output, capacity);
        },
        js_dom_get_param(name, nameLength, output, capacity) {
            const key = stringAt(name, nameLength);
            const value = new URL(window.location.href).searchParams.get(key);
            return writeStringResult(value, output, capacity);
        },
        js_dom_set_param(name, nameLength, value, valueLength, replace) {
            const url = new URL(window.location.href);
            url.searchParams.set(stringAt(name, nameLength), stringAt(value, valueLength));
            commitUrl(url, replace !== 0);
        },
        js_dom_remove_param(name, nameLength, replace) {
            const url = new URL(window.location.href);
            url.searchParams.delete(stringAt(name, nameLength));
            commitUrl(url, replace !== 0);
        },
    },
};

// ---------------------------------------------------------------------------
// Extension point: your own JavaScript, callable from Jai.
//
//   start("./main.wasm", { env: host => ({ my_fn(ptr, len) { ... } }) })
//
// Declare `my_fn :: (...) #foreign;` in Jai and call it like any procedure.
// WASM is 64-bit here: pointers and s64 arrive as BigInt, s32 as Number, and
// the same goes for what you return (return BigInt for s64/pointers).
// `env` may be an object or a function receiving `host`. Names that clash with
// the built-in host functions are rejected.
// ---------------------------------------------------------------------------
const host = {
    // Reads from wasm memory (call these inside your host function, not later).
    string: (ptr, length) => stringAt(ptr, length),
    bytes: (ptr, length) => view(ptr, length).slice(),   // a copy, safe to keep
    // Jai DOM handle <-> element.
    dom: id => node(Number(id)),
    domId: element => registerNode(element),
    // The running program's exports (undefined before start() finishes).
    get exports() { return api; },

    // A value Jai reads right away. Return the id from your function, declare
    // it `-> Async_Handle` in Jai, then custom_read_message(handle) and
    // custom_free(handle). `payload` is a string, bytes, or anything JSON-able.
    value(payload) {
        const id = newAsync({ kind: "custom", queue: [toBytes(payload)], error: null });
        return id;
    },

    // A stream of events for a Jai callback. Return `.id` from your function
    // (declared `-> Async_Handle`, taking `callback: Async_Callback, data: *void`).
    //   const h = host.handle(callback, data);
    //   window.addEventListener("resize", () => h.emit({ w: innerWidth }));
    //   return h.id;
    // emit() -> CUSTOM + custom_read_message; fail() -> CUSTOM_ERROR + async_read_error.
    // custom_free() from Jai closes it and runs onClose, where you remove listeners.
    handle(callback, data) {
        const entry = { kind: "custom", queue: [], error: null, onClose: null };
        const id = newAsync(entry);
        return {
            id,
            emit(payload) {
                entry.queue.push(toBytes(payload));
                asyncDispatch(callback, id, EVENT.CUSTOM, data);
            },
            fail(error) {
                entry.error = errorText(error);
                asyncDispatch(callback, id, EVENT.CUSTOM_ERROR, data);
            },
            set onClose(fn) { entry.onClose = fn; },
        };
    },
};

function mergeEnv(extra) {
    const added = typeof extra === "function" ? extra(host) : extra;
    for (const name of Object.keys(added || {})) {
        if (name in imports.env) throw new Error(`env.${name} clashes with a built-in host function`);
        imports.env[name] = added[name];
    }
}

// Loads a Jai program (built with Web_Build) and runs its `app_init`.
//   <script type="module">
//       import { start } from "../../web/glue.js";
//       start("./main.wasm", { env: host => ({ ... }) });   // env is optional
//   </script>
export async function start(wasmUrl = "./main.wasm", options = {}) {
    if (options.env) mergeEnv(options.env);
    const { instance } = await WebAssembly.instantiateStreaming(fetch(wasmUrl), imports);
    api = instance.exports;
    if (!api.memory) throw new Error(`${wasmUrl} does not export memory`);
    rt.setMemory(api.memory);

    try {
        api.app_init();
    } catch (error) {
        console.error("Jai app_main failed:", error);
    }
}
