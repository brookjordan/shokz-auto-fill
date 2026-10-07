#!/usr/bin/env python3
"""A stand-in for Navidrome, so the installer can be tested without a server.

    fake-subsonic.py ok <port>       answers 200 with subsonic status "ok"
    fake-subsonic.py failed <port>   answers 200 with subsonic status "failed"
    fake-subsonic.py hang <port>     accepts the connection and never replies

The hang mode exists because "the server accepted the connection and then sent
nothing" is a distinct failure from "nothing is listening", and the installer's
diagnostics are supposed to tell them apart.
"""

import http.server
import json
import socket
import sys


def serve_http(mode, port):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if mode == "ok":
                body = {"subsonic-response": {"status": "ok", "version": "1.16.1"}}
            else:
                body = {
                    "subsonic-response": {
                        "status": "failed",
                        "version": "1.16.1",
                        "error": {"code": 40, "message": "Wrong username or password"},
                    }
                }
            raw = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def log_message(self, *args):
            pass

    http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()


def serve_hang(port):
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    sock.listen(5)
    held = []
    while True:
        conn, _ = sock.accept()
        held.append(conn)  # accepted, then deliberately never answered


if __name__ == "__main__":
    mode_arg, port_arg = sys.argv[1], int(sys.argv[2])
    if mode_arg == "hang":
        serve_hang(port_arg)
    else:
        serve_http(mode_arg, port_arg)
