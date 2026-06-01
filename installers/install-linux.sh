#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_INSTALL_DIR="${HOME}/.local/share/warp-kie-adapter"
INSTALL_DIR="${INSTALL_DIR:-${DEFAULT_INSTALL_DIR}}"
MODE="${MODE:-}"
COMPONENTS="${COMPONENTS:-}"
YES=0
NO_START=0
PORT="${PORT:-8787}"

usage() {
  cat <<USAGE
Usage: ./installers/install-linux.sh [options]

Options:
  --install-dir PATH       Installation directory. Default: ${DEFAULT_INSTALL_DIR}
  --mode manual|service    Run manually or install systemd user services.
  --components adapter|tunnel|both
                           Components to install as services. Default: both.
  --yes                    Accept defaults and install missing packages when possible.
  --no-start               Register services but do not start them immediately.
  -h, --help               Show this help.
USAGE
}

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --components)
      COMPONENTS="$2"
      shift 2
      ;;
    --yes)
      YES=1
      shift
      ;;
    --no-start)
      NO_START=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
 done

prompt_default() {
  local prompt="$1"
  local default_value="$2"
  local value=""

  if [[ "${YES}" == "1" ]]; then
    printf '%s' "${default_value}"
  else
    read -r -p "${prompt} [${default_value}]: " value
    printf '%s' "${value:-${default_value}}"
  fi
}

if [[ -z "${MODE}" ]]; then
  MODE="$(prompt_default "Usage mode: manual or service" "manual")"
fi
if [[ -z "${COMPONENTS}" ]]; then
  COMPONENTS="$(prompt_default "Components: adapter, tunnel, or both" "both")"
fi
INSTALL_DIR="$(prompt_default "Install directory" "${INSTALL_DIR}")"

case "${MODE}" in
  manual|service) ;;
  *) fail "Mode must be manual or service." ;;
esac
case "${COMPONENTS}" in
  adapter|tunnel|both) ;;
  *) fail "Components must be adapter, tunnel, or both." ;;
esac

contains_component() {
  [[ "${COMPONENTS}" == "both" || "${COMPONENTS}" == "$1" ]]
}

sudo_command() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_packages() {
  local packages=("$@")

  if command -v apt-get >/dev/null 2>&1; then
    sudo_command apt-get update
    sudo_command apt-get install -y "${packages[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    sudo_command dnf install -y "${packages[@]}"
  elif command -v yum >/dev/null 2>&1; then
    sudo_command yum install -y "${packages[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    sudo_command zypper install -y "${packages[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    sudo_command pacman -Sy --needed --noconfirm "${packages[@]}"
  else
    fail "No supported package manager found. Install missing packages manually: ${packages[*]}"
  fi
}

ensure_command() {
  local command_name="$1"
  local package_name="$2"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    if [[ "${YES}" == "1" ]]; then
      log "Installing ${package_name} ..."
      install_packages "${package_name}"
    else
      fail "${command_name} is required. Install ${package_name} or rerun with --yes."
    fi
  fi
}

install_cloudflared_local() {
  local bin_dir="${INSTALL_DIR}/bin"
  local target="${bin_dir}/cloudflared"
  local arch=""
  local url=""

  mkdir -p "${bin_dir}"
  if [[ -x "${target}" ]]; then
    return
  fi

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l) arch="arm" ;;
    *) fail "Unsupported Linux architecture: $(uname -m)" ;;
  esac

  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  log "Downloading cloudflared to ${target} ..."
  curl -fsSL "${url}" -o "${target}"
  chmod +x "${target}"
}

copy_project() {
  mkdir -p "${INSTALL_DIR}"
  cp -R "${SOURCE_DIR}/." "${INSTALL_DIR}/"
  rm -rf \
    "${INSTALL_DIR}/.git" \
    "${INSTALL_DIR}/.github" \
    "${INSTALL_DIR}/certs" \
    "${INSTALL_DIR}/dist" \
    "${INSTALL_DIR}/__pycache__" \
    "${INSTALL_DIR}/adapter.log" \
    "${INSTALL_DIR}/cloudflared.log" \
    "${INSTALL_DIR}/adapter.pid" \
    "${INSTALL_DIR}/cloudflared.pid"
  chmod +x \
    "${INSTALL_DIR}/adapterctl.sh" \
    "${INSTALL_DIR}/start_adapter.sh" \
    "${INSTALL_DIR}/make_https_cert.sh" \
    "${INSTALL_DIR}/scripts/tunnel_service.py"
}

write_adapter_service() {
  local unit_dir="${HOME}/.config/systemd/user"
  mkdir -p "${unit_dir}"
  cat > "${unit_dir}/warp-kie-adapter.service" <<UNIT
[Unit]
Description=Warp Kie.ai HTTPS adapter
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/start_adapter.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
}

write_tunnel_service() {
  local unit_dir="${HOME}/.config/systemd/user"
  local python_bin="$(command -v python3)"
  local cloudflared_bin="${INSTALL_DIR}/bin/cloudflared"
  mkdir -p "${unit_dir}"
  cat > "${unit_dir}/warp-kie-adapter-tunnel.service" <<UNIT
[Unit]
Description=Cloudflare Tunnel for Warp Kie.ai adapter
After=network-online.target warp-kie-adapter.service
Wants=warp-kie-adapter.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${python_bin} ${INSTALL_DIR}/scripts/tunnel_service.py --target https://localhost:${PORT} --log ${INSTALL_DIR}/cloudflared.log --url-file ${INSTALL_DIR}/tunnel_url.txt --cloudflared ${cloudflared_bin}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
}

install_systemd_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    fail "systemctl is required for service mode. Use --mode manual on systems without systemd."
  fi

  if contains_component adapter; then
    write_adapter_service
  fi
  if contains_component tunnel; then
    write_tunnel_service
  fi

  systemctl --user daemon-reload
  if contains_component adapter; then
    systemctl --user enable warp-kie-adapter.service
    if [[ "${NO_START}" != "1" ]]; then
      systemctl --user restart warp-kie-adapter.service
    fi
  fi
  if contains_component tunnel; then
    systemctl --user enable warp-kie-adapter-tunnel.service
    if [[ "${NO_START}" != "1" ]]; then
      systemctl --user restart warp-kie-adapter-tunnel.service
    fi
  fi
}

ensure_command python3 python3
ensure_command openssl openssl
ensure_command curl curl
if contains_component tunnel; then
  install_cloudflared_local
fi
copy_project
ADAPTER_HOSTNAME="$(hostname)" CERT_DIR="${INSTALL_DIR}/certs" "${INSTALL_DIR}/make_https_cert.sh" >/dev/null

if [[ "${MODE}" == "service" ]]; then
  install_systemd_services
fi

cat <<INFO

Installed to: ${INSTALL_DIR}
README: file://${INSTALL_DIR}/README.md
Tunnel URL file: ${INSTALL_DIR}/tunnel_url.txt

INFO

if [[ "${MODE}" == "manual" ]]; then
  cat <<INFO
Manual commands:
  cd "${INSTALL_DIR}"
  ./adapterctl.sh start
  ./adapterctl.sh connection
  ./adapterctl.sh stop
INFO
else
  cat <<INFO
Service mode:
  Status: systemctl --user status warp-kie-adapter.service warp-kie-adapter-tunnel.service
  Connection: ${INSTALL_DIR}/adapterctl.sh connection
  If services should start before login, run: sudo loginctl enable-linger "${USER}"
INFO
fi

cat <<INFO

Warp API key: use your Kie API key. No local Kie key file is required.
INFO
