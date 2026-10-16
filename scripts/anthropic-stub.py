#!/usr/bin/env python3
"""Minimal Anthropic-compatible endpoint, kept solely as the reproduction for
charter open question 9 (north-star.md Decision 16, 2026-09-08): does `claude`
honour ANTHROPIC_BASE_URL?

It answers /v1/messages with a valid SSE turn whose only text is BASE_URL_OK,
so a `claude` result of exactly that string proves the turn went here and not
to Anthropic. Every request is logged as one JSON line, which is where the
recorded Authorization / anthropic-version headers came from.

    scripts/anthropic-stub.py 8787 /tmp/stub.log &
    cd /tmp && env -i HOME="$HOME" PATH=/usr/bin:/bin \\
      CLAUDE_CONFIG_DIR=/tmp/probe-cfg \\
      ANTHROPIC_BASE_URL=http://127.0.0.1:8787 \\
      ANTHROPIC_AUTH_TOKEN=stub-token \\
      claude -p "say ok" --output-format stream-json --verbose < /dev/null

Use a throwaway CLAUDE_CONFIG_DIR: the point is to prove where the request
went, and a real account's directory has no business in that experiment.
This is a test fixture, not a shim — it serves one canned answer and knows
nothing about models."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = open(sys.argv[2], "a", buffering=1) if len(sys.argv) > 2 else sys.stderr

SSE = [
    ("message_start", {"type":"message_start","message":{"id":"msg_stub","type":"message","role":"assistant","model":"stub-model","content":[],"stop_reason":None,"stop_sequence":None,"usage":{"input_tokens":10,"output_tokens":1}}}),
    ("content_block_start", {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
    ("content_block_delta", {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"BASE_URL_OK"}}),
    ("content_block_stop", {"type":"content_block_stop","index":0}),
    ("message_delta", {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":None},"usage":{"output_tokens":5}}),
    ("message_stop", {"type":"message_stop"}),
]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _read(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _record(self, body):
        interesting = {k: v for k, v in self.headers.items()
                       if k.lower() in ("authorization", "x-api-key", "anthropic-version", "anthropic-beta", "user-agent")}
        try:
            parsed = json.loads(body or b"{}")
            model = parsed.get("model")
            stream = parsed.get("stream")
        except Exception:
            model, stream = "<unparsed>", None
        print(json.dumps({"path": self.path, "method": self.command, "model": model,
                          "stream": stream, "headers": interesting}), file=LOG)

    def do_POST(self):
        body = self._read()
        self._record(body)
        if self.path.endswith("/count_tokens"):
            out = json.dumps({"input_tokens": 10}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        for name, payload in SSE:
            self.wfile.write(f"event: {name}\ndata: {json.dumps(payload)}\n\n".encode())
            self.wfile.flush()

    def do_GET(self):
        self._record(b"")
        out = json.dumps({"data": [{"id": "stub-model", "type": "model", "display_name": "Stub"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
