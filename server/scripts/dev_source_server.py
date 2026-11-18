#!/usr/bin/env python3
"""测试源站文件服务器（iOS Simulator 测试与本地联调用）。
- /file?size=N&chunk=C&delay=D：确定性字节（位置 mod 256），支持 Range、慢速
- /redirect?url=X&code=302：重定向端点
与 server/tests/conftest.py 的 file_server fixture 字节规则一致。
"""
import argparse
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(u.query)
        if u.path == "/redirect":
            target = qs.get("url", [""])[0]
            if target:
                self.send_response(int(qs.get("code", ["302"])[0]))
                self.send_header("Location", target)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        size = int(qs.get("size", ["1024"])[0])
        chunk = int(qs.get("chunk", ["65536"])[0])
        delay = float(qs.get("delay", ["0"])[0])
        rng = self.headers.get("Range", "")
        start, end = 0, size - 1
        if rng.startswith("bytes="):
            spec = rng.split("=", 1)[1].split(",", 1)[0]
            a, _, b = spec.partition("-")
            start = int(a) if a else 0
            if b:
                end = min(int(b), size - 1)
            if not a and b:
                start = max(0, size - int(b))
        start = max(0, min(start, size - 1))
        ranged = start > 0 or rng.startswith("bytes=")
        self.send_response(206 if ranged else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        if ranged:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        pos = start
        while pos <= end:
            n = min(chunk, end - pos + 1)
            self.wfile.write(bytes((pos + i) % 256 for i in range(n)))
            pos += n
            if delay:
                time.sleep(delay)

    def do_HEAD(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        size = int(qs.get("size", ["1024"])[0])
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8090)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
