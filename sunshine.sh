#!/bin/sh

set -e

# ============================================================
# Ubuntu Sunshine + Tailscale Installer
#
# Installs:
#   - Sunshine (self-hosted game stream host for Moonlight)
#   - Tailscale (and joins your tailnet with an auth key)
#
# Usage:
#   TS_AUTHKEY=tskey-auth-xxxx sh -c "$(curl -fsSL https://.../sunshine.sh)"
#
# Optional environment variables:
#   TS_AUTHKEY      Tailscale auth key (prompted for if not set)
#   DEVICE_NAME     Name shown in Moonlight and Tailscale (prompted for if not set)
#   TS_HOSTNAME     Hostname to register in the tailnet (default: from DEVICE_NAME)
#   SUNSHINE_USER   Sunshine web UI username (default: sunshine)
#   SUNSHINE_PASS   Sunshine web UI password (default: sunshine)
#
# Written in POSIX sh because `sh -c` runs it with dash on Ubuntu.
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() {
    printf "${GREEN}[+]${NC} %s\n" "$1"
}

warn() {
    printf "${YELLOW}[!]${NC} %s\n" "$1"
}

error() {
    printf "${RED}[x]${NC} %s\n" "$1"
    exit 1
}

# ------------------------------------------------------------
# Privileges
# ------------------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    TARGET_USER="${SUDO_USER:-root}"
else
    command -v sudo >/dev/null 2>&1 || error "sudo is required."
    SUDO="sudo"
    TARGET_USER="$(id -un)"
fi

if [ "$TARGET_USER" = "root" ]; then
    warn "Sunshine should run as a normal desktop user, not root."
    warn "Run this script as your user (it will use sudo when needed)."
fi

# ------------------------------------------------------------
# Check OS
# ------------------------------------------------------------

if [ ! -f /etc/os-release ]; then
    error "Cannot detect operating system."
fi

. /etc/os-release

if [ "${ID:-}" != "ubuntu" ]; then
    error "This script supports Ubuntu only. Detected: ${PRETTY_NAME:-Unknown}"
fi

case "$(dpkg --print-architecture)" in
    amd64) ARCH="amd64" ;;
    arm64) ARCH="arm64" ;;
    *) error "Unsupported architecture: $(dpkg --print-architecture)" ;;
esac

info "Detected ${PRETTY_NAME} (${ARCH})"

# ------------------------------------------------------------
# Device name
# ------------------------------------------------------------

DEFAULT_NAME="$(hostname)"
if [ -z "${DEVICE_NAME:-}" ] && [ -t 0 ]; then
    printf "Device name (shown in Moonlight) [%s]: " "$DEFAULT_NAME"
    read -r DEVICE_NAME || true
fi
DEVICE_NAME="${DEVICE_NAME:-$DEFAULT_NAME}"

# Tailscale hostnames must be DNS-safe: lowercase letters, digits, hyphens
if [ -z "${TS_HOSTNAME:-}" ]; then
    TS_HOSTNAME="$(printf '%s' "$DEVICE_NAME" | tr '[:upper:]' '[:lower:]' \
        | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-63)"
fi

info "Device name: ${DEVICE_NAME}"

# ------------------------------------------------------------
# Base packages
# ------------------------------------------------------------

info "Installing base packages..."
$SUDO apt-get update -y
$SUDO apt-get install -y curl ca-certificates jq

# ------------------------------------------------------------
# Sunshine
# ------------------------------------------------------------

info "Looking up latest Sunshine release..."

# Assets look like: sunshine_<version>-1+ubuntu24.04_amd64.deb
ASSET_SUFFIX="+ubuntu${VERSION_ID}_${ARCH}.deb"
RELEASE_JSON="$(curl -fsSL https://api.github.com/repos/LizardByte/Sunshine/releases/latest)"
ASSET_NAME="$(printf '%s' "$RELEASE_JSON" \
    | jq -r --arg sfx "$ASSET_SUFFIX" '.assets[] | select(.name | startswith("sunshine_") and endswith($sfx)) | .name' \
    | head -n1)"
DEB_URL="$(printf '%s' "$RELEASE_JSON" \
    | jq -r --arg name "$ASSET_NAME" '.assets[] | select(.name == $name) | .browser_download_url')"

if [ -z "$ASSET_NAME" ] || [ -z "$DEB_URL" ]; then
    error "No Sunshine package found for Ubuntu ${VERSION_ID} (${ARCH}). Supported: 22.04, 24.04, 26.04, 26.10."
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

info "Downloading ${ASSET_NAME}..."
curl -fL --progress-bar -o "$TMP_DIR/sunshine.deb" "$DEB_URL"

