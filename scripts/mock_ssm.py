#!/usr/bin/env python3
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
import sys

PARAMETERS = {
    "/my-app/DB_USER": "postgres_admin",
    "/my-app/DB_PASSWORD": "super_secret_pass_123",
    "/my-app/STRIPE_SECRET": "sk_test_ssm_mock_value",
}

class SsmMockHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        target = self.headers.get("X-Amz-Target", "")
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)
        payload = json.loads(body) if body else {}

        self.send_response(200)
        self.send_header("Content-Type", "application/x-amz-json-1.1")
        self.end_headers()

        if target == "AmazonSSM.GetParametersByPath":
            prefix = payload.get("Path", "")
            matched = []
            for name, val in PARAMETERS.items():
                if name.startswith(prefix):
                    matched.append({
                        "Name": name,
                        "Type": "SecureString",
                        "Value": val,
                        "Version": 1
                    })
            resp = {"Parameters": matched}
            self.wfile.write(json.dumps(resp).encode())
        elif target == "AmazonSSM.GetParameter":
            name = payload.get("Name", "")
            val = PARAMETERS.get(name, "default_val")
            resp = {
                "Parameter": {
                    "Name": name,
                    "Type": "SecureString",
                    "Value": val,
                    "Version": 1
                }
            }
            self.wfile.write(json.dumps(resp).encode())
        else:
            self.wfile.write(b"{}")

    def log_message(self, format, *args):
        pass # Quiet mode

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4566
    server = HTTPServer(("127.0.0.1", port), SsmMockHandler)
    print(f"Mock SSM server listening on http://127.0.0.1:{port}", flush=True)
    server.serve_forever()
