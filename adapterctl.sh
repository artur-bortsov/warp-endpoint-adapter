#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME_FOR_CERT="${ADAPTER_HOSTNAME:-$(hostname)}"
PORT="${ADAPTER_PORT:-8787}"
CERT_DIR="${CERT_DIR:-${ROOT_DIR}/certs}"
CERT_PATH="${ADAPTER_CERT:-${CERT_DIR}/${HOSTNAME_FOR_CERT}.pem}"
KEY_PATH="${ADAPTER_KEY:-${CERT_DIR}/${HOSTNAME_FOR_CERT}-key.pem}"
ADAPTER_PID_FILE="${ADAPTER_PID_FILE:-${ROOT_DIR}/adapter.pid}"
CLOUDFLARED_PID_FILE="${CLOUDFLARED_PID_FILE:-${ROOT_DIR}/cloudflared.pid}"
ADAPTER_LOG="${ADAPTER_LOG:-${ROOT_DIR}/adapter.log}"
CLOUDFLARED_LOG="${CLOUDFLARED_LOG:-${ROOT_DIR}/cloudflared.log}"
TUNNEL_URL_FILE="${TUNNEL_URL_FILE:-${ROOT_DIR}/tunnel_url.txt}"
if [[ -z "${CLOUDFLARED_BIN:-}" && -x "${ROOT_DIR}/bin/cloudflared" ]]; then
  CLOUDFLARED_BIN="${ROOT_DIR}/bin/cloudflared"
else
  CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-cloudflared}"
fi
ADAPTER_START_TIMEOUT="${ADAPTER_START_TIMEOUT:-30}"
TUNNEL_START_TIMEOUT="${TUNNEL_START_TIMEOUT:-60}"

usage() {
  cat <<USAGE
Usage: ./adapterctl.sh [command]

Default command:
  start              Start the adapter and Cloudflare tunnel.

Common commands:
  start              Start adapter + tunnel and print Warp connection info.
  stop               Stop tunnel + adapter.
  restart            Restart adapter + tunnel.
  status             Show process status and the current tunnel URL.
  connection         Print Warp connection info.
  models             Show model IDs accepted by this adapter.

Separate controls:
  start-adapter      Start only the local HTTPS adapter.
  stop-adapter       Stop only the local HTTPS adapter.
  restart-adapter    Restart only the local HTTPS adapter.
  start-tunnel       Start only the Cloudflare tunnel.
  stop-tunnel        Stop only the Cloudflare tunnel.
  restart-tunnel     Restart only the Cloudflare tunnel.

Log files:
  Adapter:           ${ADAPTER_LOG}
  Cloudflare tunnel: ${CLOUDFLARED_LOG}
  Tunnel URL:        ${TUNNEL_URL_FILE}
USAGE
}

