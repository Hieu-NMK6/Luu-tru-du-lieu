"""Nhận audit log của MinIO qua webhook, ghi mỗi sự kiện một dòng JSON.

Đường dẫn POST (/site-a, /site-b) quyết định file: /logs/audit-site-a.jsonl ...
"""
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        site = self.path.strip("/")
        if not re.fullmatch(r"site-[a-z]", site):   # tên site nằm trong tên file -> chặn path traversal
            self.send_response(404)
            self.end_headers()
            return
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(f"/logs/audit-{site}.jsonl", "ab") as f:
            f.write(body.rstrip(b"\n") + b"\n")
        try:
            ev = json.loads(body)
            api = ev.get("api", {})
            print(f"[{site}] {ev.get('time')} {ev.get('accessKey', '-')} "
                  f"{api.get('name')} {api.get('bucket', '')}/{api.get('object', '')} "
                  f"-> {api.get('statusCode')}")
        except ValueError:
            pass
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
