#!/usr/bin/env python3
"""Loopback sink for Nexus Repository base telemetry.

Nexus Community Edition requires a successful base telemetry upload at least
once every 10 days; otherwise it blocks writes (read-only mode).  This sink
answers uploads locally so an air-gapped instance never advances that counter.
No report data leaves the host.
"""
import http.server
import os
import sys

INGEST_SUFFIX = "/ingest"
SIGNATURE_HEADER = "x-signature"


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "NexusTelemetrySink/1.0"

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if self.path.rstrip("/").endswith(INGEST_SUFFIX):
            # Nexus counts 204 as success only when x-signature is present.
            # It skips signature validation when /publickey is unavailable.
            self.send_response(204)
            self.send_header(SIGNATURE_HEADER, "local")
            self.end_headers()
            return
        self.send_error(404)

    def do_GET(self):
        if self.path.rstrip("/") == "/healthz":
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # Missing public key makes Nexus treat signature checks as an
        # infrastructure issue instead of a failed upload.
        self.send_error(404)

    def log_message(self, fmt, *args):
        sys.stderr.write("telemetry-sink: %s\n" % (fmt % args))


def main():
    port = int(os.environ.get("NEXUS_TELEMETRY_SINK_PORT", "8099"))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("telemetry-sink: listening on 127.0.0.1:%d" % port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