print_models() {
  python3 - "${ROOT_DIR}/adapter.py" <<'PY'
import importlib.util
import pathlib
import sys

adapter_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("warp_kie_adapter", adapter_path)
if spec is None or spec.loader is None:
    raise SystemExit("Unable to load adapter.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

print("Model IDs accepted by this adapter:")
for model in module.openai_model_catalog():
    print("  " + model["id"])
print()
print("No API key is required for this list. Warp still sends your Kie API key as the bearer token for chat requests.")
PY
}

log() {
  printf '%s\n' "$*" >&2
}

read_pid_file() {
  local pid_file="${1}"
  local pid=""

  if [[ -f "${pid_file}" ]]; then
    pid="$(tr -d '[:space:]' < "${pid_file}")"
  fi

  printf '%s' "${pid}"
}

is_pid_running() {
  local pid="${1:-}"
  local running=1

  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    running=0
  fi

  return "${running}"
}

is_pid_file_running() {
  local pid_file="${1}"
  local pid

  pid="$(read_pid_file "${pid_file}")"
  is_pid_running "${pid}"
}

is_systemd_user_service_active() {
  local service_name="${1}"
  local active=1

  if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet "${service_name}" 2>/dev/null; then
    active=0
  fi

  return "${active}"
}


ensure_certificate() {
  if [[ ! -f "${CERT_PATH}" || ! -f "${KEY_PATH}" ]]; then
    log "Generating local HTTPS certificate for Cloudflare origin access..."
    ADAPTER_HOSTNAME="${HOSTNAME_FOR_CERT}" CERT_DIR="${CERT_DIR}" "${ROOT_DIR}/make_https_cert.sh" >/dev/null
  fi
}

check_prerequisites() {
  ensure_certificate
}

adapter_health_check() {
  python3 - "https://localhost:${PORT}/v1/healthz" <<'PY'
import ssl
import sys
import urllib.request

request = urllib.request.Request(sys.argv[1])
context = ssl._create_unverified_context()
with urllib.request.urlopen(request, context=context, timeout=5) as response:
    response.read()
    raise SystemExit(0 if response.status == 200 else 1)
PY
}

wait_for_adapter() {
  local deadline=$((SECONDS + ADAPTER_START_TIMEOUT))
  local ready=1

  while (( SECONDS < deadline )); do
    if adapter_health_check >/dev/null 2>&1; then
      ready=0
      break
    fi
    sleep 1
  done

  return "${ready}"
}

latest_tunnel_url() {
  python3 - "${CLOUDFLARED_LOG}" "${TUNNEL_URL_FILE}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
url_path = pathlib.Path(sys.argv[2])
latest = ""
if path.exists():
    for match in re.findall(r"https://[-a-z0-9]+\.trycloudflare\.com", path.read_text(errors="replace")):
        latest = match
if not latest and url_path.exists():
    latest = url_path.read_text(errors="replace").strip()
print(latest)
PY
}

save_tunnel_url() {
  local tunnel_url="${1}"

  if [[ -n "${tunnel_url}" ]]; then
    printf '%s\n' "${tunnel_url}" > "${TUNNEL_URL_FILE}"
  fi
}

wait_for_tunnel_url() {
  local deadline=$((SECONDS + TUNNEL_START_TIMEOUT))
  local tunnel_url=""
  local ready=1

  while (( SECONDS < deadline )); do
    tunnel_url="$(latest_tunnel_url)"
    if [[ -n "${tunnel_url}" ]]; then
      ready=0
      break
    fi
    sleep 1
  done

  return "${ready}"
}

start_adapter() {
  local pid

  pid="$(read_pid_file "${ADAPTER_PID_FILE}")"
  if is_pid_running "${pid}"; then
    log "Adapter is already running on port ${PORT} (PID ${pid})."
  else
    check_prerequisites
    mkdir -p "$(dirname "${ADAPTER_LOG}")"
    log "Starting adapter on https://localhost:${PORT} ..."
    (
      cd "${ROOT_DIR}"
      nohup env \
        ADAPTER_HOSTNAME="${HOSTNAME_FOR_CERT}" \
        ADAPTER_PORT="${PORT}" \
        ADAPTER_CERT="${CERT_PATH}" \
        ADAPTER_KEY="${KEY_PATH}" \
        "${ROOT_DIR}/start_adapter.sh" >> "${ADAPTER_LOG}" 2>&1 &
      printf '%s' "$!" > "${ADAPTER_PID_FILE}"
    )
    if wait_for_adapter; then
      log "Adapter started."
    else
      log "Adapter did not become healthy within ${ADAPTER_START_TIMEOUT}s. Check ${ADAPTER_LOG}."
      rm -f "${ADAPTER_PID_FILE}"
      exit 1
    fi
  fi
}

stop_pid_file() {
  local label="${1}"
  local pid_file="${2}"
  local pid
  local deadline

  pid="$(read_pid_file "${pid_file}")"
  if is_pid_running "${pid}"; then
    log "Stopping ${label} (PID ${pid}) ..."
    kill "${pid}" 2>/dev/null || true
    deadline=$((SECONDS + 20))
    while (( SECONDS < deadline )); do
      if ! is_pid_running "${pid}"; then
        break
      fi
      sleep 1
    done
    if is_pid_running "${pid}"; then
      log "${label} did not exit after SIGTERM; forcing stop."
      kill -KILL "${pid}" 2>/dev/null || true
    fi
  else
    log "${label} is not running."
  fi

  rm -f "${pid_file}"
}

stop_adapter() {
  stop_pid_file "adapter" "${ADAPTER_PID_FILE}"
}

start_tunnel() {
  local pid
  local tunnel_url

  pid="$(read_pid_file "${CLOUDFLARED_PID_FILE}")"
  if is_pid_running "${pid}"; then
    tunnel_url="$(latest_tunnel_url)"
    log "Cloudflare tunnel is already running (PID ${pid})."
    if [[ -n "${tunnel_url}" ]]; then
      log "Tunnel URL: ${tunnel_url}"
    fi
  else
    if ! command -v "${CLOUDFLARED_BIN}" >/dev/null 2>&1; then
      log "cloudflared is not installed or not in PATH. Set CLOUDFLARED_BIN to a cloudflared executable if it is bundled locally."
      exit 1
    fi
    if ! is_pid_file_running "${ADAPTER_PID_FILE}"; then
      log "Adapter is not running. The tunnel can start, but Warp requests will fail until the adapter is up."
    fi
    mkdir -p "$(dirname "${CLOUDFLARED_LOG}")"
    : > "${CLOUDFLARED_LOG}"
    log "Starting Cloudflare tunnel to https://localhost:${PORT} ..."
    nohup "${CLOUDFLARED_BIN}" tunnel --url "https://localhost:${PORT}" --no-tls-verify > "${CLOUDFLARED_LOG}" 2>&1 &
    printf '%s' "$!" > "${CLOUDFLARED_PID_FILE}"
    if wait_for_tunnel_url; then
      tunnel_url="$(latest_tunnel_url)"
      save_tunnel_url "${tunnel_url}"
      log "Cloudflare tunnel started: ${tunnel_url}"
    else
      log "Cloudflare tunnel did not publish a URL within ${TUNNEL_START_TIMEOUT}s. Check ${CLOUDFLARED_LOG}."
      exit 1
    fi
  fi
}

stop_tunnel() {
  stop_pid_file "Cloudflare tunnel" "${CLOUDFLARED_PID_FILE}"
}

print_status() {
  local adapter_pid
  local tunnel_pid
  local tunnel_url

  adapter_pid="$(read_pid_file "${ADAPTER_PID_FILE}")"
  tunnel_pid="$(read_pid_file "${CLOUDFLARED_PID_FILE}")"
  tunnel_url="$(latest_tunnel_url)"

  if is_pid_running "${adapter_pid}"; then
    printf 'Adapter: running (PID %s, https://localhost:%s)\n' "${adapter_pid}" "${PORT}"
  elif is_systemd_user_service_active "warp-kie-adapter.service"; then
    printf 'Adapter: running (systemd user service, https://localhost:%s)\n' "${PORT}"
  else
    printf 'Adapter: stopped\n'
  fi

  if is_pid_running "${tunnel_pid}"; then
    printf 'Cloudflare tunnel: running (PID %s)\n' "${tunnel_pid}"
  elif is_systemd_user_service_active "warp-kie-adapter-tunnel.service"; then
    printf 'Cloudflare tunnel: running (systemd user service)\n'
  else
    printf 'Cloudflare tunnel: stopped\n'
  fi

  if [[ -n "${tunnel_url}" ]]; then
    printf 'Tunnel URL: %s\n' "${tunnel_url}"
    printf 'Tunnel URL file: %s\n' "${TUNNEL_URL_FILE}"
    printf 'Warp Base URL: %s/v1\n' "${tunnel_url}"
  fi
}

print_connection_info() {
  local tunnel_url
  local base_url

  tunnel_url="$(latest_tunnel_url)"
  if [[ -n "${tunnel_url}" ]]; then
    base_url="${tunnel_url}/v1"
  else
    base_url="https://<start-the-tunnel-first>/v1"
  fi

  cat <<INFO
Warp connection:
  API type/provider: OpenAI-compatible custom endpoint
  Base URL: ${base_url}
  API key: your Kie API key
  Custom headers: none

Recommended model IDs:
  claude-opus-4-8
  claude-opus-4-7
  claude-opus-4-6
  claude-sonnet-4-6
  claude-opus-4-5
  claude-sonnet-4-5
  claude-haiku-4-5

Warp model IDs accepted for compatibility:
  claude-4-7-opus-xhigh, claude-4-7-opus-high, claude-4-7-opus-max
  claude-4-6-opus-high, claude-4-6-opus-max
  claude-4-6-sonnet-high, claude-4-6-sonnet-max
  claude-4-5-opus, claude-4-5-opus-thinking
  claude-4-5-sonnet, claude-4-5-sonnet-thinking
  claude-4-5-haiku

Notes:
  The adapter forwards Warp's Authorization bearer token to Kie; no local Kie key file is required.
  If the tunnel runs as a service, the current tunnel URL is saved to ${TUNNEL_URL_FILE}.
  Leave Warp credit fallback disabled if you want failures to stay visible on this Kie endpoint.
  Logs are written to ${ADAPTER_LOG} and ${CLOUDFLARED_LOG}.
INFO
}

start_all() {
  start_adapter
  start_tunnel
  print_connection_info
}

stop_all() {
  stop_tunnel
  stop_adapter
}

command="${1:-start}"

case "${command}" in
  start|start-all)
    start_all
    ;;
  stop|stop-all)
    stop_all
    ;;
  restart|restart-all)
    stop_all
    start_all
    ;;
  status)
    print_status
    ;;
  connection|info)
    print_connection_info
    ;;
  models|list-models)
    print_models
    ;;
  start-adapter)
    start_adapter
    ;;
  stop-adapter)
    stop_adapter
    ;;
  restart-adapter)
    stop_adapter
    start_adapter
    ;;
  start-tunnel)
    start_tunnel
    print_connection_info
    ;;
  stop-tunnel)
    stop_tunnel
    ;;
  restart-tunnel)
    stop_tunnel
    start_tunnel
    print_connection_info
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
