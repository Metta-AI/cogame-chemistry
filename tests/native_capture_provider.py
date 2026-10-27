"""Loopback-only synthetic responses for complete native capture qualification."""

import json
import re
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Provider(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        request = json.loads(raw)
        user = request["messages"][0]["content"]
        shift = int(re.search(r"SHIFT (\d+)", user)[1])
        retry = "Your previous reply was invalid" in user
        if shift == 2 or (shift == 1 and not retry):
            text = "invalid reply"
        elif shift == 3:
            text = json.dumps(
                {"job": "forage", "reactor": "cobalt", "say": "x" * 500, "notes": "PRIVATE_CAPTURE_SENTINEL"}
            )
        else:
            text = json.dumps({"job": "forage", "say": "work", "notes": "PRIVATE_CAPTURE_SENTINEL"})
        body = json.dumps(
            {
                "model": request["model"],
                "stop_reason": "end_turn",
                "content": [{"type": "text", "text": text}],
                "usage": None if shift == 4 else {"input_tokens": 100, "output_tokens": 20},
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid5(uuid.NAMESPACE_URL, raw.decode())))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
print(server.server_port, flush=True)
server.serve_forever()
