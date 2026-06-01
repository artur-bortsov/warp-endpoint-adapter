#!/usr/bin/env python3
"""Run cloudflared in the foreground and persist the current quick-tunnel URL."""

from __future__ import annotations

import argparse
import pathlib
import re
import shutil
import signal
import subprocess
import sys
import time
from typing import TextIO

TUNNEL_URL_RE = re.compile(r"https://[-a-z0-9]+\.trycloudflare\.com")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run cloudflared and save the published tunnel URL.")
    parser.add_argument("--target", default="https://localhost:8787", help="Origin URL served by the adapter.")
    parser.add_argument("--log", default="cloudflared.log", help="Path to append cloudflared output.")
    parser.add_argument("--url-file", default="tunnel_url.txt", help="Path that receives the latest tunnel URL.")
    parser.add_argument("--cloudflared", default="cloudflared", help="cloudflared executable or absolute path.")
    return parser.parse_args()


def resolve_cloudflared(executable: str) -> str:
    resolved = executable
    has_path_separator = "/" in executable or "\\" in executable

    if not has_path_separator:
        which_result = shutil.which(executable)
        if which_result:
            resolved = which_result
        else:
            raise SystemExit("cloudflared was not found. Install it or pass --cloudflared.")

    return resolved


def write_line(log_handle: TextIO, line: str) -> None:
    sys.stdout.write(line)
    sys.stdout.flush()
    log_handle.write(line)
    log_handle.flush()


def save_tunnel_url(url_file: pathlib.Path, tunnel_url: str) -> None:
    url_file.parent.mkdir(parents=True, exist_ok=True)
    url_file.write_text(tunnel_url + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    log_path = pathlib.Path(args.log).expanduser().resolve()
    url_file = pathlib.Path(args.url_file).expanduser().resolve()
    cloudflared = resolve_cloudflared(args.cloudflared)
    process_holder: dict[str, subprocess.Popen[str] | None] = {"process": None}

    def stop_child(signum: int, _frame: object) -> None:
        child = process_holder["process"]
        if child and child.poll() is None:
            child.terminate()

    signal.signal(signal.SIGTERM, stop_child)
    signal.signal(signal.SIGINT, stop_child)

    log_path.parent.mkdir(parents=True, exist_ok=True)
    command = [cloudflared, "tunnel", "--url", args.target, "--no-tls-verify"]
    exit_code = 1

    with log_path.open("a", encoding="utf-8", buffering=1) as log_handle:
        write_line(log_handle, f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] starting: {' '.join(command)}\n")
        child = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        process_holder["process"] = child

        if child.stdout:
            for line in child.stdout:
                write_line(log_handle, line)
                match = TUNNEL_URL_RE.search(line)
                if match:
                    save_tunnel_url(url_file, match.group(0))

        exit_code = child.wait()
        write_line(log_handle, f"[{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}] cloudflared exited with {exit_code}\n")

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
