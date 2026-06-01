#!/usr/bin/env bash
set -euo pipefail

HOSTNAME_FOR_CERT="${ADAPTER_HOSTNAME:-$(hostname)}"
CERT_DIR="${CERT_DIR:-certs}"
CERT_PATH="${CERT_DIR}/${HOSTNAME_FOR_CERT}.pem"
KEY_PATH="${CERT_DIR}/${HOSTNAME_FOR_CERT}-key.pem"

mkdir -p "${CERT_DIR}"

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -sha256 \
  -days 825 \
  -nodes \
  -keyout "${KEY_PATH}" \
  -out "${CERT_PATH}" \
  -subj "/CN=${HOSTNAME_FOR_CERT}" \
  -addext "subjectAltName=DNS:${HOSTNAME_FOR_CERT}"

chmod 600 "${KEY_PATH}"

if [[ "${TRUST_CERT:-0}" == "1" ]]; then
  security add-trusted-cert \
    -d \
    -r trustRoot \
    -k "${HOME}/Library/Keychains/login.keychain-db" \
    "${CERT_PATH}"
fi

cat <<INFO
Created:
  Certificate: ${CERT_PATH}
  Private key: ${KEY_PATH}

Host URL:
  https://${HOSTNAME_FOR_CERT}:8787/v1

If Warp rejects the certificate, rerun with:
  TRUST_CERT=1 ./make_https_cert.sh
INFO
