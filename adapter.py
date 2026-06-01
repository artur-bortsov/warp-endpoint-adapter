#!/usr/bin/env python3
"""OpenAI-compatible HTTPS adapter for Kie.ai Claude endpoints."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import queue
import ssl
import sys
import time
import traceback
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

__version__ = "0.1.0"

KIE_MESSAGES_URL = "https://api.kie.ai/claude/v1/messages"
DEFAULT_MODEL = "claude-opus-4-8"
KNOWN_CLAUDE_MODELS = [
    "claude-opus-4-8",
    "claude-opus-4-7",
    "claude-opus-4-6",
    "claude-opus-4-5",
    "claude-sonnet-4-6",
    "claude-sonnet-4-5",
    "claude-haiku-4-5",
]
WARP_MODEL_ALIASES = {
    # Warp built-in model IDs include effort variants. Kie expects the base
    # Claude model ID in the upstream `model` field.
    "claude-4-7-opus-xhigh": "claude-opus-4-7",
    "claude-4-7-opus-high": "claude-opus-4-7",
    "claude-4-7-opus-max": "claude-opus-4-7",
    "claude-4-6-opus-high": "claude-opus-4-6",
    "claude-4-6-opus-max": "claude-opus-4-6",
    "claude-4-6-sonnet-high": "claude-sonnet-4-6",
    "claude-4-6-sonnet-max": "claude-sonnet-4-6",
    "claude-4-5-opus": "claude-opus-4-5",
    "claude-4-5-opus-thinking": "claude-opus-4-5",
    "claude-4-5-sonnet": "claude-sonnet-4-5",
    "claude-4-5-sonnet-thinking": "claude-sonnet-4-5",
    "claude-4-5-haiku": "claude-haiku-4-5",
}
CLAUDE_NATIVE_TOOL_NAMES = {
    "Bash",
    "Edit",
    "Glob",
    "Grep",
    "LS",
    "MultiEdit",
    "NotebookEdit",
    "Read",
    "Task",
    "TodoWrite",
    "WebFetch",
    "WebSearch",
    "Write",
}
MODEL_ALIASES: dict[str, str] = {}

for model_id in KNOWN_CLAUDE_MODELS:
    MODEL_ALIASES[model_id] = model_id

MODEL_ALIASES.update(WARP_MODEL_ALIASES)


def json_dumps(data: Any) -> bytes:
    return json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def openai_model_catalog() -> list[dict[str, Any]]:
    seen_model_ids: set[str] = set()
    model_ids: list[str] = []

    for model_id in KNOWN_CLAUDE_MODELS:
        if model_id not in seen_model_ids:
            model_ids.append(model_id)
            seen_model_ids.add(model_id)

    for model_id in WARP_MODEL_ALIASES:
        if model_id not in seen_model_ids:
            model_ids.append(model_id)
            seen_model_ids.add(model_id)

    return [
        {
            "id": model_id,
            "object": "model",
            "created": 0,
            "owned_by": "kie.ai",
        }
        for model_id in model_ids
    ]


def normalize_model(model: str | None) -> str:
    if not model:
        normalized = DEFAULT_MODEL
    else:
        normalized = MODEL_ALIASES.get(model, model)

    return normalized


def text_from_content(content: Any) -> str:
    text_parts: list[str] = []

    if isinstance(content, str):
        text_parts.append(content)
    elif isinstance(content, list):
        for part in content:
            if isinstance(part, str):
                text_parts.append(part)
            elif isinstance(part, dict):
                part_type = part.get("type")
                if part_type in (None, "text", "input_text"):
                    text = part.get("text") or part.get("content") or ""
                    if text:
                        text_parts.append(str(text))

    return "\n".join(text_parts)


def openai_content_to_claude_content(content: Any) -> Any:
    claude_content: Any = ""

    if isinstance(content, str):
        claude_content = content
    elif isinstance(content, list):
        blocks: list[dict[str, Any]] = []
        text_parts: list[str] = []

        for part in content:
            if isinstance(part, str):
                text_parts.append(part)
            elif isinstance(part, dict):
                part_type = part.get("type")
                if part_type in (None, "text", "input_text"):
                    text = part.get("text") or part.get("content") or ""
                    if text:
                        text_parts.append(str(text))
                elif part_type == "image_url":
                    blocks.append(part)

        if blocks:
            if text_parts:
                blocks.insert(0, {"type": "text", "text": "\n".join(text_parts)})
            claude_content = blocks
        elif text_parts:
            claude_content = "\n".join(text_parts)

    return claude_content


def prepend_system_to_messages(system_text: str, messages: list[dict[str, Any]]) -> None:
    prefix = "System/developer instructions:\n" + system_text

    if messages and messages[0].get("role") == "user":
        content = messages[0].get("content", "")
        if isinstance(content, str):
            messages[0]["content"] = prefix + "\n\nUser message:\n" + content
        elif isinstance(content, list):
            content.insert(0, {"type": "text", "text": prefix})
            messages[0]["content"] = content
    else:
        messages.insert(0, {"role": "user", "content": prefix})


def parse_tool_arguments(arguments: Any) -> dict[str, Any]:
    parsed: dict[str, Any] = {}

    if isinstance(arguments, dict):
        parsed = arguments
    elif isinstance(arguments, str) and arguments.strip():
        try:
            loaded = json.loads(arguments)
            if isinstance(loaded, dict):
                parsed = loaded
        except json.JSONDecodeError:
            parsed = {"_raw_arguments": arguments}

    return parsed


def openai_tool_names(tools: Any) -> list[str]:
    names: list[str] = []

    if isinstance(tools, list):
        for tool in tools:
            if isinstance(tool, dict) and tool.get("type") == "function":
                function = tool.get("function") or {}
                name = function.get("name")
                if isinstance(name, str) and name:
                    names.append(name)

    return names


def tool_compatibility_instruction(tool_names: list[str]) -> str:
    instruction = ""

    if tool_names:
        visible_names = ", ".join(tool_names[:80])
        instruction = (
            "Tool compatibility requirement for this OpenAI-compatible endpoint: "
            "use only tool names that are explicitly provided in this request. "
            "Do not call Claude Code native tools such as Bash, Read, Write, Edit, MultiEdit, Glob, Grep, "
            "Task, TodoWrite, WebFetch, or WebSearch. "
            "Available tool names are: "
            + visible_names
            + "."
        )

    return instruction


def resolve_tool_call_name(tool_name: str, available_tool_names: set[str] | None) -> str:
    resolved_name = tool_name

    if tool_name in CLAUDE_NATIVE_TOOL_NAMES:
        resolved_name = ""
    elif available_tool_names is not None and tool_name not in available_tool_names:
        resolved_name = ""

    return resolved_name


def unsupported_tool_message(tool_name: str) -> str:
    if tool_name:
        message = (
            "The model attempted to call the unsupported Claude-native tool `"
            + tool_name
            + "`. This adapter suppressed that tool call so Warp would not abort the response. "
            "Retry with a text-only request, or use a built-in Warp model when terminal/file tools are required."
        )
    else:
        message = (
            "The model attempted to call an unsupported tool. This adapter suppressed that tool call so Warp would not abort "
            "the response. Retry with a text-only request, or use a built-in Warp model when terminal/file tools are required."
        )
    return message


def unsupported_tool_names_from_kie_response(
    kie_response: dict[str, Any],
    available_tool_names: set[str] | None,
) -> list[str]:
    tool_names: list[str] = []

    for item in kie_response.get("content") or []:
        if isinstance(item, dict) and item.get("type") == "tool_use":
            tool_name = str(item.get("name") or "")
            if not resolve_tool_call_name(tool_name, available_tool_names):
                tool_names.append(tool_name)

    return tool_names


def text_only_fallback_instruction(tool_name: str) -> str:
    if tool_name:
        instruction = (
            "Your previous attempt tried to call the unavailable Claude-native tool `"
            + tool_name
            + "`. This OpenAI-compatible endpoint cannot execute terminal, file, browser, or other native tools. "
            "Answer the user's original request in text only. If execution would be required, explain what the user "
            "can run or check manually. Do not call any tools."
        )
    else:
        instruction = (
            "Your previous attempt tried to call an unavailable native tool. This OpenAI-compatible endpoint cannot "
            "execute terminal, file, browser, or other native tools. Answer the user's original request in text only. "
            "If execution would be required, explain what the user can run or check manually. Do not call any tools."
        )

    return instruction


def build_text_fallback_payload(base_payload: dict[str, Any], tool_name: str, stream: bool) -> dict[str, Any]:
    fallback_payload = dict(base_payload)
    messages = json.loads(json.dumps(base_payload.get("messages") or []))
    messages.append({"role": "user", "content": text_only_fallback_instruction(tool_name)})
    fallback_payload["messages"] = messages
    fallback_payload["stream"] = stream
    fallback_payload.pop("tools", None)

    return fallback_payload

def convert_openai_messages(messages: list[dict[str, Any]], system_mode: str) -> tuple[list[dict[str, Any]], str]:
    claude_messages: list[dict[str, Any]] = []
    system_parts: list[str] = []

    for message in messages:
        role = message.get("role", "")

        if role in ("system", "developer"):
            system_text = text_from_content(message.get("content"))
            if system_text:
                system_parts.append(system_text)
        elif role == "user":
            claude_messages.append(
                {
                    "role": "user",
                    "content": openai_content_to_claude_content(message.get("content", "")),
                }
            )
        elif role == "assistant":
            content_blocks: list[dict[str, Any]] = []
            assistant_text = text_from_content(message.get("content"))
            if assistant_text:
                content_blocks.append({"type": "text", "text": assistant_text})

            for tool_call in message.get("tool_calls") or []:
                function = tool_call.get("function") or {}
                content_blocks.append(
                    {
                        "type": "tool_use",
                        "id": tool_call.get("id") or "toolu_" + uuid.uuid4().hex,
                        "name": function.get("name", ""),
                        "input": parse_tool_arguments(function.get("arguments")),
                    }
                )

            if content_blocks:
                claude_messages.append({"role": "assistant", "content": content_blocks})
            else:
                claude_messages.append({"role": "assistant", "content": ""})
        elif role == "tool":
            tool_result = {
                "type": "tool_result",
                "tool_use_id": message.get("tool_call_id", ""),
                "content": text_from_content(message.get("content")),
            }
            claude_messages.append({"role": "user", "content": [tool_result]})
        elif role == "function":
            tool_result = {
                "type": "tool_result",
                "tool_use_id": message.get("name", ""),
                "content": text_from_content(message.get("content")),
            }
            claude_messages.append({"role": "user", "content": [tool_result]})

    system_text = "\n\n".join(system_parts)
    if system_text and system_mode == "prepend":
        prepend_system_to_messages(system_text, claude_messages)

    return claude_messages, system_text


def convert_openai_tools(tools: Any) -> list[dict[str, Any]]:
    claude_tools: list[dict[str, Any]] = []

    if isinstance(tools, list):
        for tool in tools:
            if isinstance(tool, dict) and tool.get("type") == "function":
                function = tool.get("function") or {}
                name = function.get("name")
                if name:
                    claude_tools.append(
                        {
                            "name": name,
                            "description": function.get("description") or "",
                            "input_schema": function.get("parameters") or {"type": "object", "properties": {}},
                        }
                    )

    return claude_tools


def convert_openai_to_kie(payload: dict[str, Any], system_mode: str, stream: bool = False) -> dict[str, Any]:
    messages, system_text = convert_openai_messages(payload.get("messages") or [], system_mode)
    tool_names = openai_tool_names(payload.get("tools"))
    compatibility_instruction = tool_compatibility_instruction(tool_names)
    kie_payload: dict[str, Any] = {
        "model": normalize_model(payload.get("model")),
        "messages": messages,
        "stream": stream,
        "max_tokens": payload.get("max_tokens") or 4096,
    }

    tools = convert_openai_tools(payload.get("tools"))
    if tools:
        kie_payload["tools"] = tools
    if compatibility_instruction:
        if system_mode == "top_level":
            if system_text:
                system_text = system_text + "\n\n" + compatibility_instruction
            else:
                system_text = compatibility_instruction
        else:
            prepend_system_to_messages(compatibility_instruction, messages)

    if system_text and system_mode == "top_level":
        kie_payload["system"] = system_text

    return kie_payload


def convert_usage(kie_usage: dict[str, Any]) -> dict[str, Any]:
    prompt_tokens = int(kie_usage.get("input_tokens") or 0)
    completion_tokens = int(kie_usage.get("output_tokens") or 0)

    return {
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion_tokens,
        "total_tokens": prompt_tokens + completion_tokens,
    }


def convert_kie_to_openai(
    kie_response: dict[str, Any],
    requested_model: str,
    available_tool_names: set[str] | None = None,
) -> dict[str, Any]:
    text_parts: list[str] = []
    tool_calls: list[dict[str, Any]] = []

    for item in kie_response.get("content") or []:
        if isinstance(item, dict):
            item_type = item.get("type")
            if item_type == "text":
                text_parts.append(str(item.get("text", "")))
            elif item_type == "tool_use":
                tool_name = str(item.get("name") or "")
                resolved_tool_name = resolve_tool_call_name(tool_name, available_tool_names)
                if resolved_tool_name:
                    tool_calls.append(
                        {
                            "id": item.get("id") or "call_" + uuid.uuid4().hex,
                            "type": "function",
                            "function": {
                                "name": resolved_tool_name,
                                "arguments": json.dumps(item.get("input") or {}, ensure_ascii=False),
                            },
                        }
                    )
                else:
                    text_parts.append(unsupported_tool_message(tool_name))

    message: dict[str, Any] = {"role": "assistant", "content": "\n".join(text_parts) or None}
    finish_reason = "stop"

    if tool_calls:
        message["tool_calls"] = tool_calls
        finish_reason = "tool_calls"

    return {
        "id": kie_response.get("id") or "chatcmpl-" + uuid.uuid4().hex,
        "object": "chat.completion",
        "created": int(time.time()),
        "model": requested_model,
        "choices": [
            {
                "index": 0,
                "message": message,
                "finish_reason": finish_reason,
            }
        ],
        "usage": convert_usage(kie_response.get("usage") or {}),
    }


def summarize_openai_response(completion: dict[str, Any]) -> dict[str, Any]:
    choice = (completion.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    content = message.get("content") or ""
    tool_calls = message.get("tool_calls") or []
    argument_chars = 0

    for tool_call in tool_calls:
        function = tool_call.get("function") or {}
        argument_chars += len(function.get("arguments") or "")

    return {
        "finish_reason": choice.get("finish_reason"),
        "text_chars": len(content),
        "tool_calls": len(tool_calls),
        "tool_argument_chars": argument_chars,
    }


def map_kie_stop_reason(stop_reason: str | None) -> str:
    finish_reason = "stop"

    if stop_reason == "tool_use":
        finish_reason = "tool_calls"
    elif stop_reason == "max_tokens":
        finish_reason = "length"

    return finish_reason


class AdapterServer(ThreadingHTTPServer):
    def __init__(
        self,
        server_address: tuple[str, int],
        handler_class: type[BaseHTTPRequestHandler],
        upstream_timeout: int,
        system_mode: str,
        stream_heartbeat_seconds: int,
    ) -> None:
        super().__init__(server_address, handler_class)
        self.upstream_timeout = upstream_timeout
        self.system_mode = system_mode
        self.stream_heartbeat_seconds = stream_heartbeat_seconds


class AdapterHandler(BaseHTTPRequestHandler):
    server: AdapterServer
    protocol_version = "HTTP/1.1"

    def log_message(self, format_string: str, *args: Any) -> None:
        safe_args: list[Any] = []

        for index, arg in enumerate(args):
            if isinstance(arg, int):
                safe_args.append(arg)
            else:
                text = str(arg).replace("\n", "\\n").replace("\r", "\\r")
                if index == 0 and format_string.startswith('"%s"'):
                    parts = text.split()
                    method = parts[0][:16] if parts else "<invalid>"
                    path = parts[1] if len(parts) > 1 and parts[1].startswith("/") else "<invalid>"
                    text = method + " " + path
                elif len(text) > 200:
                    text = text[:200] + "...[truncated]"
                safe_args.append(text)

        try:
            message = format_string % tuple(safe_args)
        except TypeError:
            message = format_string

        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), message))

    def log_event(self, request_id: str, event: str, **fields: Any) -> None:
        safe_fields: dict[str, Any] = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "request_id": request_id,
            "event": event,
            "remote": self.client_address[0] if self.client_address else None,
        }

        for key, value in fields.items():
            if isinstance(value, (str, int, float, bool)) or value is None:
                safe_fields[key] = value
            else:
                safe_fields[key] = str(value)

        sys.stderr.write(json.dumps(safe_fields, ensure_ascii=False, separators=(",", ":")) + "\n")

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json_dumps(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def send_no_content(self) -> None:
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def bearer_token(self) -> str:
        authorization = self.headers.get("Authorization") or ""
        token = authorization.strip()

        if token.lower().startswith("bearer "):
            token = token[7:].strip()
        if token.lower().startswith("bearer "):
            token = token[7:].strip()

        return token

    def request_kie_api_key(self) -> str:
        return self.bearer_token()

    def discard_request_body(self) -> None:
        try:
            content_length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            content_length = 0

        if content_length > 0:
            self.rfile.read(content_length)

    def reject_unauthorized(self) -> None:
        self.close_connection = True
        self.send_json(
            401,
            {
                "error": {
                    "message": "Unauthorized",
                    "type": "authentication_error",
                }
            },
        )

    def do_OPTIONS(self) -> None:
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/")

        if path in ("", "/healthz", "/v1/healthz"):
            self.send_json(200, {"status": "ok", "upstream": "kie.ai", "model": DEFAULT_MODEL})
        elif path in ("/models", "/v1/models"):
            self.send_json(
                200,
                {
                    "object": "list",
                    "data": openai_model_catalog(),
                },
            )
        else:
            self.send_json(404, {"error": {"message": "Not found", "type": "not_found_error"}})

    def read_json_body(self) -> dict[str, Any]:
        content_length = int(self.headers.get("Content-Length") or "0")
        raw_body = self.rfile.read(content_length)
        body = json.loads(raw_body.decode("utf-8"))

        if not isinstance(body, dict):
            raise ValueError("Request body must be a JSON object")

        return body

    def call_kie(self, payload: dict[str, Any], request_id: str, kie_api_key: str) -> dict[str, Any]:
        headers = {
            "Authorization": "Bearer " + kie_api_key,
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
            "User-Agent": "warp-kie-adapter/" + __version__,
        }
        request = urllib.request.Request(KIE_MESSAGES_URL, data=json_dumps(payload), headers=headers, method="POST")
        started_at = time.monotonic()
        raw_response = ""
        status = 0

        self.log_event(
            request_id,
            "upstream_started",
            upstream="kie.ai",
            model=payload.get("model"),
            stream=bool(payload.get("stream")),
            max_tokens=payload.get("max_tokens"),
        )

        try:
            with urllib.request.urlopen(request, timeout=self.server.upstream_timeout) as response:
                raw_response = response.read().decode("utf-8", errors="replace")
                status = response.status
        except urllib.error.HTTPError as error:
            raw_response = error.read().decode("utf-8", errors="replace")
            status = error.code
        except Exception as error:
            self.log_event(
                request_id,
                "upstream_failed",
                elapsed_ms=int((time.monotonic() - started_at) * 1000),
                error_type=type(error).__name__,
                message=str(error),
            )
            raise

        self.log_event(
            request_id,
            "upstream_finished",
            status=status,
            elapsed_ms=int((time.monotonic() - started_at) * 1000),
            response_bytes=len(raw_response.encode("utf-8")),
        )

        try:
            parsed = json.loads(raw_response)
        except json.JSONDecodeError as error:
            parsed = {
                "code": status,
                "msg": "Upstream returned non-JSON response",
                "raw": raw_response[:1000],
                "parse_error": str(error),
            }

        if not isinstance(parsed, dict):
            parsed = {"code": status, "msg": "Upstream returned unexpected JSON response", "raw": parsed}

        if status >= 400:
            parsed.setdefault("code", status)
            parsed.setdefault("msg", "Upstream HTTP error")

        return parsed

    def stream_kie_to_queue(
        self,
        payload: dict[str, Any],
        request_id: str,
        kie_api_key: str,
        output_queue: queue.Queue[tuple[str, Any]],
    ) -> None:
        stream_payload = dict(payload)
        stream_payload["stream"] = True
        headers = {
            "Authorization": "Bearer " + kie_api_key,
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01",
            "User-Agent": "warp-kie-adapter/" + __version__,
        }
        request = urllib.request.Request(KIE_MESSAGES_URL, data=json_dumps(stream_payload), headers=headers, method="POST")
        started_at = time.monotonic()
        status = 0

        self.log_event(
            request_id,
            "upstream_started",
            upstream="kie.ai",
            model=stream_payload.get("model"),
            stream=True,
            max_tokens=stream_payload.get("max_tokens"),
        )

        try:
            with urllib.request.urlopen(request, timeout=self.server.upstream_timeout) as response:
                status = response.status
                self.log_event(
                    request_id,
                    "upstream_stream_opened",
                    status=status,
                    elapsed_ms=int((time.monotonic() - started_at) * 1000),
                )
                for raw_line in response:
                    line = raw_line.decode("utf-8", errors="replace").strip()
                    if line.startswith("data:"):
                        data = line[5:].strip()
                        if data and data != "[DONE]":
                            try:
                                output_queue.put(("event", json.loads(data)))
                            except json.JSONDecodeError as error:
                                output_queue.put(("error", {"message": "Upstream returned invalid SSE JSON", "detail": str(error)}))
                        elif data == "[DONE]":
                            output_queue.put(("done", None))
        except urllib.error.HTTPError as error:
            raw_response = error.read().decode("utf-8", errors="replace")
            status = error.code
            message = "Upstream HTTP error"
            try:
                parsed_error = json.loads(raw_response)
                if isinstance(parsed_error, dict):
                    message = parsed_error.get("msg") or parsed_error.get("message") or message
            except json.JSONDecodeError:
                message = raw_response[:300] or message
            output_queue.put(("error", {"message": message, "code": status}))
        except Exception as error:
            self.log_event(
                request_id,
                "upstream_failed",
                elapsed_ms=int((time.monotonic() - started_at) * 1000),
                error_type=type(error).__name__,
                message=str(error),
            )
            output_queue.put(("error", {"message": str(error)}))

        self.log_event(
            request_id,
            "upstream_finished",
            status=status,
            elapsed_ms=int((time.monotonic() - started_at) * 1000),
            response_mode="sse_upstream",
        )
        output_queue.put(("done", None))

    def do_POST(self) -> None:
        request_id = uuid.uuid4().hex[:12]
        path = self.path.split("?", 1)[0].rstrip("/")
        kie_api_key = self.request_kie_api_key()

        if not kie_api_key:
            self.discard_request_body()
            self.log_event(request_id, "unauthorized", method="POST", path=path)
            self.reject_unauthorized()
            return

        if path not in ("/chat/completions", "/v1/chat/completions"):
            self.send_json(404, {"error": {"message": "Not found", "type": "not_found_error"}})
        else:
            try:
                openai_request = self.read_json_body()
                requested_model = openai_request.get("model") or DEFAULT_MODEL
                stream = bool(openai_request.get("stream"))
                available_tool_names = set(openai_tool_names(openai_request.get("tools")))
                kie_payload = convert_openai_to_kie(openai_request, self.server.system_mode)
                fallback_openai_request = dict(openai_request)
                fallback_openai_request["tools"] = []
                fallback_openai_request.pop("tool_choice", None)
                text_fallback_payload = convert_openai_to_kie(fallback_openai_request, self.server.system_mode)

                self.log_event(
                    request_id,
                    "request_started",
                    method="POST",
                    path=path,
                    model=requested_model,
                    upstream_model=kie_payload.get("model"),
                    stream=stream,
                    messages=len(openai_request.get("messages") or []),
                    tools=len(openai_request.get("tools") or []),
                )

                if stream:
                    self.send_streaming_upstream_response(
                        kie_payload,
                        text_fallback_payload,
                        requested_model,
                        request_id,
                        kie_api_key,
                        available_tool_names,
                    )
                else:
                    kie_response = self.call_kie(kie_payload, request_id, kie_api_key)
                    if "code" in kie_response and kie_response.get("code") not in (0, 200):
                        self.log_event(request_id, "request_failed", code=kie_response.get("code"))
                        self.send_json(
                            502,
                            {
                                "error": {
                                    "message": kie_response.get("msg") or "Kie.ai request failed",
                                    "type": "upstream_error",
                                    "code": kie_response.get("code"),
                                }
                            },
                        )
                    else:
                        unsupported_tool_names = unsupported_tool_names_from_kie_response(
                            kie_response,
                            available_tool_names,
                        )
                        if unsupported_tool_names:
                            fallback_payload = build_text_fallback_payload(
                                text_fallback_payload,
                                unsupported_tool_names[0],
                                False,
                            )
                            self.log_event(
                                request_id,
                                "text_fallback_started",
                                tool_name=unsupported_tool_names[0],
                                response_mode="json",
                            )
                            fallback_response = self.call_kie(fallback_payload, request_id, kie_api_key)
                            if "code" in fallback_response and fallback_response.get("code") not in (0, 200):
                                self.log_event(
                                    request_id,
                                    "text_fallback_failed",
                                    code=fallback_response.get("code"),
                                    response_mode="json",
                                )
                                openai_response = convert_kie_to_openai(
                                    kie_response,
                                    requested_model,
                                    available_tool_names,
                                )
                            else:
                                openai_response = convert_kie_to_openai(fallback_response, requested_model, set())
                                self.log_event(
                                    request_id,
                                    "text_fallback_finished",
                                    response_mode="json",
                                    **summarize_openai_response(openai_response),
                                )
                        else:
                            openai_response = convert_kie_to_openai(kie_response, requested_model, available_tool_names)
                        self.send_json(200, openai_response)
                        self.log_event(
                            request_id,
                            "request_finished",
                            status=200,
                            response_mode="json",
                            **summarize_openai_response(openai_response),
                        )
            except Exception as error:
                self.log_event(request_id, "adapter_error", error_type=type(error).__name__, message=str(error))
                traceback.print_exc()
                self.send_json(
                    500,
                    {
                        "error": {
                            "message": str(error),
                            "type": "adapter_error",
                        }
                    },
                )

    def begin_sse(self) -> None:
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

    def write_sse(self, payload: dict[str, Any] | str) -> None:
        if isinstance(payload, str):
            line = "data: " + payload + "\n\n"
        else:
            line = "data: " + json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n\n"
        self.wfile.write(line.encode("utf-8"))
        self.wfile.flush()

    def write_chat_chunk(
        self,
        completion_id: str,
        created: int,
        model: str,
        delta: dict[str, Any],
        finish_reason: str | None,
    ) -> None:
        self.write_sse(
            {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}],
            }
        )

    def write_tool_call_chunks(
        self,
        completion_id: str,
        created: int,
        model: str,
        index: int,
        tool_call: dict[str, Any],
    ) -> int:
        function = tool_call.get("function") or {}
        arguments = function.get("arguments") or ""
        chunk_count = 1

        self.write_chat_chunk(
            completion_id,
            created,
            model,
            {
                "tool_calls": [
                    {
                        "index": index,
                        "id": tool_call.get("id"),
                        "type": "function",
                        "function": {
                            "name": function.get("name", ""),
                            "arguments": "",
                        },
                    }
                ]
            },
            None,
        )

        if arguments:
            self.write_chat_chunk(
                completion_id,
                created,
                model,
                {
                    "tool_calls": [
                        {
                            "index": index,
                            "function": {
                                "arguments": arguments,
                            },
                        }
                    ]
                },
                None,
            )
            chunk_count += 1

        return chunk_count

    def send_streaming_completion_chunks(self, completion: dict[str, Any], include_role: bool = True) -> int:
        completion_id = completion["id"]
        created = completion["created"]
        model = completion["model"]
        choice = completion["choices"][0]
        message = choice["message"]
        tool_calls = message.get("tool_calls") or []
        chunk_count = 0

        if include_role:
            self.write_chat_chunk(completion_id, created, model, {"role": "assistant"}, None)
            chunk_count += 1

        if tool_calls:
            for index, tool_call in enumerate(tool_calls):
                chunk_count += self.write_tool_call_chunks(completion_id, created, model, index, tool_call)
            finish_reason = "tool_calls"
        else:
            content = message.get("content") or ""
            if content:
                self.write_chat_chunk(completion_id, created, model, {"content": content}, None)
                chunk_count += 1
            finish_reason = choice.get("finish_reason") or "stop"

        self.write_chat_chunk(completion_id, created, model, {}, finish_reason)
        self.write_sse("[DONE]")
        self.close_connection = True
        return chunk_count + 2
    def stream_text_fallback_response(
        self,
        text_fallback_payload: dict[str, Any],
        tool_name: str,
        completion_id: str,
        created: int,
        requested_model: str,
        request_id: str,
        kie_api_key: str,
        heartbeat_seconds: int,
    ) -> dict[str, Any]:
        fallback_payload = build_text_fallback_payload(text_fallback_payload, tool_name, True)
        fallback_events: queue.Queue[tuple[str, Any]] = queue.Queue()
        stats: dict[str, Any] = {
            "chunks": 0,
            "heartbeats": 0,
            "text_chars": 0,
            "suppressed_tool_calls": 0,
            "finish_reason": "stop",
            "fallback_failed": False,
        }
        final_received = False

        self.log_event(request_id, "text_fallback_started", tool_name=tool_name, response_mode="sse")

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            executor.submit(self.stream_kie_to_queue, fallback_payload, request_id, kie_api_key, fallback_events)
            while not final_received:
                try:
                    event_type, event_payload = fallback_events.get(timeout=heartbeat_seconds)
                except queue.Empty:
                    stats["heartbeats"] += 1
                    self.write_chat_chunk(completion_id, created, requested_model, {}, None)
                    stats["chunks"] += 1
                    continue

                if event_type == "error":
                    fallback_message = (
                        "The model tried to use an unavailable native tool, and the text-only fallback request failed. "
                        "Please retry and explicitly ask for text-only guidance."
                    )
                    stats["fallback_failed"] = True
                    stats["text_chars"] += len(fallback_message)
                    self.write_chat_chunk(completion_id, created, requested_model, {"content": fallback_message}, None)
                    stats["chunks"] += 1
                    final_received = True
                elif event_type == "done":
                    final_received = True
                elif event_type == "event" and isinstance(event_payload, dict):
                    kie_event_type = event_payload.get("type")
                    if kie_event_type == "content_block_start":
                        content_block = event_payload.get("content_block") or {}
                        if content_block.get("type") == "tool_use":
                            stats["suppressed_tool_calls"] += 1
                            self.log_event(
                                request_id,
                                "unsupported_tool_call_suppressed",
                                tool_name=str(content_block.get("name") or ""),
                                block_index=int(event_payload.get("index") or 0),
                                fallback=True,
                            )
                    elif kie_event_type == "content_block_delta":
                        delta = event_payload.get("delta") or {}
                        if delta.get("type") == "text_delta":
                            text = delta.get("text") or ""
                            if text:
                                stats["text_chars"] += len(text)
                                self.write_chat_chunk(completion_id, created, requested_model, {"content": text}, None)
                                stats["chunks"] += 1
                    elif kie_event_type == "message_delta":
                        delta = event_payload.get("delta") or {}
                        finish_reason = map_kie_stop_reason(delta.get("stop_reason"))
                        if finish_reason != "tool_calls":
                            stats["finish_reason"] = finish_reason
                    elif kie_event_type == "message_stop":
                        final_received = True

        if stats["text_chars"] == 0:
            empty_fallback_message = (
                "The model tried to use an unavailable native tool and did not produce a text-only fallback. "
                "Please retry and explicitly ask for text-only guidance."
            )
            stats["text_chars"] += len(empty_fallback_message)
            self.write_chat_chunk(completion_id, created, requested_model, {"content": empty_fallback_message}, None)
            stats["chunks"] += 1

        self.log_event(
            request_id,
            "text_fallback_finished",
            response_mode="sse",
            chunks=stats["chunks"],
            text_chars=stats["text_chars"],
            suppressed_tool_calls=stats["suppressed_tool_calls"],
            fallback_failed=stats["fallback_failed"],
        )

        return stats

    def send_streaming_completion(self, completion: dict[str, Any]) -> None:
        self.begin_sse()
        self.send_streaming_completion_chunks(completion)

    def send_streaming_error(self, message: str, code: Any = None) -> None:
        payload: dict[str, Any] = {
            "error": {
                "message": message,
                "type": "upstream_error",
            }
        }

        if code is not None:
            payload["error"]["code"] = code

        self.write_sse(payload)
        self.write_sse("[DONE]")
        self.close_connection = True

    def send_streaming_upstream_response(
        self,
        kie_payload: dict[str, Any],
        text_fallback_payload: dict[str, Any],
        requested_model: str,
        request_id: str,
        kie_api_key: str,
        available_tool_names: set[str] | None = None,
    ) -> None:
        completion_id = "chatcmpl-" + uuid.uuid4().hex
        created = int(time.time())
        heartbeat_count = 0
        heartbeat_seconds = max(1, self.server.stream_heartbeat_seconds)
        chunk_count = 1
        text_chars = 0
        tool_argument_chars = 0
        tool_call_indexes: dict[int, int] = {}
        suppressed_tool_indexes: set[int] = set()
        suppressed_tool_name = ""
        fallback_suppressed_tool_calls = 0
        fallback_used = False
        fallback_failed = False
        finish_reason = "stop"
        final_sent = False
        response_closed = False

        try:
            self.begin_sse()
            self.write_chat_chunk(completion_id, created, requested_model, {"role": "assistant"}, None)
            self.log_event(request_id, "stream_started", status=200)
            upstream_events: queue.Queue[tuple[str, Any]] = queue.Queue()

            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                executor.submit(self.stream_kie_to_queue, kie_payload, request_id, kie_api_key, upstream_events)
                while not final_sent:
                    try:
                        event_type, event_payload = upstream_events.get(timeout=heartbeat_seconds)
                    except queue.Empty:
                        heartbeat_count += 1
                        self.write_chat_chunk(completion_id, created, requested_model, {}, None)
                        chunk_count += 1
                        continue

                    if event_type == "error":
                        message = event_payload.get("message") or "Kie.ai request failed"
                        self.log_event(
                            request_id,
                            "request_failed",
                            code=event_payload.get("code"),
                            response_mode="sse",
                        )
                        self.send_streaming_error(message, event_payload.get("code"))
                        response_closed = True
                        final_sent = True
                    elif event_type == "done":
                        final_sent = True
                    elif event_type == "event" and isinstance(event_payload, dict):
                        kie_event_type = event_payload.get("type")
                        if kie_event_type == "content_block_start":
                            index = int(event_payload.get("index") or 0)
                            content_block = event_payload.get("content_block") or {}
                            if content_block.get("type") == "tool_use":
                                tool_name = str(content_block.get("name") or "")
                                resolved_tool_name = resolve_tool_call_name(tool_name, available_tool_names)
                                if resolved_tool_name:
                                    tool_call_index = len(tool_call_indexes)
                                    tool_call_indexes[index] = tool_call_index
                                    self.write_chat_chunk(
                                        completion_id,
                                        created,
                                        requested_model,
                                        {
                                            "tool_calls": [
                                                {
                                                    "index": tool_call_index,
                                                    "id": content_block.get("id"),
                                                    "type": "function",
                                                    "function": {
                                                        "name": resolved_tool_name,
                                                        "arguments": "",
                                                    },
                                                }
                                            ]
                                        },
                                        None,
                                    )
                                    chunk_count += 1
                                else:
                                    suppressed_tool_indexes.add(index)
                                    if not suppressed_tool_name:
                                        suppressed_tool_name = tool_name
                                    self.log_event(
                                        request_id,
                                        "unsupported_tool_call_suppressed",
                                        tool_name=tool_name,
                                        block_index=index,
                                    )
                        elif kie_event_type == "content_block_delta":
                            index = int(event_payload.get("index") or 0)
                            delta = event_payload.get("delta") or {}
                            delta_type = delta.get("type")
                            if delta_type == "text_delta":
                                text = delta.get("text") or ""
                                if text:
                                    text_chars += len(text)
                                    self.write_chat_chunk(completion_id, created, requested_model, {"content": text}, None)
                                    chunk_count += 1
                            elif delta_type == "input_json_delta":
                                partial_json = delta.get("partial_json") or ""
                                if partial_json and index in tool_call_indexes:
                                    tool_call_index = tool_call_indexes[index]
                                    tool_argument_chars += len(partial_json)
                                    self.write_chat_chunk(
                                        completion_id,
                                        created,
                                        requested_model,
                                        {
                                            "tool_calls": [
                                                {
                                                    "index": tool_call_index,
                                                    "function": {
                                                        "arguments": partial_json,
                                                    },
                                                }
                                            ]
                                        },
                                        None,
                                    )
                                    chunk_count += 1
                        elif kie_event_type == "message_delta":
                            delta = event_payload.get("delta") or {}
                            finish_reason = map_kie_stop_reason(delta.get("stop_reason"))
                        elif kie_event_type == "message_stop":
                            final_sent = True

            if not response_closed:
                fallback_stats: dict[str, Any] = {}
                if suppressed_tool_indexes and not tool_call_indexes:
                    fallback_used = True
                    fallback_stats = self.stream_text_fallback_response(
                        text_fallback_payload,
                        suppressed_tool_name,
                        completion_id,
                        created,
                        requested_model,
                        request_id,
                        kie_api_key,
                        heartbeat_seconds,
                    )
                    heartbeat_count += int(fallback_stats.get("heartbeats") or 0)
                    chunk_count += int(fallback_stats.get("chunks") or 0)
                    text_chars += int(fallback_stats.get("text_chars") or 0)
                    finish_reason = str(fallback_stats.get("finish_reason") or "stop")
                    fallback_failed = bool(fallback_stats.get("fallback_failed"))
                    fallback_suppressed_tool_calls = int(fallback_stats.get("suppressed_tool_calls") or 0)
                elif finish_reason == "tool_calls" and not tool_call_indexes:
                    finish_reason = "stop"
                self.write_chat_chunk(completion_id, created, requested_model, {}, finish_reason)
                self.write_sse("[DONE]")
                chunk_count += 2
                self.log_event(
                    request_id,
                    "request_finished",
                    status=200,
                    response_mode="sse",
                    heartbeats=heartbeat_count,
                    chunks=chunk_count,
                    finish_reason=finish_reason,
                    text_chars=text_chars,
                    tool_calls=len(tool_call_indexes),
                    suppressed_tool_calls=len(suppressed_tool_indexes) + fallback_suppressed_tool_calls,
                    fallback_used=fallback_used,
                    fallback_failed=fallback_failed,
                    tool_argument_chars=tool_argument_chars,
                )
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError) as error:
            self.log_event(request_id, "client_disconnected", error_type=type(error).__name__)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="HTTPS OpenAI-compatible adapter for Kie.ai Claude.")
    parser.add_argument("--host", default=os.environ.get("ADAPTER_BIND_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("ADAPTER_PORT", "8787")))
    parser.add_argument("--cert", default=os.environ.get("ADAPTER_CERT"))
    parser.add_argument("--key", default=os.environ.get("ADAPTER_KEY"))
    parser.add_argument("--upstream-timeout", type=int, default=int(os.environ.get("UPSTREAM_TIMEOUT", "180")))
    parser.add_argument(
        "--stream-heartbeat-seconds",
        type=int,
        default=int(os.environ.get("STREAM_HEARTBEAT_SECONDS", "10")),
    )
    parser.add_argument("--system-mode", choices=("prepend", "top_level"), default=os.environ.get("KIE_SYSTEM_MODE", "prepend"))

    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if not args.cert or not args.key:
        raise SystemExit("HTTPS certificate and key are required. Pass --cert and --key.")

    httpd = AdapterServer(
        (args.host, args.port),
        AdapterHandler,
        args.upstream_timeout,
        args.system_mode,
        args.stream_heartbeat_seconds,
    )

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certfile=args.cert, keyfile=args.key)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)

    sys.stderr.write(f"Warp Kie.ai Endpoint Adapter v{__version__} starting\n")
    sys.stderr.write(f"Serving HTTPS adapter on {args.host}:{args.port}\n")
    sys.stderr.write(f"Configure Warp base URL as https://<trusted-hostname>:{args.port}/v1\n")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
