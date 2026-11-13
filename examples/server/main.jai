// Native dev server for the jaidom examples, built on modules/HTTP_Server.
//
//     ./build.sh examples/server        (from the repo root)
//     examples/server/server            serves the repo on http://localhost:8000
//     examples/server/server 9000       another port
//     examples/server/server 9000 /some/dir   another root (relative or absolute)
//
// Open http://localhost:8000/ and pick an example. The wasm pages are plain
// static files; /api/* and /ws exist for examples/chat.

#import "Basic";
#import "String";
#import "System";
#import "HTTP_Server";

main :: () {
    port: u16 = 8000;
    args := get_command_line_arguments();
    if args.count > 1 port = xx to_integer(args[1]);

    // static() resolves the folder against the working directory at call time.
    // Move there first, so the server works from any directory.
    root := repo_root();
    if args.count > 2 root = args[2];
    if !set_working_directory(root) {
        print("cannot use root %\n", root);
        exit(1);
    }

    http_listen(port = port);

    // Middleware: runs first for every request and doesn't respond, so the
    // request falls through to the routes below.
    any("*", (request: *Request) {;
        print("% %\n", request.method, request.path);
    });

    get("/api/hello/:name", (request: *Request) {;
        send_text(request, tprint("Hello %!", request.get_param(request, "name")));
    });

    get("/api/info", (request: *Request) {;
        send_json(request, tprint("{\"server\":\"jai HTTP_Server\",\"threads\":%,\"websockets\":%}", THREAD_POOL_COUNT, all_websockets.count));
    });

    // Bodies are limited by the module's request buffer (2 KB with headers).
    post("/api/echo", (request: *Request) {;
        send_text(request, tprint("echo: %", request.body));
    });

    // Chat for examples/chat: everything a client sends goes to everybody.
    {
        chat := websocket_listen("/ws");
        chat.onopen = (ws: *Websocket) {;
            ws.send(ws, "server: welcome, say something");
            ws.broadcast(ws, "server: someone joined");
        };
        chat.onmsg = (ws: *Websocket, message: string) {;
            ws.broadcast(ws, message);
            ws.send(ws, message);
        };
    }

    static(".");

    print("serving % on http://localhost:%/\n", root, port);
    while 1 sleep_milliseconds(60_000);   // the module's threads do the work
}

// The repo root: two directories above this executable (examples/server/server).
repo_root :: () -> string {
    exe := get_path_of_running_executable();
    for 1 .. 3 {    // strip "server", "server/", "examples/"
        index := find_index_from_right(exe, "/");
        if index > 0 exe.count = index;
    }
    return exe;
}
