#!/usr/bin/env bash
set -Eeuo pipefail

REPO="firedesiresa-bit/gamepower-heatsync-linux"
BRANCH="main"
DEFAULT_PORT="/dev/serial/by-id/usb-Turing_UsbMonitor_USB35INCHIPSV2-if00"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
INSTALL_DIR="$DATA_HOME/gamepower-heatsync"
BIN_DIR="$HOME/.local/bin"
SERVICE_DIR="$CONFIG_HOME/systemd/user"
SERVICE_NAME="gamepower-heatsync.service"
NO_ACTIVATE=0
PORT="${HEATSYNC_PORT:-$DEFAULT_PORT}"
TEMP_DIR=""

die() {
  printf 'HeatSync installer: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Install the Gamepower HeatSync Linux telemetry service.

Usage: install.sh [--port PATH] [--no-activate] [--help]

  --port PATH     HeatSync serial device (defaults to the USB35INCH by-id path)
  --no-activate   Install files but do not enable/start the systemd user service
  --help          Show this help

The installer uses APT for missing software packages and sudo may ask for your
password. It does not install or change an NVIDIA driver.
EOF
}

install_apt_packages() {
  (($#)) || return 0
  command -v sudo >/dev/null 2>&1 || die "sudo is required to install packages: $*"
  sudo -v || die "could not obtain sudo access to install dependencies"
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends "$@"
}

while (($#)); do
  case "$1" in
    --port)
      (($# >= 2)) || die "--port requires a device path"
      PORT="$2"
      shift 2
      ;;
    --no-activate)
      NO_ACTIVATE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1 (use --help)"
      ;;
  esac
done

[[ $EUID -ne 0 ]] || die "run this as your normal desktop user, not with sudo"
[[ "$PORT" =~ ^/[A-Za-z0-9._/+:-]+$ ]] || die "unsupported serial path syntax: $PORT"

OS_ID=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
fi
[[ "$OS_ID" == "ubuntu" ]] || die "this installer currently supports Ubuntu; detected '${OS_ID:-unknown}'"
command -v apt-get >/dev/null 2>&1 || die "APT is required on Ubuntu"

missing_packages=()
for package in python3 python3-serial lm-sensors ca-certificates; do
  if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
    missing_packages+=("$package")
  fi
done

source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$source_dir/heatsync_linux.py" || ! -f "$source_dir/systemd/gamepower-heatsync.service" ]]; then
  source_dir=""
  if ! command -v curl >/dev/null 2>&1; then
    missing_packages+=(curl)
  fi
  if ! command -v tar >/dev/null 2>&1; then
    missing_packages+=(tar)
  fi
fi

if ((${#missing_packages[@]})); then
  install_apt_packages "${missing_packages[@]}"
fi

if [[ -z "$source_dir" ]]; then
  TEMP_DIR="$(mktemp -d)"
  archive="$TEMP_DIR/source.tar.gz"
  source_dir="$TEMP_DIR/source"
  mkdir -p "$source_dir"
  printf 'Downloading %s (%s branch)...\n' "$REPO" "$BRANCH"
  curl --fail --location --silent --show-error \
    "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" \
    --output "$archive" || die "could not download the project archive"
  tar -xzf "$archive" --strip-components=1 -C "$source_dir" \
    || die "could not unpack the project archive"
fi

[[ -f "$source_dir/heatsync_linux.py" ]] || die "project source is missing heatsync_linux.py"
[[ -f "$source_dir/systemd/gamepower-heatsync.service" ]] || die "project source is missing the systemd service"

python3 -c 'import serial' 2>/dev/null || die "pySerial is unavailable after package installation"
command -v sensors >/dev/null 2>&1 || die "lm-sensors did not provide the sensors command"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  driver_package="$(dpkg-query -W -f='${Package}\n' 'nvidia-driver-*' 2>/dev/null \
    | grep -E '^nvidia-driver-[0-9]+' | sort -V | tail -n1 || true)"
  driver_package="${driver_package%%:*}"
  if [[ "$driver_package" =~ ^nvidia-driver-([0-9]+)(-server)? ]]; then
    utils_package="nvidia-utils-${BASH_REMATCH[1]}${BASH_REMATCH[2]:-}"
    printf 'Installing %s for the already-installed NVIDIA driver...\n' "$utils_package"
    install_apt_packages "$utils_package"
  else
    die "nvidia-smi is missing and no APT-installed NVIDIA driver was found. Install a suitable NVIDIA driver first; this installer will not install or replace GPU drivers."
  fi
fi
command -v nvidia-smi >/dev/null 2>&1 || die "nvidia-smi is still unavailable; check the NVIDIA driver and rerun this installer"

if ! sensors -j 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
raise SystemExit(0 if any("k10temp" in chip.lower() for chip in data) else 1)
'; then
  die "no AMD k10temp sensor found. Confirm this is an AMD CPU and that sensors -j shows k10temp Tctl/Tdie."
fi

if ! nvidia-smi --query-gpu=temperature.gpu,utilization.gpu --format=csv,noheader,nounits >/dev/null 2>&1; then
  die "nvidia-smi cannot read a GPU. Check the NVIDIA driver and rerun the installer."
fi

[[ -e "$PORT" ]] || die "HeatSync serial device not found at '$PORT'. Check /dev/serial/by-id/ or pass --port PATH."
[[ -r "$PORT" && -w "$PORT" ]] || {
  if getent group dialout >/dev/null && ! id -nG | tr ' ' '\n' | grep -qx dialout; then
    printf 'Adding %s to dialout so it can access the USB serial device...\n' "$USER"
    sudo usermod -aG dialout "$USER"
    die "log out and back in to refresh group access, then rerun this installer"
  fi
  die "no read/write access to '$PORT'. Check its permissions and dialout group membership."
}

install -d "$INSTALL_DIR" "$BIN_DIR" "$SERVICE_DIR"
install -m 0755 "$source_dir/heatsync_linux.py" "$INSTALL_DIR/heatsync_linux.py"
ln -sfn "$INSTALL_DIR/heatsync_linux.py" "$BIN_DIR/gamepower-heatsync"
install -m 0644 "$source_dir/systemd/gamepower-heatsync.service" "$SERVICE_DIR/$SERVICE_NAME"

override_dir="$SERVICE_DIR/$SERVICE_NAME.d"
if [[ "$PORT" != "$DEFAULT_PORT" ]]; then
  install -d "$override_dir"
  printf '[Service]\nEnvironment=HEATSYNC_PORT=%s\n' "$PORT" > "$override_dir/port.conf"
else
  if [[ -f "$override_dir/port.conf" ]]; then
    rm -f -- "$override_dir/port.conf"
    rmdir "$override_dir" 2>/dev/null || true
  fi
fi

if ((NO_ACTIVATE)); then
  printf 'Installed to %s. Activate with:\n  systemctl --user daemon-reload\n  systemctl --user enable --now %s\n' "$INSTALL_DIR" "$SERVICE_NAME"
  exit 0
fi

command -v systemctl >/dev/null 2>&1 || die "systemd is required to activate the user service"
systemctl --user daemon-reload || die "could not contact your systemd user manager; log into the desktop session and rerun"
systemctl --user enable "$SERVICE_NAME" || die "could not enable the service"
if systemctl --user is-active --quiet "$SERVICE_NAME"; then
  systemctl --user restart "$SERVICE_NAME" || die "could not restart the service; inspect systemctl --user status $SERVICE_NAME"
else
  systemctl --user start "$SERVICE_NAME" || die "could not start the service; inspect systemctl --user status $SERVICE_NAME"
fi

printf '\nHeatSync live metrics are installed and active.\n'
printf '  Service: systemctl --user status %s\n' "$SERVICE_NAME"
printf '  Logs:    journalctl --user -u %s -f\n' "$SERVICE_NAME"
printf '  Stop:    systemctl --user disable --now %s\n' "$SERVICE_NAME"
