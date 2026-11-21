#!/usr/bin/env python3
"""OpenAI-compatible shim in front of an Anthropic-messages provider.

claude-mem's `--provider host` expects an OpenAI-compatible server on localhost
and never starts one itself. DSH runs no such server, so this shim supplies the
endpoints claude-mem uses and forwards them to a Claude model.

Two upstream dialects are supported, chosen by SHIM_UPSTREAM_API:

  openai      POST {base}/chat/completions, OpenAI schema, relayed untouched
  anthropic   POST {base}/messages, Anthropic schema, translated both ways

The second is what a Claude gateway such as pateway1 speaks, and it is the
default. Only one model is ever requested — SHIM_MODEL — no matter what the
caller asks for, so the model used for memory summarisation is decided in one
place and cannot drift to a pricier one.

Routes:
  POST /v1/chat/completions   the completion, in OpenAI schema
  GET  /v1/models             a static list, enough for a probe
  GET  /health, GET /         liveness

The upstream key is read at request time, never stored here and never logged.
Sources, in order:
  1. $SHIM_UPSTREAM_API_KEY
  2. the DSH credential store, /root/.dsh/.credentials.yaml, under `refs:`

Environment:
  SHIM_PORT               listen port (default 37778)
  SHIM_HOST               listen host (default 127.0.0.1)
  SHIM_UPSTREAM_API       openai | anthropic (default anthropic)
  SHIM_UPSTREAM_BASE_URL  upstream base URL (default https://api.pateway.ai/v1)
  SHIM_MODEL              the only model ever requested (default claude-haiku-5-5)
  SHIM_UPSTREAM_KEY_ENV   credential name to read (default PATEWAY1_API_KEY)
  SHIM_MAX_TOKENS         ceiling for max_tokens when the caller omits it (default 4096)
  SHIM_LOG                log file (default /root/.llm-shim/shim.log)
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
import uuid
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.environ.get("SHIM_PORT", "37778"))
HOST = os.environ.get("SHIM_HOST", "127.0.0.1")
UPSTREAM_API = os.environ.get("SHIM_UPSTREAM_API", "anthropic").strip().lower()
UPSTREAM_BASE = os.environ.get("SHIM_UPSTREAM_BASE_URL", "https://api.pateway.ai/v1").rstrip("/")
MODEL = os.environ.get("SHIM_MODEL", "claude-haiku-5-5")
KEY_ENV = os.environ.get("SHIM_UPSTREAM_KEY_ENV", "PATEWAY1_API_KEY")
MAX_TOKENS = int(os.environ.get("SHIM_MAX_TOKENS", "4096"))
CREDENTIALS = Path(os.environ.get("SHIM_CREDENTIALS", "/root/.dsh/.credentials.yaml"))
LOG = Path(os.environ.get("SHIM_LOG", "/root/.llm-shim/shim.log"))
ANTHROPIC_VERSION = os.environ.get("SHIM_ANTHROPIC_VERSION", "2023-06-01")

STOP_REASONS = {
    "end_turn": "stop",
    "stop_sequence": "stop",
    "max_tokens": "length",
    "tool_use": "tool_calls",
    "refusal": "content_filter",
}

_lock = threading.Lock()


def log(message: str) -> None:
    line = f"[llm-shim] {message}\n"
    with _lock:
        try:
            LOG.parent.mkdir(parents=True, exist_ok=True)
            with LOG.open("a", encoding="utf-8") as handle:
                handle.write(line)
        except OSError:
            pass
    sys.stderr.write(line)


def credential(name: str) -> str | None:
    """Read one ref from the DSH credential store without a YAML dependency."""
    try:
        lines = CREDENTIALS.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    in_refs = False
    for line in lines:
        if not line.strip():
            continue
        if not line.startswith((" ", "\t")):
            in_refs = line.strip() == "refs:"
            continue
        if not in_refs or ":" not in line:
            continue
        key, _, value = line.strip().partition(":")
        if key.strip() == name:
            value = value.strip().strip('"').strip("'")
            return value or None
    return None


def api_key() -> str | None:
    return os.environ.get("SHIM_UPSTREAM_API_KEY") or credential(KEY_ENV)


def to_anthropic(payload: dict) -> dict:
    """Translate an OpenAI chat-completions body into an Anthropic messages body."""
    messages = payload.get("messages") or []
    system_parts: list[str] = []
    converted: list[dict] = []

    for message in messages:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        content = message.get("content")
        text = content if isinstance(content, str) else _flatten_content(content)
        if role == "system":
            if text:
                system_parts.append(text)
            continue
        if role not in ("user", "assistant") or not text:
            continue
        # Anthropic requires alternating roles; merge consecutive ones.
        if converted and converted[-1]["role"] == role:
            converted[-1]["content"][0]["text"] += "\n\n" + text
        else:
            converted.append({"role": role, "content": [{"type": "text", "text": text}]})

    if not converted:
        converted = [{"role": "user", "content": [{"type": "text", "text": "ping"}]}]

    body = {
        "model": MODEL,
        "max_tokens": int(payload.get("max_tokens") or payload.get("max_completion_tokens") or MAX_TOKENS),
        "messages": converted,
    }
    if system_parts:
        body["system"] = "\n\n".join(system_parts)
    for source, target in (("temperature", "temperature"), ("top_p", "top_p")):
        if isinstance(payload.get(source), (int, float)):
            body[target] = payload[source]
    stop = payload.get("stop")
    if isinstance(stop, str):
        body["stop_sequences"] = [stop]
    elif isinstance(stop, list):
        body["stop_sequences"] = [s for s in stop if isinstance(s, str)][:4]
    return body


def _flatten_content(content: object) -> str:
    """Collapse OpenAI content parts into plain text."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    pieces: list[str] = []
    for part in content:
        if isinstance(part, str):
            pieces.append(part)
        elif isinstance(part, dict) and part.get("type") == "text":
            text = part.get("text")
            if isinstance(text, str):
                pieces.append(text)
    return "\n".join(pieces)