info "Installing Sunshine..."
$SUDO apt-get install -y "$TMP_DIR/sunshine.deb"

# Allow KMS screen capture (needed on Wayland / without X capture)
SUNSHINE_BIN="$(readlink -f "$(command -v sunshine)")"
if [ -n "$SUNSHINE_BIN" ]; then
    info "Granting cap_sys_admin to Sunshine for KMS capture..."
    $SUDO setcap cap_sys_admin+p "$SUNSHINE_BIN" || warn "setcap failed; KMS capture may not work."
fi

# Virtual input devices (keyboard/mouse/gamepad) need uinput
info "Configuring uinput access..."
echo "uinput" | $SUDO tee /etc/modules-load.d/uinput.conf >/dev/null
$SUDO modprobe uinput || warn "Could not load uinput module."
$SUDO usermod -aG input "$TARGET_USER" || true

SUNSHINE_USER="${SUNSHINE_USER:-sunshine}"
SUNSHINE_PASS="${SUNSHINE_PASS:-sunshine}"

if [ -n "$SUNSHINE_USER" ] && [ -n "$SUNSHINE_PASS" ]; then
    info "Setting Sunshine web UI credentials..."
    if [ -n "$SUDO" ]; then
        sunshine --creds "$SUNSHINE_USER" "$SUNSHINE_PASS" >/dev/null 2>&1 || warn "Could not set Sunshine credentials."
    else
        sudo -u "$TARGET_USER" sunshine --creds "$SUNSHINE_USER" "$SUNSHINE_PASS" >/dev/null 2>&1 || warn "Could not set Sunshine credentials."
    fi
fi

# Name the host as it appears in Moonlight
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
SUNSHINE_CONF_DIR="${TARGET_HOME}/.config/sunshine"
SUNSHINE_CONF="${SUNSHINE_CONF_DIR}/sunshine.conf"

info "Setting Sunshine device name..."
$SUDO mkdir -p "$SUNSHINE_CONF_DIR"
$SUDO touch "$SUNSHINE_CONF"
$SUDO sed -i '/^[[:space:]]*sunshine_name[[:space:]]*=/d' "$SUNSHINE_CONF"
printf 'sunshine_name = %s\n' "$DEVICE_NAME" | $SUDO tee -a "$SUNSHINE_CONF" >/dev/null
$SUDO chown -R "$TARGET_USER:" "$SUNSHINE_CONF_DIR"

# CLI helper to approve Moonlight pairing requests without the browser
info "Installing sunshine-pair helper..."
$SUDO tee /usr/local/bin/sunshine-pair >/dev/null <<'EOF'
#!/bin/sh
# Approve a pending Moonlight pairing request from the terminal.
#
# Usage: sunshine-pair [PIN] [CLIENT_NAME]
# Credentials come from SUNSHINE_USER / SUNSHINE_PASS (default: sunshine / sunshine).

set -e

API="${SUNSHINE_API:-https://localhost:47990/api}"
PIN="$1"
NAME="$2"

SUNSHINE_USER="${SUNSHINE_USER:-sunshine}"
SUNSHINE_PASS="${SUNSHINE_PASS:-sunshine}"

api() {
    curl -fsSk -u "$SUNSHINE_USER:$SUNSHINE_PASS" "$@"
}

PENDING="$(api "$API/pin")" || { echo "Could not reach Sunshine API (wrong credentials or not running?)" >&2; exit 1; }
if ! COUNT="$(printf '%s' "$PENDING" | jq -e '.pairings | length' 2>/dev/null)"; then
    echo "Sunshine API returned no data. Sunshine probably has no login set up yet," >&2
    echo "or was started before it was set. Restart Sunshine and try again." >&2
    exit 1
fi

if [ "$COUNT" -eq 0 ]; then
    echo "No pending pairing requests. Click the host in Moonlight first, then rerun." >&2
    exit 1
fi

# Use the newest request; list all when there are several
printf '%s' "$PENDING" | jq -r '.pairings[] | "  pending: \(.name) (\(.address))"'
PAIRING_ID="$(printf '%s' "$PENDING" | jq -r '.pairings[-1].id')"
[ -n "$NAME" ] || NAME="$(printf '%s' "$PENDING" | jq -r '.pairings[-1].name // "Moonlight"')"
[ -n "$NAME" ] || NAME="Moonlight"

if [ -z "$PIN" ]; then
    printf "PIN shown in Moonlight: "
    read -r PIN
fi

BODY="$(jq -nc --arg id "$PAIRING_ID" --arg pin "$PIN" --arg name "$NAME" \
    '{pairing_id: $id, pin: $pin, name: $name}')"
