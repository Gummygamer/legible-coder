#!/usr/bin/env python3
"""Minimal OpenAI-compatible HTTP shim for the Legible-Nano checkpoint."""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


MODEL_ID = "legible-nano-checkpoint"
REPO_DIR = Path(__file__).resolve().parent
DEFAULT_NANO_REPO = REPO_DIR.parent / "Legible-Nano"
DEFAULT_CHECKPOINT = DEFAULT_NANO_REPO / "out" / "legible-nano" / "ckpt.pt"


def import_nano(nano_repo: Path) -> tuple[Any, Any]:
    sys.path.insert(0, str(nano_repo))
    import torch  # type: ignore
    from sample import load_checkpoint  # type: ignore

    return torch, load_checkpoint


def content_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                parts.append(str(item.get("text", "")))
            elif isinstance(item, str):
                parts.append(item)
        return "\n".join(part for part in parts if part)
    return "" if content is None else str(content)


def latest_user_text(messages: list[dict[str, Any]]) -> str:
    for msg in reversed(messages):
        if msg.get("role") == "user":
            return content_text(msg.get("content"))
    return "\n".join(content_text(msg.get("content")) for msg in messages)


def one_line(text: str, limit: int) -> str:
    cleaned = " ".join(text.split())
    if len(cleaned) <= limit:
        return cleaned
    return cleaned[: limit - 3].rstrip() + "..."


def prompt_from_messages(messages: list[dict[str, Any]]) -> str:
    task = one_line(latest_user_text(messages), 220)
    if not task:
        task = "write a small Legible program"
    if task.startswith("function ") or task.startswith("record "):
        return task
    return f"function main(): nothing\n  intent: {task}\n  "


def generated_source(prompt: str, decoded: str) -> str:
    text = decoded if decoded.startswith(prompt) else prompt + decoded
    text = text.strip()
    if "function " in text:
        text = text[text.index("function ") :]
    if not text.endswith("\n"):
        text += "\n"
    return text


class NanoService:
    def __init__(
        self,
        checkpoint: Path,
        nano_repo: Path,
        device: str,
        default_max_new_tokens: int,
        default_temperature: float,
        default_top_k: int,
    ) -> None:
        torch, load_checkpoint = import_nano(nano_repo)
        if device == "auto":
            device = "cuda" if torch.cuda.is_available() else "cpu"
        self.torch = torch
        self.model, self.tokenizer = load_checkpoint(checkpoint, device)
        self.device = device
        self.default_max_new_tokens = default_max_new_tokens
        self.default_temperature = default_temperature
        self.default_top_k = default_top_k
        self.lock = threading.Lock()

    def complete(self, request: dict[str, Any]) -> str:
        messages = request.get("messages", [])
        if not isinstance(messages, list):
            messages = []
        prompt = prompt_from_messages(messages)
        max_tokens = request.get("max_tokens", self.default_max_new_tokens)
        try:
            max_new_tokens = min(int(max_tokens), self.default_max_new_tokens)
        except (TypeError, ValueError):
            max_new_tokens = self.default_max_new_tokens
        max_new_tokens = max(1, max_new_tokens)
        try:
            temperature = float(request.get("temperature", self.default_temperature))
        except (TypeError, ValueError):
            temperature = self.default_temperature
        temperature = max(temperature, 0.05)
        top_k = int(request.get("top_k", self.default_top_k))

        ids = self.tokenizer.encode(prompt, add_bos=True)
        x = self.torch.tensor(ids, dtype=self.torch.long, device=self.device)[None, ...]
        with self.lock, self.torch.no_grad():
            y = self.model.generate(
                x,
                max_new_tokens,
                temperature=temperature,
                top_k=top_k,
                eos_token_id=self.tokenizer.eos_id,
            )
        decoded = self.tokenizer.decode(y[0].tolist())
        source = generated_source(prompt, decoded)
        return "FINAL:\n" + source


def make_handler(service: NanoService) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "LegibleNanoHTTP/0.1"

        def log_message(self, format: str, *args: Any) -> None:
            print("%s - - [%s] %s" % (self.address_string(), self.log_date_time_string(), format % args))

        def send_json(self, status: int, body: dict[str, Any]) -> None:
            data = json.dumps(body).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:
            if self.path in {"/health", "/v1/health"}:
                self.send_json(200, {"status": "ok", "model": MODEL_ID})
            elif self.path == "/v1/models":
                self.send_json(
                    200,
                    {"object": "list", "data": [{"id": MODEL_ID, "object": "model", "owned_by": "local"}]},
                )
            else:
                self.send_json(404, {"error": {"message": "not found"}})

        def do_POST(self) -> None:
            if self.path != "/v1/chat/completions":
                self.send_json(404, {"error": {"message": "not found"}})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                content = service.complete(payload)
                created = int(time.time())
                self.send_json(
                    200,
                    {
                        "id": f"chatcmpl-legible-nano-{created}",
                        "object": "chat.completion",
                        "created": created,
                        "model": payload.get("model", MODEL_ID),
                        "choices": [
                            {
                                "index": 0,
                                "message": {"role": "assistant", "content": content},
                                "finish_reason": "stop",
                            }
                        ],
                    },
                )
            except Exception as exc:  # pragma: no cover - surfaced to the caller
                self.send_json(500, {"error": {"message": str(exc)}})

    return Handler


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Serve Legible-Nano as an OpenAI-compatible chat endpoint.")
    parser.add_argument("--host", default=os.environ.get("LEGIBLE_NANO_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("LEGIBLE_NANO_PORT", "8765")))
    parser.add_argument("--nano-repo", type=Path, default=Path(os.environ.get("LEGIBLE_NANO_REPO", DEFAULT_NANO_REPO)))
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=Path(os.environ.get("LEGIBLE_NANO_CHECKPOINT", DEFAULT_CHECKPOINT)),
    )
    parser.add_argument("--device", default=os.environ.get("LEGIBLE_NANO_DEVICE", "auto"))
    parser.add_argument(
        "--max-new-tokens",
        type=int,
        default=int(os.environ.get("LEGIBLE_NANO_MAX_NEW_TOKENS", "320")),
    )
    parser.add_argument(
        "--temperature",
        type=float,
        default=float(os.environ.get("LEGIBLE_NANO_TEMPERATURE", "0.8")),
    )
    parser.add_argument("--top-k", type=int, default=int(os.environ.get("LEGIBLE_NANO_TOP_K", "80")))
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    service = NanoService(
        args.checkpoint,
        args.nano_repo,
        args.device,
        args.max_new_tokens,
        args.temperature,
        args.top_k,
    )
    server = ThreadingHTTPServer((args.host, args.port), make_handler(service))
    print(f"Legible-Nano shim serving {args.checkpoint} on http://{args.host}:{args.port}/v1")
    server.serve_forever()


if __name__ == "__main__":
    main()