def from_anthropic(body: dict, requested_model: str) -> dict:
    """Translate an Anthropic messages response into an OpenAI chat completion."""
    text_parts: list[str] = []
    reasoning_parts: list[str] = []
    for block in body.get("content") or []:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text" and isinstance(block.get("text"), str):
            text_parts.append(block["text"])
        elif block.get("type") == "thinking" and isinstance(block.get("thinking"), str):
            reasoning_parts.append(block["thinking"])

    usage = body.get("usage") or {}
    prompt_tokens = int(usage.get("input_tokens") or 0)
    completion_tokens = int(usage.get("output_tokens") or 0)
    message: dict = {"role": "assistant", "content": "\n".join(text_parts) if text_parts else None}
    if reasoning_parts:
        message["reasoning_content"] = "\n".join(reasoning_parts)

    return {
        "id": body.get("id") or f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": body.get("model") or requested_model,
        "choices": [{
            "index": 0,
            "message": message,
            "finish_reason": STOP_REASONS.get(body.get("stop_reason") or "", "stop"),
        }],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
        },
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A002 - stdlib signature
        log(f"{self.command} {self.path} -> {fmt % args}")

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - stdlib naming
        path = self.path.split("?", 1)[0]
        if path in ("/", "/health", "/api/health"):
            self._json(200, {"status": "ok", "model": MODEL, "upstream": UPSTREAM_API})
            return
        if path == "/v1/models":
            self._json(200, {"object": "list", "data": [{"id": MODEL, "object": "model", "owned_by": "shim"}]})
            return
        self._json(404, {"error": {"message": f"no route for {path}"}})

    def do_POST(self) -> None:  # noqa: N802 - stdlib naming
        path = self.path.split("?", 1)[0]
        if path != "/v1/chat/completions":
            self._json(404, {"error": {"message": f"no route for {path}"}})
            return

        key = api_key()
        if not key:
            log(f"no upstream key ({KEY_ENV}) available")
            self._json(502, {"error": {"message": f"shim has no upstream key: {KEY_ENV}"}})
            return

        try:
            length = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, OSError) as error:
            self._json(400, {"error": {"message": f"unreadable request body: {error}"}})
            return
        if not isinstance(payload, dict):
            self._json(400, {"error": {"message": "body must be an object"}})
            return

        requested = payload.get("model")
        if UPSTREAM_API == "anthropic":
            self._anthropic(payload, key, requested)
        else:
            self._openai(payload, key, requested)

    def _openai(self, payload: dict, key: str, requested: object) -> None:
        payload = dict(payload)
        payload["model"] = MODEL
        payload.pop("stream", None)
        log(f"forwarding openai completion (asked {requested!r}, using {MODEL!r})")
        request = urllib.request.Request(
            f"{UPSTREAM_BASE}/chat/completions",
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {key}",
                "Content-Type": "application/json",
                "HTTP-Referer": "http://localhost",
                "X-Title": "claude-mem host shim",
            },
            method="POST",
        )
        self._relay(request, requested)

    def _anthropic(self, payload: dict, key: str, requested: object) -> None:
        body = to_anthropic(payload)
        log(f"forwarding anthropic completion (asked {requested!r}, using {MODEL!r}, "
            f"max_tokens={body['max_tokens']})")
        request = urllib.request.Request(
            f"{UPSTREAM_BASE}/messages",
            data=json.dumps(body).encode("utf-8"),
            headers={
                "x-api-key": key,
                "Authorization": f"Bearer {key}",
                "anthropic-version": ANTHROPIC_VERSION,
                "Content-Type": "application/json",
            },
            method="POST",
        )
        upstream = None
        try:
            upstream = urllib.request.urlopen(request, timeout=300)
            raw = upstream.read()
        except urllib.error.HTTPError as error:
            detail = error.read()[:2000].decode("utf-8", "replace")
            log(f"upstream HTTP {error.code}: {detail[:300]}")
            self._json(error.code or 502, {"error": {"message": detail}})
            return
        except (urllib.error.URLError, OSError) as error:
            log(f"upstream unreachable: {error}")
            self._json(502, {"error": {"message": f"upstream unreachable: {error}"}})
            return
        finally:
            if upstream is not None:
                upstream.close()

        try:
            parsed = json.loads(raw)
        except ValueError:
            log(f"upstream returned non-JSON: {raw[:200]!r}")
            self._json(502, {"error": {"message": "upstream returned non-JSON"}})
            return
        if isinstance(parsed, dict) and parsed.get("type") == "error":
            self._json(502, {"error": {"message": json.dumps(parsed)[:1000]}})
            return
        self._json(200, from_anthropic(parsed, str(requested or MODEL)))

    def _relay(self, request: urllib.request.Request, requested: object) -> None:
        try:
            upstream = urllib.request.urlopen(request, timeout=300)
        except urllib.error.HTTPError as error:
            detail = error.read()[:2000].decode("utf-8", "replace")
            log(f"upstream HTTP {error.code}: {detail[:300]}")
            body = detail.encode("utf-8")
            self.send_response(error.code or 502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        except (urllib.error.URLError, OSError) as error:
            log(f"upstream unreachable: {error}")
            self._json(502, {"error": {"message": f"upstream unreachable: {error}"}})
            return
        self.send_response(upstream.status)
        for header, value in upstream.headers.items():
            if header.lower() in ("transfer-encoding", "connection", "content-length"):
                continue
            self.send_header(header, value)
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            while True:
                chunk = upstream.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            upstream.close()
        self.close_connection = True


def main() -> int:
    if not api_key():
        log(f"warning: no upstream key found ({KEY_ENV}); requests will fail with 502")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    log(f"listening on http://{HOST}:{PORT}/v1 -> {UPSTREAM_BASE} ({UPSTREAM_API}) as {MODEL}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
