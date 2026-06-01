#!/usr/bin/env python3
"""Repository preparation checks for public release readiness."""

from __future__ import annotations

import pathlib
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
REQUIRED_FILES = [
    "README.md",
    "LICENSE",
    "CHANGELOG.md",
    ".gitignore",
    ".dockerignore",
    "Dockerfile",
    "docker-compose.yml",
    "adapter.py",
    "adapterctl.sh",
    "adapterctl.ps1",
    "installers/install-macos.sh",
    "installers/install-linux.sh",
    "installers/install-windows.ps1",
    "docker/README.md",
    "docker/QUICK_START.md",
    "docker/docker-entrypoint.sh",
    "docker/docker-quick-start.sh",
    "docker/docker-quick-start.ps1",
    "assets/project-thumbnail.svg",
    "assets/social-preview.svg",
    "assets/social-preview.png",
]


def main() -> int:
    errors: list[str] = []

    for relative in REQUIRED_FILES:
        if not (REPO_ROOT / relative).exists():
            errors.append(f"Missing required file: {relative}")

    readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
    gitignore = (REPO_ROOT / ".gitignore").read_text(encoding="utf-8")

    if "![Warp Kie.ai Endpoint Adapter](assets/project-thumbnail.svg)" not in readme:
        errors.append("README does not embed assets/project-thumbnail.svg immediately after the title.")
    if "## License" not in readme or "[LICENSE](LICENSE)" not in readme:
        errors.append("README must include a License section referencing LICENSE.")
    if "banner" in "\n".join(path.name.lower() for path in (REPO_ROOT / "assets").glob("*")):
        errors.append("Asset filenames must not contain 'banner'.")

    for pattern in ("*.log", "*.pid", "certs/", "tunnel_url.txt", "bin/cloudflared*", "docker-data/"):
        if pattern not in gitignore:
            errors.append(f".gitignore is missing runtime pattern: {pattern}")

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        status = 1
    else:
        print("Repository preparation checks passed.")
        status = 0

    return status


if __name__ == "__main__":
    raise SystemExit(main())
