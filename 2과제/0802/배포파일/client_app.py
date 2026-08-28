import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen


SERVICE_URL = os.environ.get("SERVICE_URL", "").rstrip("/")


class ClientHandler(BaseHTTPRequestHandler):
    def _send_json(self, status_code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._send_json(200, {"status": "ok", "app": "client"})
            return

        if parsed.path == "/v1/client/orders":
            order_id = parse_qs(parsed.query).get("id", ["1001"])[0]
            if not SERVICE_URL:
                self._send_json(500, {"error": "SERVICE_URL is not configured"})
                return
            request = Request(f"{SERVICE_URL}/v1/orders?id={order_id}")
            with urlopen(request, timeout=5) as response:
                service_payload = json.loads(response.read().decode("utf-8"))
            self._send_json(200, {"client": "ok", "service": service_payload})
            return

        self._send_json(404, {"error": "not found"})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 80), ClientHandler)
    server.serve_forever()
