#!/usr/bin/env bash

set -e

# ============================================================
# Ubuntu Hyper-V Enhanced Session Installer
#
# Installs:
#   - Hyper-V Linux integration tools
#   - XRDP
#   - XFCE4
#   - Hyper-V socket support
#
# Configures XRDP to use Hyper-V's VSOCK channel.
# ============================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[+]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

error() {
    echo -e "${RED}[x]${NC} $1"
    exit 1
}

# ------------------------------------------------------------
# Check OS
# ------------------------------------------------------------

if [ ! -f /etc/os-release ]; then
    error "Cannot detect operating system."
fi

. /etc/os-release

if [ "${ID:-}" != "ubuntu" ]; then
    warn "This script was designed for Ubuntu."
    warn "Detected: ${PRETTY_NAME:-Unknown}"
fi

# ------------------------------------------------------------
# Check sudo
# ------------------------------------------------------------

if ! command -v sudo >/dev/null 2>&1; then
    error "sudo is required."
fi

info "Ubuntu Hyper-V Enhanced Session setup"
echo

# Request sudo immediately so the user isn't interrupted later.
sudo -v

# ------------------------------------------------------------
# Update packages
# ------------------------------------------------------------

info "Updating package repositories..."

sudo apt update

# ------------------------------------------------------------
# Install Hyper-V tools
# ------------------------------------------------------------

info "Installing Hyper-V integration tools..."

sudo apt install -y \
    linux-tools-virtual \
    linux-cloud-tools-virtual

# ------------------------------------------------------------
# Install XRDP + XFCE
# ------------------------------------------------------------

info "Installing XRDP and XFCE..."

sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    xrdp \
    xfce4 \
    xfce4-goodies

# ------------------------------------------------------------
# Configure XFCE session
# ------------------------------------------------------------

info "Configuring XFCE session..."

echo "xfce4-session" > "$HOME/.xsession"

chmod 644 "$HOME/.xsession"

# ------------------------------------------------------------
# Allow XRDP to access SSL certificates
# ------------------------------------------------------------

info "Adding XRDP to ssl-cert group..."

sudo adduser xrdp ssl-cert || true

# ------------------------------------------------------------
# Backup XRDP config
# ------------------------------------------------------------

XRDP_CONFIG="/etc/xrdp/xrdp.ini"

if [ -f "$XRDP_CONFIG" ]; then
    if [ ! -f "${XRDP_CONFIG}.atlas-backup" ]; then
        info "Creating XRDP configuration backup..."

        sudo cp "$XRDP_CONFIG" "${XRDP_CONFIG}.atlas-backup"
    fi
else
    error "$XRDP_CONFIG was not found."
fi

# ------------------------------------------------------------
# Configure XRDP for Hyper-V VSOCK
# ------------------------------------------------------------

info "Configuring XRDP to use Hyper-V VSOCK..."

sudo sed -i \
    's|^port=3389|port=vsock://-1:3389|' \
    "$XRDP_CONFIG"

sudo sed -i \
    's|^security_layer=.*|security_layer=rdp|' \
    "$XRDP_CONFIG"

sudo sed -i \
    's|^crypt_level=.*|crypt_level=none|' \
    "$XRDP_CONFIG"

sudo sed -i \
    's|^bitmap_compression=.*|bitmap_compression=false|' \
    "$XRDP_CONFIG"

# ------------------------------------------------------------
# Enable Hyper-V socket module
# ------------------------------------------------------------

info "Enabling hv_sock kernel module..."

echo "hv_sock" | sudo tee /etc/modules-load.d/hv_sock.conf >/dev/null

# Try loading it immediately.
sudo modprobe hv_sock 2>/dev/null || true

# ------------------------------------------------------------
# Enable XRDP
# ------------------------------------------------------------

info "Enabling XRDP service..."

sudo systemctl enable xrdp
sudo systemctl restart xrdp

# ------------------------------------------------------------
# Verify
# ------------------------------------------------------------

echo
info "Installation complete!"

echo
echo "XRDP status:"
sudo systemctl --no-pager --full status xrdp 2>/dev/null | head -n 10 || true

echo
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Hyper-V Enhanced Session Ubuntu setup completed${NC}"
echo -e "${GREEN}============================================================${NC}"
echo
echo "Next step:"
echo
echo "  Shut down this VM:"
echo
echo "      sudo shutdown now"
echo
echo "  Then configure Enhanced Session Mode from"
echo "  Windows / Hyper-V."
echo
echo "XRDP backup:"
echo
echo "  /etc/xrdp/xrdp.ini.atlas-backup"
echo
