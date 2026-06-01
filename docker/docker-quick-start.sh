#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMAND="${1:-start}"
PORT="${ADAPTER_HOST_PORT:-8788}"
URL_FILE="${REPO_ROOT}/docker-data/tunnel_url.txt"

if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
  PORT="${2}"
fi

usage() {
  cat <<USAGE
Usage: ./docker/docker-quick-start.sh [command] [port]

Default command:
  start              Build and start adapter + Cloudflare Tunnel in the background.

Commands:
  start              Build and start adapter + tunnel, then print Warp settings.
  adapter            Build and start only the local adapter.
  stop               Stop and remove adapter/tunnel containers for this project.
  restart            Stop, then start adapter + tunnel.
  status             Show Docker Compose service status and current tunnel URL.
  url                Print the current tunnel URL and Warp Base URL.
  logs               Follow Docker Compose logs.
  test               Test local and public health/models endpoints.
  help               Show this help.

Port:
  Defaults to 8788 to avoid conflicts with a non-Docker adapter on 8787.
  You can also set ADAPTER_HOST_PORT, for example:
    ADAPTER_HOST_PORT=8790 ./docker/docker-quick-start.sh start

USAGE
}

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n\n' "$*" >&2
  show_dependency_help >&2
  exit 1
}

show_dependency_help() {
  cat <<'HELP'
What to do next:
  - macOS/Windows: install or start Docker Desktop, then rerun this script.
  - Linux: install Docker Engine and the Compose plugin.

Ubuntu/Debian example:
  sudo apt-get update
  sudo apt-get install -y docker.io docker-compose-v2
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$USER"

After adding yourself to the docker group, sign out and sign in again.
If your Linux distribution uses the Docker upstream packages, the Compose
package may be named docker-compose-plugin instead of docker-compose-v2.
HELP
}

check_dependencies() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker is not installed or is not in PATH."
  fi

  if ! docker info >/dev/null 2>&1; then
    fail "Docker is installed, but the Docker daemon is not reachable. Docker Desktop may not be running, or this user may not have Docker permissions."
  fi

  if ! docker compose version >/dev/null 2>&1; then
    fail "Docker is installed, but the Docker Compose plugin is missing."
  fi
}

warn_if_port_busy() {
  local port="${1}"

  if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
    log "WARNING: port ${port} already appears to be in use."
    log "Use a different port, for example: ADAPTER_HOST_PORT=8790 ./docker/docker-quick-start.sh start"
    log ""
  fi
}

compose() {
  (
    cd "${REPO_ROOT}"
    ADAPTER_HOST_PORT="${PORT}" docker compose "$@"
  )
}

wait_for_tunnel_url() {
  local deadline=$((SECONDS + 90))
  local url=""

  while [[ -z "${url}" && "${SECONDS}" -lt "${deadline}" ]]; do
    if [[ -s "${URL_FILE}" ]]; then
      url="$(tr -d '[:space:]' < "${URL_FILE}")"
    else
      sleep 1
    fi
  done

  printf '%s' "${url}"
}

current_tunnel_url() {
  local url=""

  if [[ -s "${URL_FILE}" ]]; then
    url="$(tr -d '[:space:]' < "${URL_FILE}")"
  fi

  printf '%s' "${url}"
}

print_warp_settings() {
  local url
  url="$(current_tunnel_url)"

  if [[ -n "${url}" ]]; then
    cat <<INFO

Warp settings:
  API type/provider: OpenAI-compatible custom endpoint
  Base URL: ${url}/v1
  API key: your Kie API key
  Custom headers: none
  Recommended model ID: claude-opus-4-8

The tunnel URL is saved in:
  docker-data/tunnel_url.txt

INFO
  else
    cat <<INFO

The adapter is running locally at:
  https://localhost:${PORT}/v1

No Cloudflare Tunnel URL is available yet. If Warp cannot use localhost,
run:
  ./docker/docker-quick-start.sh start

INFO
  fi
}

start_adapter_only() {
  check_dependencies
  warn_if_port_busy "${PORT}"
  log "Building and starting the adapter container on https://localhost:${PORT}/v1 ..."
  compose up --build -d adapter
  log ""
  compose ps
  print_warp_settings
}

start_with_tunnel() {
  check_dependencies
  warn_if_port_busy "${PORT}"
  mkdir -p "${REPO_ROOT}/docker-data"
  rm -f "${URL_FILE}"
  log "Building and starting the adapter + Cloudflare Tunnel containers..."
  compose --profile tunnel up --build -d
  log ""
  compose --profile tunnel ps
  log ""
  log "Waiting for Cloudflare to publish the quick-tunnel URL..."
  local url
  url="$(wait_for_tunnel_url)"

  if [[ -n "${url}" ]]; then
    print_warp_settings
  else
    log "The containers started, but no tunnel URL was written within 90 seconds."
    log "Check logs with:"
    log "  ./docker/docker-quick-start.sh logs"
    exit 1
  fi
}

stop_stack() {
  check_dependencies
  log "Stopping Docker Compose services for this project..."
  compose --profile tunnel down
}

show_status() {
  check_dependencies
  compose --profile tunnel ps
  print_warp_settings
}

show_url() {
  print_warp_settings
}

show_logs() {
  check_dependencies
  compose --profile tunnel logs --tail=120 -f
}

test_endpoint() {
  local label="${1}"
  local url="${2}"
  local curl_args=("${@:3}")

  if command -v curl >/dev/null 2>&1; then
    local status
    status="$(curl "${curl_args[@]}" -o /tmp/warp-kie-docker-test.json -w '%{http_code}' --max-time 30 "${url}" 2>/dev/null || true)"
    log "${label}: ${status}"
    if [[ -s /tmp/warp-kie-docker-test.json ]]; then
      python3 - "${label}" /tmp/warp-kie-docker-test.json <<'PY' 2>/dev/null || true
import json
import pathlib
import sys

label = sys.argv[1]
path = pathlib.Path(sys.argv[2])
data = json.loads(path.read_text(encoding="utf-8"))
if label.endswith("models"):
    models = data.get("data", [])
    has_opus = any(item.get("id") == "claude-opus-4-8" for item in models)
    print(f"{label}: model_count={len(models)}, has_claude_opus_4_8={str(has_opus).lower()}")
PY
    fi
  else
    log "curl is not installed, so endpoint tests were skipped."
  fi
}

test_stack() {
  check_dependencies
  test_endpoint "local health" "https://localhost:${PORT}/v1/healthz" -sk
  test_endpoint "local models" "https://localhost:${PORT}/v1/models" -sk

  local url
  url="$(current_tunnel_url)"
  if [[ -n "${url}" ]]; then
    test_endpoint "public health" "${url}/v1/healthz" -sS
    test_endpoint "public models" "${url}/v1/models" -sS
  else
    log "No public tunnel URL found yet."
  fi
}

case "${COMMAND}" in
  start|tunnel)
    start_with_tunnel
    ;;
  adapter|adapter-only)
    start_adapter_only
    ;;
  stop|down)
    stop_stack
    ;;
  restart)
    stop_stack
    start_with_tunnel
    ;;
  status|ps)
    show_status
    ;;
  url|connection)
    show_url
    ;;
  logs)
    show_logs
    ;;
  test)
    test_stack
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
