#!/usr/bin/env python3
"""Hydra token hook — inject merchant_id and azp from OAuth2 client metadata."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class TokenHookHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/health", "/healthz", "/ready"):
            self._json_response(200, {"status": "ok"})
            return
        self.send_error(404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            self._json_response(400, {"error": "invalid json"})
            return

        client = body.get("client") or body.get("request", {}).get("client") or {}
        metadata = client.get("metadata") or {}
        merchant_id = metadata.get("merchant_id", "")
        client_id = client.get("client_id", "")

        self._json_response(
            200,
            {
                "session": {
                    "access_token": {
                        "merchant_id": merchant_id,
                        "azp": client_id,
                    }
                }
            },
        )

    def _json_response(self, code, payload):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        return


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), TokenHookHandler).serve_forever()
