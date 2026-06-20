#!/usr/bin/env python3
"""HTTP -> SMTP injector for inbound mail.

The Cloudflare Email Worker reads each inbound message and POSTs the raw RFC822
to this service over HTTPS (the ISP blocks inbound :25, so this is the only way
mail enters the network). We validate a shared secret and relay the message into
Stalwart over the internal SMTP listener.

Zero external dependencies — Python stdlib only.
"""
import hmac
import os
import smtplib
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get("INJECTOR_SHARED_SECRET", "")
STALWART_HOST = os.environ.get("STALWART_HOST", "stalwart")
STALWART_PORT = int(os.environ.get("STALWART_PORT", "25"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8025"))
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(40 * 1024 * 1024)))  # 40 MiB


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body=b""):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, b"ok\n")
        else:
            self._send(404)

    def do_POST(self):
        # Served behind SWAG at mail.<domain>/_inject (shares the mail hostname).
        if self.path != "/_inject":
            self._send(404)
            return

        token = self.headers.get("X-Auth-Token", "")
        if not SECRET or not hmac.compare_digest(token, SECRET):
            log("rejected: bad or missing auth token")
            self._send(403, b"forbidden\n")
            return

        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0 or length > MAX_BYTES:
            self._send(413, b"payload empty or too large\n")
            return

        # Envelope is passed explicitly by the worker; falling back to the
        # message headers would lose the real SMTP recipient on aliasing.
        env_from = self.headers.get("X-Env-From", "")  # may be "" for bounces
        env_to = self.headers.get("X-Env-To", "")
        if not env_to:
            self._send(400, b"missing X-Env-To\n")
            return

        raw = self.rfile.read(length)
        try:
            with smtplib.SMTP(STALWART_HOST, STALWART_PORT, timeout=30) as smtp:
                smtp.sendmail(env_from, [env_to], raw)
        except Exception as exc:  # noqa: BLE001 - report any failure to the worker
            log(f"delivery failed for {env_to!r}: {exc}")
            # 5xx -> worker rejects -> sending MTA retries (no silent loss).
            self._send(502, b"upstream delivery failed\n")
            return

        log(f"delivered {len(raw)} bytes for {env_to!r} (from {env_from!r})")
        self._send(200, b"accepted\n")

    def log_message(self, *args):  # silence default access logging
        pass


def main():
    if not SECRET:
        log("FATAL: INJECTOR_SHARED_SECRET is not set")
        sys.exit(1)
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    log(
        f"injector listening on :{LISTEN_PORT}, "
        f"relaying to {STALWART_HOST}:{STALWART_PORT}"
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
