"""Test server for the ?selftest page.

HTTP on :8000 serves the repo root plus POST /echo and GET /slow.
WebSocket echo on :8765.
"""
import asyncio
import functools
import http.server
import os
import threading
import time

import websockets

# Serve the whole repo so pages can import ../../web/glue.js.
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      ".wasm": "application/wasm", ".js": "text/javascript"}

    def do_GET(self):
        if self.path.split("?")[0].endswith("/slow"):
            time.sleep(1.5)
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        super().do_GET()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Echo-Content-Type", self.headers.get("Content-Type", ""))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


async def echo(socket):
    async for message in socket:
        await socket.send(message)


def main():
    handler = functools.partial(Handler, directory=ROOT)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 8000), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    async def run_ws():
        async with websockets.serve(echo, "127.0.0.1", 8765):
            await asyncio.Future()

    print("serving on http://127.0.0.1:8000 and ws://127.0.0.1:8765", flush=True)
    asyncio.run(run_ws())


if __name__ == "__main__":
    main()
