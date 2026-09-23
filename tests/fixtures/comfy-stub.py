#!/usr/bin/env python3
"""Stub ComfyUI for tests. Serves the handful of endpoints `comfy` uses.

Usage: comfy-stub.py <port> <state-dir>
Records each /prompt body to <state-dir>/last-prompt.json so tests can assert
exactly what the helper submitted, including JSON types.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1])
STATE = sys.argv[2]

MODELS = {
    "checkpoints": ["v1-5-pruned-emaonly-fp16.safetensors"],
    "loras": [],
    "vae": ["vae-ft-mse.safetensors"],
}

# Flipped by /_stub/fail-exec so one test can drive the error path.
# running/pending are set by /_stub/queue so the cancel and fetch tests can
# drive a queue that actually holds jobs; "known" is the set of prompt ids
# /history answers for at all — real ComfyUI returns {} for anything else, and
# a stub that answered for every id let `comfy fetch <typo>` look like a
# finished job with no outputs.
STATE_FLAGS = {
    "exec_error": False,
    "pending_forever": False,
    "running": "",
    "pending": [],
    "known": ["stub-prompt-1"],
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        p, q = u.path, parse_qs(u.query)
        if p == "/system_stats":
            return self._send(200, {
                "system": {"os": "linux", "comfyui_version": "0.33.1",
                           "python_version": "3.12.3 (main)"},
                "devices": [{"name": "stub cuda:0", "type": "cuda",
                             "vram_total": 130596048896, "vram_free": 76522124646}],
            })
        if p == "/queue":
            # ComfyUI's own entry shape: [number, prompt_id, prompt,
            # extra_data, outputs_to_execute]. The prompt id at index 1 is
            # what `comfy cancel` and `comfy fetch` read.
            running = []
            if STATE_FLAGS["running"]:
                running = [[0, STATE_FLAGS["running"], {}, {}, []]]
            pending = [[i + 1, pid, {}, {}, []]
                       for i, pid in enumerate(STATE_FLAGS["pending"])]
            return self._send(200, {"queue_running": running, "queue_pending": pending})
        if p == "/models":
            return self._send(200, list(MODELS))
        if p.startswith("/models/"):
            folder = p[len("/models/"):]
            if folder not in MODELS:
                return self._send(404, {"error": "no such folder"})
            return self._send(200, MODELS[folder])
        if p.startswith("/history/"):
            pid = p[len("/history/"):]
            if STATE_FLAGS["pending_forever"]:
                return self._send(200, {})
            # Real ComfyUI has no entry for an id it never saw, and answers
            # with an empty object rather than a 404.
            if pid not in STATE_FLAGS["known"]:
                return self._send(200, {})
            if STATE_FLAGS["exec_error"]:
                return self._send(200, {pid: {"status": {
                    "status_str": "error",
                    "messages": [["execution_error", {
                        "node_id": "3", "node_type": "KSampler",
                        "exception_message": "stub blew up",
                    }]],
                }}})
            return self._send(200, {pid: {
                "status": {"status_str": "success"},
                "outputs": {"9": {"images": [
                    {"filename": "ComfyUI_00001_.png", "subfolder": "", "type": "output"},
                    # A hostile filename: the helper must write a basename only.
                    {"filename": "../../escape.png", "subfolder": "", "type": "output"},
                    # A non-empty subfolder: pins the other half of the
                    # filename/subfolder/type bug class — the stub's /view
                    # check below only had subfolder="" cases to catch a
                    # swap until this fixture existed.
                    {"filename": "nested_00001_.png", "subfolder": "nested", "type": "output"},
                ]}},
            }})
        if p == "/view":
            fn = q.get("filename", [""])[0]
            sub = q.get("subfolder", [""])[0]
            typ = q.get("type", [""])[0]
            # Real ComfyUI 400s on a filename/subfolder/type combo that
            # doesn't match what it actually saved — reject a mismatch here
            # too, so a caller that mis-threads these three values (e.g. by
            # reading a tab-separated `filename subfolder type` line with
            # `IFS=$'\t' read`, where bash's whitespace-IFS collapsing
            # silently drops an empty middle field and shifts subfolder/type
            # off by one) fails loudly instead of the stub papering over it
            # by echoing back bytes regardless of params.
            expected = {
                "ComfyUI_00001_.png": ("", "output"),
                "../../escape.png": ("", "output"),
                "nested_00001_.png": ("nested", "output"),
            }.get(fn)
            if expected is None or (sub, typ) != expected:
                return self._send(400, {"error": f"no such file: {fn!r} in subfolder={sub!r} type={typ!r}"})
            data = b"\x89PNG\r\n\x1a\n" + fn.encode()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        if u.path == "/prompt":
            with open(os.path.join(STATE, "last-prompt.json"), "wb") as fh:
                fh.write(raw)
            try:
                body = json.loads(raw)
            except ValueError:
                return self._send(400, {"error": {"message": "invalid json"}})
            if "prompt" not in body:
                return self._send(400, {"error": {"message": "missing prompt"}})
            return self._send(200, {"prompt_id": "stub-prompt-1", "number": 1})
        if u.path == "/interrupt":
            # Appended to, never overwritten: the cancel tests assert on
            # whether an interrupt was issued AT ALL for a given invocation.
            with open(os.path.join(STATE, "interrupts"), "a") as fh:
                fh.write("interrupt\n")
            return self._send(200, {})
        if u.path == "/queue":
            with open(os.path.join(STATE, "last-queue-post.json"), "wb") as fh:
                fh.write(raw)
            return self._send(200, {})
        if u.path == "/upload/image":
            # Record the raw multipart body so tests can assert which local
            # file the helper actually uploaded (its filename= field).
            with open(os.path.join(STATE, "last-upload.raw"), "wb") as fh:
                fh.write(raw)
            return self._send(200, {"name": "uploaded.png", "subfolder": "", "type": "input"})
        if u.path == "/_stub/fail-exec":
            STATE_FLAGS["exec_error"] = True
            return self._send(200, {"ok": True})
        if u.path == "/_stub/pending":
            STATE_FLAGS["pending_forever"] = True
            return self._send(200, {"ok": True})
        if u.path == "/_stub/queue":
            # {"running": "<id>", "pending": ["<id>", ...]} — either key may
            # be omitted; an empty string/list clears it.
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                return self._send(400, {"error": "invalid json"})
            if "running" in body:
                STATE_FLAGS["running"] = body["running"]
            if "pending" in body:
                STATE_FLAGS["pending"] = list(body["pending"])
            return self._send(200, {"ok": True})
        self._send(404, {"error": "not found"})


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
