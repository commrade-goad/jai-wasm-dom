// Generic host for Jai workers. It contains no application code: it loads the
// wasm module named by `new Worker(..., { name: <wasm url> })` and forwards
// messages between the page and Jai.
//   page -> worker: copied into wasm memory, then `jai_worker_dispatch(ptr, len, binary)`
//   worker -> page: Jai calls `js_worker_reply(ptr, len, binary)` (copied out)
import { createRuntime } from "./runtime.js";

const rt = createRuntime();
const { view, offset } = rt;
let api = null;

function toBytes(data) {
    if (typeof data === "string") return { binary: false, bytes: rt.encoder.encode(data) };
    if (data instanceof ArrayBuffer) return { binary: true, bytes: new Uint8Array(data) };
    if (ArrayBuffer.isView(data)) return { binary: true, bytes: new Uint8Array(data.buffer, data.byteOffset, data.byteLength) };
    return { binary: false, bytes: rt.encoder.encode(JSON.stringify(data)) };
}

const imports = {
    env: {
        ...rt.libc,
        js_worker_reply(bytes, length, binary) {
            if (binary !== 0) {
                const copy = view(bytes, length).slice();
                postMessage(copy.buffer, [copy.buffer]);
            } else {
                postMessage(rt.stringAt(bytes, length));
            }
        },
        js_worker_close() { self.close(); },
    },
};

function deliver(data) {
    const { binary, bytes } = toBytes(data);
    const length = BigInt(bytes.length);
    // Never hand Jai a null pointer, even for an empty message.
    const buffer = rt.malloc(length > 0n ? length : 1n);
    view(buffer, bytes.length).set(bytes);
    try {
        api.jai_worker_dispatch(buffer, length, binary ? 1 : 0);
    } finally {
        rt.free(buffer);
    }
}

const ready = (async () => {
    const result = await WebAssembly.instantiateStreaming(fetch(self.name), imports);
    api = result.instance.exports;
    if (!api.memory) throw new Error(`${self.name} does not export memory`);
    rt.setMemory(api.memory);
    if (api.worker_init) api.worker_init();
})();

// Registered synchronously so messages posted right after spawn are kept;
// awaiting the same promise preserves their order.
onmessage = async event => {
    try {
        await ready;
        deliver(event.data);
    } catch (error) {
        console.error("Jai worker failed:", error);
        setTimeout(() => { throw error; }, 0);   // surfaces as WORKER_ERROR on the page
    }
};

// A failed load with no message pending must still reach the page.
ready.catch(error => setTimeout(() => { throw error; }, 0));
