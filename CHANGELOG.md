# Changelog

## [0.1.0] – 2026-05-31
### Added
- Initial OpenAI-compatible HTTPS adapter for Kie.ai Claude models in Warp.
- Bearer-token forwarding so Warp's configured Kie API key is used per request.
- Kie Claude model IDs plus Warp Claude model ID compatibility mapping.
- Streaming and tool-call translation between Kie Claude messages and OpenAI chat completions.
- macOS, Linux, and Windows installers with manual and service modes.
- Dockerfile and Docker Compose support for adapter-only and optional Cloudflare Tunnel containers.
- `adapterctl` models command for listing accepted model IDs without a local Kie API key.
- Linux `adapterctl` status output detects systemd user services created by the installer.
- Streaming SSL write failures after a client/tunnel disconnect are logged as client disconnects instead of adapter errors.
- Claude-native tool calls such as `Bash` are suppressed before Warp sees them, with upstream instructions to use only request-provided OpenAI-compatible tool names and a text-only fallback retry when native tools are attempted.
- Tunnel URL persistence in `tunnel_url.txt` for service-based Cloudflare Tunnel usage.
- Docker tunnel image disables the adapter healthcheck inherited from the adapter stage, so Compose does not report a healthy cloudflared sidecar as an unhealthy adapter.
- Docker Quick Start Guide and helper scripts for dependency checks, adapter/tunnel startup, status, logs, URL printing, and endpoint testing.
- Public repository assets and GPL-3.0 license.

---
