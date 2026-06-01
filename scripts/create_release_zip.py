#!/usr/bin/env python3
"""Create the release ZIP expected by the repository preparation pipeline."""

from __future__ import annotations

import pathlib
import re
import zipfile

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT_NAME = "warp-endpoint-adapter"
EXCLUDED_DIRS = {".git", "__pycache__", "certs", "dist", ".venv", "venv", "docker-data"}
EXCLUDED_NAMES = {".env", "adapter_api_key.txt", "adapter.pid", "cloudflared.pid", "tunnel_url.txt"}
EXCLUDED_SUFFIXES = {".pyc", ".pyo", ".log"}


def adapter_version() -> str:
    text = (REPO_ROOT / "adapter.py").read_text(encoding="utf-8")
    match = re.search(r'^__version__\s*=\s*["\']([^"\']+)["\']', text, re.MULTILINE)
    version = "0.0.0"

    if match:
        version = match.group(1)

    return version


def should_include(path: pathlib.Path) -> bool:
    relative_parts = path.relative_to(REPO_ROOT).parts
    include = True

    if any(part in EXCLUDED_DIRS for part in relative_parts):
        include = False
    elif path.name in EXCLUDED_NAMES:
        include = False
    elif path.suffix in EXCLUDED_SUFFIXES:
        include = False
    elif path.name.startswith("cloudflared") and path.parent.name == "bin":
        include = False

    return include


def main() -> None:
    version = adapter_version()
    dist_dir = REPO_ROOT / "dist"
    zip_path = dist_dir / f"{PROJECT_NAME}-v{version}.zip"
    archive_root = f"{PROJECT_NAME}-v{version}"

    dist_dir.mkdir(exist_ok=True)
    if zip_path.exists():
        zip_path.unlink()

    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(REPO_ROOT.rglob("*")):
            if path.is_file() and should_include(path):
                relative = path.relative_to(REPO_ROOT)
                archive.write(path, pathlib.PurePosixPath(archive_root, *relative.parts))

    print(zip_path)


if __name__ == "__main__":
    main()
