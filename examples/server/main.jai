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

    // Middleware: each of these is a route that doesn't respond, so the request
    // falls through to the routes below. Order matters, they come first.
    use_logger();
    use_security_headers();
    use_cors(.{ allow_origins = "*" }, "/api/*");
    use_rate_limit(.{ max_requests = 300, window_seconds = 60 }, "/api/*");
    use_request_id();                    // X-Request-ID on every response
    use_compress(.{}, "/api/*");         // brotli for big api responses (files are compressed by static())

    // every error the server makes itself (404, 405, 413...) comes through here: /api/* gets json
    set_error_handler((request: *Request, status_code: u16, message: string) {;
        if begins_with(request.path, "/api") {
            send_json(request, tprint("{\"status\":%,\"error\":%}", status_code, json_quote(message)), status_code = status_code);
        }   // anything else: the default plain text answer
    });

    get("/api/hello/:name", (request: *Request) {;
        send_text(request, tprint("Hello %!", request.get_param(request, "name")));
    });

    get("/api/info", (request: *Request) {;
        send_json(request, tprint("{\"server\":\"jai HTTP_Server\",\"threads\":%,\"websockets\":%}", thread_count, all_websockets.count));
    });

    // Bodies up to http_options.max_request_bytes (1 MB by default).
    post("/api/echo", (request: *Request) {;
        send_text(request, tprint("echo: %", request.body));
    });

    // A group shares a prefix (and middleware) between routes. group_use only affects routes added after it.
    api := group("/api");
    group_use(api, api_middleware);
    group_get(api, "/whoami", whoami_handler);
    group_post(api, "/login", login_handler);        // curl -c jar -d user=alice localhost:8000/api/login
    group_post(api, "/logout", logout_handler);
    group_post(api, "/upload", upload_handler);      // curl -F file=@some.txt -F note=hi localhost:8000/api/upload
    group_get(api, "/cookie", cookie_handler);
    group_get(api, "/big", big_handler);             // big enough to be compressed
    v1 := sub_group(api, "/v1");
    group_get(v1, "/ping/:n", (request: *Request) {;
        send_json(request, tprint("{\"pong\":%,\"id\":%}", json_quote(request.get_param(request, "n")), json_quote(request.request_id)));
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
    print_routes();
    http_wait_for_shutdown();   // ctrl-c: finish the requests in progress, then stop
    print("bye\n");
}

api_label := "jaidom api";

// a middleware: look at the request, hand something to the handlers after it, don't respond
api_middleware :: (request: *Request) {
    set_local(request, "label", *api_label);
}

whoami_handler :: (request: *Request) {
    label := cast(*string) get_local(request, "label");
    user, logged_in := session_get(request, "user");
    if logged_in send_json(request, tprint("{\"label\":%,\"user\":%}", json_quote(label.*), json_quote(user)));
    else         send_error(request, 401, "not logged in");
}

login_handler :: (request: *Request) {
    user, found := get_form(request, "user");
    if !found || user.count == 0 { send_error(request, 400, "field user is missing"); return; }
    session_set(request, "user", user);
    send_json(request, tprint("{\"logged_in\":%}", json_quote(user)));
}

logout_handler :: (request: *Request) {
    session_destroy(request);
    send_empty(request, 204);
}

upload_handler :: (request: *Request) {
    file, found := get_file(request, "file");
    if !found { send_error(request, 400, "no file field"); return; }
    note, _ := get_form(request, "note");
    send_json(request, tprint("{\"filename\":%,\"type\":%,\"bytes\":%,\"note\":%}", json_quote(file.filename), json_quote(file.content_type), file.data.count, json_quote(note)));
}

cookie_handler :: (request: *Request) {
    visits_text, had := get_cookie(request, "visits");
    visits := ifx had then to_integer(visits_text) else 0;
    set_cookie(request, "visits", tprint("%", visits + 1), .{ max_age_seconds = 3600 });
    send_json(request, tprint("{\"visits\":%}", visits + 1));
}

big_handler :: (request: *Request) {
    builder: String_Builder;
    append(*builder, "[");
    for 0 .. 199 print_to_builder(*builder, "%{\"n\":%,\"text\":\"lorem ipsum dolor sit amet\"}", ifx it > 0 then "," else "", it);
    append(*builder, "]");
    send_json(request, builder_to_string(*builder));
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