RESULT="$(api -X POST -H "Content-Type: application/json" -d "$BODY" "$API/pin")"

if [ "$(printf '%s' "$RESULT" | jq -r '.status' 2>/dev/null)" = "true" ]; then
    echo "Paired: $NAME"
else
    echo "Pairing failed: $RESULT" >&2
    exit 1
fi
EOF
$SUDO chmod 755 /usr/local/bin/sunshine-pair

info "Starting Sunshine in the background..."
SUNSHINE_LOG="/tmp/sunshine-${TARGET_USER}.log"

# Stop any running instance so it picks up the new credentials and name
if [ -n "$SUDO" ]; then
    systemctl --user stop sunshine 2>/dev/null || true
fi
if pgrep -u "$TARGET_USER" -x sunshine >/dev/null 2>&1; then
    info "Stopping running Sunshine instance..."
    $SUDO pkill -u "$TARGET_USER" -x sunshine || true
    # Shutdown takes a few seconds; wait so the new instance can bind its ports
    i=0
    while pgrep -u "$TARGET_USER" -x sunshine >/dev/null 2>&1 && [ "$i" -lt 15 ]; do
        sleep 1
        i=$((i + 1))
    done
    $SUDO pkill -9 -u "$TARGET_USER" -x sunshine 2>/dev/null || true
fi

if [ -n "$SUDO" ]; then
    # Preferred: systemd user service (also autostarts on login)
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now sunshine 2>/dev/null || true
fi

if [ -n "$SUDO" ] && systemctl --user is-active --quiet sunshine 2>/dev/null; then
    info "Sunshine running as user service (logs: journalctl --user -u sunshine -f)"
else
    # Fallback: detach it from this shell so it survives the script exiting
    if [ -n "$SUDO" ]; then
        setsid nohup sunshine >"$SUNSHINE_LOG" 2>&1 </dev/null &
    else
        sudo -u "$TARGET_USER" -H env DISPLAY="${DISPLAY:-:0}" \
            setsid nohup sunshine >"$SUNSHINE_LOG" 2>&1 </dev/null &
    fi
    sleep 3
    if pgrep -u "$TARGET_USER" -x sunshine >/dev/null 2>&1; then
        info "Sunshine running detached (logs: ${SUNSHINE_LOG})"
    else
        warn "Sunshine did not stay running. Check ${SUNSHINE_LOG}; it needs a logged-in desktop session."
    fi
fi

# ------------------------------------------------------------
# Tailscale
# ------------------------------------------------------------

if command -v tailscale >/dev/null 2>&1; then
    info "Tailscale already installed."
else
    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | $SUDO sh
fi

$SUDO systemctl enable --now tailscaled

if [ -z "${TS_AUTHKEY:-}" ]; then
    if [ -t 0 ]; then
        printf "Enter your Tailscale auth key (tskey-auth-...), or leave blank to log in via browser: "
        stty -echo 2>/dev/null || true
        read -r TS_AUTHKEY || true
        stty echo 2>/dev/null || true
        printf "\n"
    fi
fi

TS_ARGS=""
if [ -n "${TS_HOSTNAME:-}" ]; then
    TS_ARGS="--hostname=${TS_HOSTNAME}"
fi

if [ -n "${TS_AUTHKEY:-}" ]; then
    info "Joining tailnet with auth key..."
    # shellcheck disable=SC2086
    $SUDO tailscale up --authkey="$TS_AUTHKEY" $TS_ARGS
else
    warn "No auth key provided. Open the URL below to log in."
    # shellcheck disable=SC2086
    $SUDO tailscale up $TS_ARGS
fi

# `tailscale up` can skip the hostname on an already-logged-in machine
if [ -n "${TS_HOSTNAME:-}" ]; then
    info "Setting Tailscale device name to ${TS_HOSTNAME}..."
    $SUDO tailscale set --hostname="$TS_HOSTNAME" || warn "Could not set Tailscale device name."
fi

TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"

# ------------------------------------------------------------
# Done
# ------------------------------------------------------------

echo
info "Installation complete."
echo
echo "  Device name:       ${DEVICE_NAME}"
echo "  Sunshine web UI:   https://localhost:47990"
echo "  Username:          ${SUNSHINE_USER}"
echo "  Password:          ${SUNSHINE_PASS}"
if [ -n "$TS_IP" ]; then
    echo "  Tailscale name:    ${TS_HOSTNAME}"
    echo "  Tailscale IP:      ${TS_IP}"
    echo "  Moonlight:         add host ${TS_IP}"
fi
echo "  Pair a client:     sunshine-pair <PIN shown in Moonlight>"
echo
warn "Log out and back in (or reboot) so the 'input' group change takes effect."
