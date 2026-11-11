#load "wasm_build.jai";

// Every Jai worker is its own wasm module; list them here.
#run build_wasm("echo-worker", "echo_worker.jai");
