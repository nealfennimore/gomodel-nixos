import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path.endswith("/models"):
            return self._send({"object": "list", "data": [{"id": "mock-model", "object": "model", "created": 0, "owned_by": "mock"}]})
        self.send_response(404); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); req = json.loads(self.rfile.read(n) or b"{}")
        sys.stderr.write("auth=%s\n" % self.headers.get("Authorization"))
        self._send({"id": "chatcmpl-mock", "object": "chat.completion", "created": 0, "model": req.get("model"),
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": "hello from mock"}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 3, "total_tokens": 4}})
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
