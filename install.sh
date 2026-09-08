#!/bin/sh
#
# Put the newest Atlas on the desktop, ready to double-click.
#
#     sh -c "$(curl -fsSL https://raw.githubusercontent.com/benborla/atlas-releases/main/install.sh)"
#
# Downloads the latest Linux build, verifies it, and installs it as ~/Desktop/Atlas.
# Re-run it to update; the old copy is replaced.
#
# This file is the copy of record. CI mirrors it to the public releases repo on
# every merge, which is where the URL above serves it from — the source repo is
# private and raw.githubusercontent would 404 for anyone without access.
#
# POSIX sh on purpose. `sh -c` is dash on Debian and Ubuntu, so nothing here may
# depend on bash.

set -eu

# The public releases repo, not the private source. It holds nothing but this
# script and the built binaries, so no credential is ever needed here.
REPO="${ATLAS_REPO:-benborla/atlas-releases}"
ASSET="atlas-linux-x86_64"
NAME="Atlas"

# Overridable so the script can be exercised against a local file:// copy
# without publishing a release first.
BASE_URL="${ATLAS_BASE_URL:-https://github.com/$REPO/releases/latest/download}"

RED=""
GREEN=""
DIM=""
RESET=""

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m')
    DIM=$(printf '\033[2m')
    RESET=$(printf '\033[0m')
fi

say() { printf '%s\n' "$*"; }
step() { printf '  %s\n' "$*"; }
die() { printf '%serror%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- platform

os=$(uname -s)
arch=$(uname -m)

[ "$os" = "Linux" ] || die "this installer is for Linux; uname says $os.
       On macOS grab atlas-macos-arm64 from
       https://github.com/$REPO/releases/latest"

case "$arch" in
    x86_64 | amd64) ;;
    *) die "no build for $arch — only x86_64 is published." ;;
esac

# ------------------------------------------------------------------ tools

if command -v curl >/dev/null 2>&1; then
    fetch() { curl -fSL --progress-bar -o "$1" "$2"; }
    fetch_quiet() { curl -fsSL -o "$1" "$2"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget -q --show-progress -O "$1" "$2"; }
    fetch_quiet() { wget -q -O "$1" "$2"; }
else
    die "need curl or wget to download anything."
fi

# ---------------------------------------------------------------- desktop

# xdg-user-dir knows the localised name — Escritorio, Bureau, Schreibtisch. It
# falls back to printing $HOME when no desktop is configured, which is not a
# desktop, so that answer is refused.
desktop="$HOME/Desktop"

if command -v xdg-user-dir >/dev/null 2>&1; then
    found=$(xdg-user-dir DESKTOP 2>/dev/null || true)

    if [ -n "$found" ] && [ "$found" != "$HOME" ]; then
        desktop="$found"
    fi
fi

mkdir -p "$desktop" || die "cannot create $desktop"

target="$desktop/$NAME"

# ----------------------------------------------------------------- fetch

tmp=$(mktemp -d "${TMPDIR:-/tmp}/atlas.XXXXXX") || die "cannot make a temp dir"
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Atlas"
say "${DIM}from $BASE_URL${RESET}"
say ""

step "downloading $ASSET"

fetch "$tmp/$ASSET" "$BASE_URL/$ASSET" \
    || die "download failed. If the release has not been published yet, see
       https://github.com/$REPO/releases"

# A 404 page saved as the asset would otherwise be chmod +x'd onto the desktop.
magic=$(head -c 4 "$tmp/$ASSET" | od -An -tx1 | tr -d ' \n')

[ "$magic" = "7f454c46" ] \
    || die "that download is not a Linux executable (magic $magic).
       The release asset may be missing or the URL wrong."

# --------------------------------------------------------------- checksum

if fetch_quiet "$tmp/SHA256SUMS" "$BASE_URL/SHA256SUMS" 2>/dev/null \
    && command -v sha256sum >/dev/null 2>&1; then

    step "verifying checksum"

    # Only this asset's line: SHA256SUMS covers files that were not downloaded.
    if ! (cd "$tmp" && grep " $ASSET\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1); then
        die "checksum mismatch — the download is corrupt. Try again."
    fi
else
    step "${DIM}skipping checksum (no SHA256SUMS or sha256sum)${RESET}"
fi

# ---------------------------------------------------------------- install

# Only now that a good binary is in hand: a failed download must not take the
# working copy on the desktop with it.
if [ -e "$target" ] || [ -L "$target" ]; then
    step "replacing the existing $NAME"
    rm -f "$target" || die "cannot remove $target"
fi

step "installing to $target"

mv "$tmp/$ASSET" "$target" || die "cannot write to $desktop"
chmod +x "$target" || die "cannot make $target executable"

# GNOME and KDE refuse to launch a desktop file that is not marked trusted.
# Harmless everywhere else, so it is not worth branching on the desktop
# environment.
if command -v gio >/dev/null 2>&1; then
    gio set "$target" metadata::trusted true >/dev/null 2>&1 || true
fi

say ""
say "${GREEN}Done.${RESET} Atlas is on your desktop."
say ""
say "  Run it:        $target"
say "  Or from here:  ${DIM}\"\$HOME/${target#"$HOME"/}\"${RESET}"
say ""
say "${DIM}Double-clicking may not work in every file manager; running it from${RESET}"
say "${DIM}a terminal always does. Needs a graphical session, and pkexec for${RESET}"
say "${DIM}the privileged write (apt install policykit-1).${RESET}"
