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
Usage: ./installers/install-macos.sh [options]

Options:
  --install-dir PATH       Installation directory. Default: ${DEFAULT_INSTALL_DIR}
  --mode manual|service    Run manually or install launchd user services.
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

ensure_homebrew() {
  if ! command -v brew >/dev/null 2>&1; then
    if [[ "${YES}" == "1" ]]; then
      log "Installing Homebrew because required packages are missing..."
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
    else
      fail "Homebrew is required to install missing packages. Install it from https://brew.sh or rerun with --yes."
    fi
  fi
}

ensure_command() {
  local command_name="$1"
  local brew_package="$2"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    ensure_homebrew
    log "Installing ${brew_package} with Homebrew..."
    brew install "${brew_package}"
  fi
}

install_cloudflared_local() {
  local bin_dir="${INSTALL_DIR}/bin"
  local target="${bin_dir}/cloudflared"
  local arch=""
  local url=""
  local tmp_file=""

  mkdir -p "${bin_dir}"
  if [[ -x "${target}" ]]; then
    return
  fi

  case "$(uname -m)" in
    arm64) arch="arm64" ;;
    x86_64) arch="amd64" ;;
    *) fail "Unsupported macOS architecture: $(uname -m)" ;;
  esac

  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${arch}.tgz"
  tmp_file="$(mktemp)"
  log "Downloading cloudflared to ${target} ..."
  curl -fsSL "${url}" -o "${tmp_file}"
  tar -xzf "${tmp_file}" -C "${bin_dir}" cloudflared
  rm -f "${tmp_file}"
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

write_plist() {
  local label="$1"
  local plist_path="$2"
  local program_xml="$3"
  local stdout_path="$4"
  local stderr_path="$5"

  mkdir -p "$(dirname "${plist_path}")"
  cat > "${plist_path}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
${program_xml}
  </array>
  <key>WorkingDirectory</key>
  <string>${INSTALL_DIR}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key>
  <string>${stdout_path}</string>
  <key>StandardErrorPath</key>
  <string>${stderr_path}</string>
</dict>
</plist>
PLIST
}

load_launch_agent() {
  local plist_path="$1"
  local label="$2"

  launchctl bootout "gui/${UID}" "${plist_path}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${UID}" "${plist_path}"
  launchctl enable "gui/${UID}/${label}" || true
  if [[ "${NO_START}" != "1" ]]; then
    launchctl kickstart -k "gui/${UID}/${label}"
  fi
}

install_adapter_service() {
  local label="dev.warp-kie-adapter.adapter"
  local plist_path="${HOME}/Library/LaunchAgents/${label}.plist"
  local program_xml="    <string>${INSTALL_DIR}/start_adapter.sh</string>"

  write_plist "${label}" "${plist_path}" "${program_xml}" "${INSTALL_DIR}/adapter.out.log" "${INSTALL_DIR}/adapter.err.log"
  load_launch_agent "${plist_path}" "${label}"
}

install_tunnel_service() {
  local label="dev.warp-kie-adapter.tunnel"
  local plist_path="${HOME}/Library/LaunchAgents/${label}.plist"
  local python_bin="$(command -v python3)"
  local cloudflared_bin="${INSTALL_DIR}/bin/cloudflared"
  local program_xml=""

  program_xml="    <string>${python_bin}</string>
    <string>${INSTALL_DIR}/scripts/tunnel_service.py</string>
    <string>--target</string>
    <string>https://localhost:${PORT}</string>
    <string>--log</string>
    <string>${INSTALL_DIR}/cloudflared.log</string>
    <string>--url-file</string>
    <string>${INSTALL_DIR}/tunnel_url.txt</string>
    <string>--cloudflared</string>
    <string>${cloudflared_bin}</string>"
  write_plist "${label}" "${plist_path}" "${program_xml}" "${INSTALL_DIR}/cloudflared.out.log" "${INSTALL_DIR}/cloudflared.err.log"
  load_launch_agent "${plist_path}" "${label}"
}

ensure_command python3 python
ensure_command openssl openssl
ensure_command curl curl
if contains_component tunnel; then
  install_cloudflared_local
fi
copy_project
ADAPTER_HOSTNAME="$(hostname)" CERT_DIR="${INSTALL_DIR}/certs" "${INSTALL_DIR}/make_https_cert.sh" >/dev/null

if [[ "${MODE}" == "service" ]]; then
  if contains_component adapter; then
    install_adapter_service
  fi
  if contains_component tunnel; then
    install_tunnel_service
  fi
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
  Status: ./adapterctl.sh status
  Connection: ./adapterctl.sh connection
  macOS services: ~/Library/LaunchAgents/dev.warp-kie-adapter.*.plist
INFO
fi

cat <<INFO

Warp API key: use your Kie API key. No local Kie key file is required.
INFO
