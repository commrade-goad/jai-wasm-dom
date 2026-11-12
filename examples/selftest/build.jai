#import "Web_Build";

#run {
    build_wasm("main", "main.jai", dir = #filepath);
    build_wasm("echo-worker", "echo_worker.jai", dir = #filepath);
}
