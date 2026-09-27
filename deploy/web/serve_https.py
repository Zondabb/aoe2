#!/usr/bin/env python3
"""Serve the Godot web export in a secure context.

Godot's web build refuses to start on plain HTTP except localhost. This host
also accepts TLS on port 80 because some networks block 443. Plain HTTP is
redirected to https://<public-host>:80/.
"""

from __future__ import annotations

import http.server
import mimetypes
import os
import posixpath
import socket
import socketserver
import ssl
import threading
from urllib.parse import unquote, urlsplit

ROOT = os.environ.get("AOE2_WEB_ROOT", "/root/workspace/aoe2_web/public")
CERT = os.environ.get(
    "AOE2_WEB_CERT", "/etc/letsencrypt/live/106.12.81.171/fullchain.pem"
)
KEY = os.environ.get("AOE2_WEB_KEY", "/etc/letsencrypt/live/106.12.81.171/privkey.pem")
PUBLIC_HOST = os.environ.get("AOE2_WEB_HOST", "106.12.81.171")
HTTPS_URL = f"https://{PUBLIC_HOST}:80"

mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/octet-stream", ".pck")
HIDDEN_SUFFIXES = (".gz", ".br")
CACHE_CONTROL = "public, max-age=0, must-revalidate"


def safe_path(url_path: str) -> str | None:
    path = urlsplit(url_path).path
    path = unquote(path)
    if path.endswith("/"):
        path += "index.html"
    relative = posixpath.normpath(path).lstrip("/")
    if relative in {".", ".."} or relative.startswith("../"):
        return None
    full = os.path.realpath(os.path.join(ROOT, relative.replace("/", os.sep)))
    root = os.path.realpath(ROOT)
    if full != root and not full.startswith(root + os.sep):
        return None
    return full


def guess_type(path: str) -> str:
    mime, _encoding = mimetypes.guess_type(path)
    return mime or "application/octet-stream"


class GodotHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print("%s - %s" % (self.address_string(), format % args), flush=True)

    def _is_acme(self) -> bool:
        return urlsplit(self.path).path.startswith("/.well-known/acme-challenge/")

    def do_GET(self):
        self._send_file(head_only=False)

    def do_HEAD(self):
        self._send_file(head_only=True)

    def _send_file(self, head_only: bool) -> None:
        full = safe_path(self.path)
        if full is None or not os.path.isfile(full):
            self.send_error(404, "File not found")
            return
        if full.endswith(HIDDEN_SUFFIXES) and not self._is_acme():
            self.send_error(404, "File not found")
            return

        encoding = None
        body_path = full
        accept = self.headers.get("Accept-Encoding", "")
        gzip_path = full + ".gz"
        if "gzip" in accept and os.path.isfile(gzip_path):
            if os.path.getsize(gzip_path) < os.path.getsize(full):
                body_path = gzip_path
                encoding = "gzip"

        size = os.path.getsize(body_path)
        self.send_response(200)
        self.send_header("Content-Type", guess_type(full))
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", CACHE_CONTROL)
        self.send_header("ETag", f'"{size:x}-{int(os.path.getmtime(body_path))}"')
        if encoding:
            self.send_header("Content-Encoding", encoding)
            self.send_header("Vary", "Accept-Encoding")
        self.end_headers()
        if head_only:
            return
        with open(body_path, "rb") as handle:
            self.wfile.write(handle.read())


class RedirectHandler(GodotHandler):
    def _redirect(self) -> None:
        self.send_response(301)
        self.send_header("Location", f"{HTTPS_URL}{self.path}")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self._is_acme():
            return super().do_GET()
        self._redirect()

    def do_HEAD(self):
        if self._is_acme():
            return super().do_HEAD()
        self._redirect()


class ProtocolDispatchServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address, ssl_context):
        self.ssl_context = ssl_context
        super().__init__(server_address, GodotHandler)

    def process_request_thread(self, request, client_address):
        try:
            request.settimeout(5)
            try:
                peek = request.recv(1, socket.MSG_PEEK)
            except socket.timeout:
                return
            request.settimeout(None)
            if not peek:
                return
            if peek[:1] == b"\x16":
                request = self.ssl_context.wrap_socket(request, server_side=True)
                handler_cls = GodotHandler
            else:
                handler_cls = RedirectHandler
            handler_cls(request, client_address, self)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


def load_context() -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(CERT, KEY)
    return ctx


def serve_443(ctx: ssl.SSLContext) -> None:
    https = http.server.ThreadingHTTPServer(("0.0.0.0", 443), GodotHandler)
    https.socket = ctx.wrap_socket(https.socket, server_side=True)
    print("HTTPS :443 serving", ROOT, flush=True)
    https.serve_forever()


def main() -> None:
    if not os.path.isdir(ROOT):
        raise SystemExit(f"web root does not exist: {ROOT}")
    ctx = load_context()
    threading.Thread(target=serve_443, args=(ctx,), name="https-443", daemon=True).start()
    print(f"HTTP  :80  -> {HTTPS_URL}/", flush=True)
    print("HTTPS :80  serving", ROOT, flush=True)
    ProtocolDispatchServer(("0.0.0.0", 80), ctx).serve_forever()


if __name__ == "__main__":
    main()
