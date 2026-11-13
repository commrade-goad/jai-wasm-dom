"""End-to-end test: starts the native server, then drives the wasm examples in
headless Chromium. Needs `pip install playwright` and a built examples/server.

    python3 examples/server/test/run.py
"""
import hashlib
import os
import socket
import subprocess
import sys
import time
import urllib.request

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "server")

failures = []


def check(ok, name):
    print(("PASS " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for(predicate, seconds=5.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


if not os.path.exists(SERVER):
    sys.exit("build the server first: ./build.sh examples/server")

port = free_port()
base = f"http://127.0.0.1:{port}"
server = subprocess.Popen([SERVER, str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd="/")
try:
    wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", port)) == 0)

    # --- plain HTTP ---------------------------------------------------------
    def fetch(path, data=None):
        return urllib.request.urlopen(urllib.request.Request(base + path, data=data), timeout=5)

    r = fetch("/examples/hello/main.wasm")
    check(r.headers["Content-Type"] == "application/wasm", "wasm is served as exactly application/wasm")
    with open(os.path.join(HERE, "..", "..", "hello", "main.wasm"), "rb") as f:
        wasm_sha256 = hashlib.sha256(f.read()).hexdigest()
    check(fetch("/api/hello/test").read() == b"Hello test!", "router: GET /api/hello/:name")
    check(b'"threads"' in fetch("/api/info").read(), "router: GET /api/info (json)")
    check(fetch("/api/echo", data=b"ping").read() == b"echo: ping", "router: POST /api/echo")
    check(fetch("/web/glue.js").headers["Content-Type"].startswith("text/javascript"), "js is served as text/javascript")

    # --- the wasm pages -----------------------------------------------------
    with sync_playwright() as p:
        browser = p.chromium.launch()

        def open_page(path):
            page = browser.new_page()
            page.errors = []
            page.on("pageerror", lambda e: page.errors.append(str(e)))
            page.goto(base + path)
            return page

        page = open_page("/examples/hello/")
        check(wait_for(lambda: "HTTP 200" in page.locator("#out").inner_text()), "hello: wasm ran and fetched over HTTP")
        check(not page.errors, "hello: no page errors")
        # Hash what the browser received (after it decoded any Content-Encoding).
        digest = page.evaluate("""async () => {
            const body = await (await fetch("/examples/hello/main.wasm")).arrayBuffer();
            const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", body));
            return [...hash].map(byte => byte.toString(16).padStart(2, "0")).join("");
        }""")
        check(digest == wasm_sha256, "wasm bytes arrive intact (172 KB, multi-write response)")

        page = open_page("/examples/todos/")
        check(wait_for(lambda: page.locator("#nav-counter").count() == 1), "todos: UI rendered by wasm")
        check(not page.errors, "todos: no page errors")

        page = open_page("/examples/custom-js/")
        time.sleep(0.5)
        check(not page.errors, "custom-js: no page errors")

        # --- chat: two clients through the native WebSocket server ----------
        a = open_page("/examples/chat/")
        b = open_page("/examples/chat/")
        for name, pg in (("a", a), ("b", b)):
            check(wait_for(lambda: pg.locator("#status").inner_text() == "connected"), f"chat {name}: websocket connected")
            check(wait_for(lambda: "api: Hello jai!" in pg.locator("#log").inner_text()), f"chat {name}: GET /api/hello over fetch")

        a.fill("#message", "hello from a")
        a.click("#send")
        check(wait_for(lambda: "hello from a" in b.locator("#log").inner_text()), "chat: message from a reaches b")
        check(wait_for(lambda: "hello from a" in a.locator("#log").inner_text()), "chat: sender gets its own echo")

        b.fill("#message", "enter key")
        b.press("#message", "Enter")
        check(wait_for(lambda: "enter key" in a.locator("#log").inner_text()), "chat: Enter sends (dom_read_event_key)")

        a.fill("#message", "post me")
        a.click("#echo")
        check(wait_for(lambda: "api: echo: post me" in a.locator("#log").inner_text()), "chat: POST /api/echo from wasm")
        check(not a.errors and not b.errors, "chat: no page errors")

        browser.close()
finally:
    server.terminate()

print()
print("FAILED: " + ", ".join(failures) if failures else "all passed")
sys.exit(1 if failures else 0)
