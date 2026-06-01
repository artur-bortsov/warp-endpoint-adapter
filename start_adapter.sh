#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSTNAME_FOR_CERT="${ADAPTER_HOSTNAME:-$(hostname)}"
PORT="${ADAPTER_PORT:-8787}"
CERT_DIR="${CERT_DIR:-${ROOT_DIR}/certs}"
CERT_PATH="${ADAPTER_CERT:-${CERT_DIR}/${HOSTNAME_FOR_CERT}.pem}"
KEY_PATH="${ADAPTER_KEY:-${CERT_DIR}/${HOSTNAME_FOR_CERT}-key.pem}"

if [[ ! -f "${CERT_PATH}" || ! -f "${KEY_PATH}" ]]; then
  echo "Missing HTTPS certificate/key. Run ./make_https_cert.sh first." >&2
  exit 1
fi

exec python3 "${ROOT_DIR}/adapter.py" \
  --host "${ADAPTER_BIND_HOST:-0.0.0.0}" \
  --port "${PORT}" \
  --cert "${CERT_PATH}" \
  --key "${KEY_PATH}"
