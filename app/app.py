"""Minimal service used to exercise the platform.

GET /health  -> 200 while the process is up (load balancer and Route 53 health checks).
GET /        -> 200 with the serving region and the database role (writer or read-only),
               503 if the database is unreachable. Useful during failover drills.
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

PORT = int(os.environ.get("PORT", "8080"))
REGION = os.environ.get("APP_REGION", "unknown")


def db_status() -> dict:
    conn_info = {
        "host": os.environ["DB_HOST"],
        "dbname": os.environ.get("DB_NAME", "app"),
        "user": os.environ["DB_USER"],
        "password": os.environ["DB_PASSWORD"],
        "sslmode": "require",
        "connect_timeout": 3,
    }
    with psycopg.connect(**conn_info) as conn:
        read_only = conn.execute("SELECT pg_is_in_recovery()").fetchone()[0]
        version = conn.execute("SHOW server_version").fetchone()[0]
    return {"role": "read-only" if read_only else "writer", "server_version": version}


class Handler(BaseHTTPRequestHandler):
    def _send(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:  # noqa: N802 (http.server naming)
        if self.path == "/health":
            self._send(200, {"status": "ok"})
            return
        if self.path == "/":
            try:
                self._send(200, {"region": REGION, "database": db_status()})
            except Exception as exc:  # report, do not crash the server
                self._send(503, {"region": REGION, "database": "unreachable", "error": type(exc).__name__})
            return
        self._send(404, {"error": "not found"})

    def log_message(self, fmt: str, *args) -> None:
        # One line per request, without query strings or headers.
        print(json.dumps({"method": self.command, "path": self.path.split("?")[0], "region": REGION}))


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
