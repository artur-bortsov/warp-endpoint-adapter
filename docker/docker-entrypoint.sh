#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/app"
MODE="${1:-adapter}"
PORT="${ADAPTER_PORT:-8787}"
HOST="${ADAPTER_BIND_HOST:-0.0.0.0}"
HOSTNAME_FOR_CERT="${ADAPTER_HOSTNAME:-warp-kie-adapter}"
CERT_DIR="${CERT_DIR:-${APP_DIR}/certs}"
CERT_PATH="${ADAPTER_CERT:-${CERT_DIR}/${HOSTNAME_FOR_CERT}.pem}"
KEY_PATH="${ADAPTER_KEY:-${CERT_DIR}/${HOSTNAME_FOR_CERT}-key.pem}"

ensure_certificate() {
  if [[ ! -f "${CERT_PATH}" || ! -f "${KEY_PATH}" ]]; then
    mkdir -p "${CERT_DIR}"
    ADAPTER_HOSTNAME="${HOSTNAME_FOR_CERT}" CERT_DIR="${CERT_DIR}" "${APP_DIR}/make_https_cert.sh" >/dev/null
  fi
}

case "${MODE}" in
  adapter)
    ensure_certificate
    exec python3 "${APP_DIR}/adapter.py" \
      --host "${HOST}" \
      --port "${PORT}" \
      --cert "${CERT_PATH}" \
      --key "${KEY_PATH}"
    ;;
  tunnel)
    mkdir -p /data
    exec python3 "${APP_DIR}/scripts/tunnel_service.py" \
      --target "${TUNNEL_TARGET:-https://adapter:8787}" \
      --log "${TUNNEL_LOG:-/data/cloudflared.log}" \
      --url-file "${TUNNEL_URL_FILE:-/data/tunnel_url.txt}" \
      --cloudflared "${CLOUDFLARED_BIN:-cloudflared}"
    ;;
  shell)
    exec /bin/bash
    ;;
  *)
    exec "$@"
    ;;
esac
