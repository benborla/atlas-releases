#!/bin/sh
#
# Tune a VM account for Kathana: faster Steam, no Steam self-updates, launch
# options, the game's engine.cfg, display scale, one workspace, dock at the
# bottom.
#
#     sh -c "$(curl -fsSL https://raw.githubusercontent.com/benborla/atlas-releases/main/tune.sh)"
#
# Run it as the account that plays, from a terminal on its desktop (not with
# sudo). Steam is closed first if it's running. Safe to re-run.
#
# Steam must have been started and logged in once in this account, and
# Kathana installed, for the Steam and game parts. Everything else works
# without Steam.
#
# Optional environment variables:
#   KATHANA_LAUNCH_OPTIONS   default: PROTON_USE_WINED3D=1 mesa_glthread=true %command%
#   DISPLAY_SCALE            default: 0.8
#   DOCK_ICON_SIZE           default: 16
#
# POSIX sh on purpose: `sh -c` is dash on Ubuntu.

set -eu

APPID=2081880
REPO="${ATLAS_REPO:-benborla/atlas-releases}"
LAUNCH_OPTIONS="${KATHANA_LAUNCH_OPTIONS:-PROTON_USE_WINED3D=1 mesa_glthread=true %command%}"
SCALE="${DISPLAY_SCALE:-0.8}"
ICON_SIZE="${DOCK_ICON_SIZE:-16}"
# Steam's built-in browser (the whole Steam window) draws with the GPU by
# default. This VM has none (llvmpipe), so GPU mode is the slow path.
STEAM_FLAGS="-cef-disable-gpu -cef-disable-gpu-compositing"

RED="" GREEN="" YELLOW="" DIM="" RESET=""
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED=$(printf '\033[31m') GREEN=$(printf '\033[32m') YELLOW=$(printf '\033[33m')
    DIM=$(printf '\033[2m') RESET=$(printf '\033[0m')
fi
say() { printf '%s\n' "$*"; }
step() { printf '  %s\n' "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
die() { printf '%serror%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
WARNINGS=0

[ "$(id -u)" != 0 ] || die "run this as the account that plays, not as root or with sudo."
command -v python3 >/dev/null 2>&1 || die "python3 is required."
case "$SCALE" in *[!0-9.]* | "" | .* | *.*.*) die "DISPLAY_SCALE must be a number like 0.8, not '$SCALE'." ;; esac
case "$ICON_SIZE" in *[!0-9]* | "") die "DOCK_ICON_SIZE must be a whole number, not '$ICON_SIZE'." ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/atlas-tune.XXXXXX") || die "cannot make a temp dir"
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Atlas VM tuning ${DIM}(Kathana, app $APPID)${RESET}"
say ""

# ------------------------------------------------------------------- steam

STEAM_ROOT=""
for d in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/debian-installation"; do
    if [ -f "$d/steam.sh" ] || [ -d "$d/steamapps" ]; then
        STEAM_ROOT=$(cd "$d" && pwd -P)
        break
    fi
done

steam_running() { pgrep -u "$(id -u)" -x steam >/dev/null 2>&1; }

GAME_DIR=""
if [ -z "$STEAM_ROOT" ]; then
    warn "Steam isn't set up in this account yet: start Steam, log in, install Kathana, then re-run."
else
    say "Steam ${DIM}($STEAM_ROOT)${RESET}"

    # Steam rewrites its config files when it exits, so edits made while it
    # runs are lost.
    if steam_running; then
        step "closing Steam"
        (steam -shutdown >/dev/null 2>&1 &)
        i=0
        while steam_running && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
        steam_running && die "Steam is still running. Quit it (Steam menu > Exit) and re-run."
    fi

    # No "Updating Steam..." on every start. If Valve ever requires a newer
    # client, Steam stops logging in: delete steam.cfg, let it update once,
    # re-run this script.
    if [ -f "$STEAM_ROOT/steam.sh" ]; then
        printf 'BootStrapperInhibitAll=enable\nBootStrapperForceSelfUpdate=disable\n' >"$STEAM_ROOT/steam.cfg"
        step "Steam self-update off ${DIM}(steam.cfg)${RESET}"
    else
        warn "Steam hasn't finished installing itself; self-update left on. Start Steam once, then re-run."
    fi

    # Launch options and game auto-update live in Steam's VDF files.
    cat >"$tmp/steam.py" <<'PY'
import glob, os, sys

root, appid, opts = sys.argv[1:4]
say = lambda m: print("  " + m, file=sys.stderr)
warn = lambda m: print("  ! " + m, file=sys.stderr)


def tokens(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif c in "{}":
            yield c
            i += 1
        elif c == '"':
            i += 1
            buf = []
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    buf.append({"n": "\n", "t": "\t", "\\": "\\", '"': '"'}.get(text[i + 1], "\\" + text[i + 1]))
                    i += 2
                else:
                    buf.append(text[i])
                    i += 1
            i += 1
            yield ("s", "".join(buf))
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in '{}"':
                j += 1
            yield ("s", text[i:j])
            i = j


def parse(path):
    toks = list(tokens(open(path, encoding="utf-8").read()))
    pos = 0

    def block():
        nonlocal pos
        items = []
        while pos < len(toks):
            t = toks[pos]
            if t == "}":
                pos += 1
                return items
            if t == "{":
                raise ValueError("unexpected {")
            pos += 1
            nxt = toks[pos]
            if nxt == "{":
                pos += 1
                items.append([t[1], block()])
            elif nxt == "}":
                raise ValueError("key without value: " + t[1])
            else:
                items.append([t[1], nxt[1]])
                pos += 1
        return items

    return block()


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def dump(items, depth=0):
    ind = "\t" * depth
    out = []
    for k, v in items:
        if isinstance(v, list):
            out.append('%s"%s"\n%s{\n%s%s}\n' % (ind, esc(k), ind, dump(v, depth + 1), ind))
        else:
            out.append('%s"%s"\t\t"%s"\n' % (ind, esc(k), esc(v)))
    return "".join(out)


def save(path, tree):
    if not os.path.exists(path + ".atlas-bak"):
        with open(path, "rb") as a, open(path + ".atlas-bak", "wb") as b:
            b.write(a.read())
    tmp = path + ".atlas-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(dump(tree))
    os.replace(tmp, path)


def child(items, key, create=True):
    for kv in items:
        if kv[0].lower() == key.lower() and isinstance(kv[1], list):
            return kv[1]
    if not create:
        return None
    new = []
    items.append([key, new])
    return new


def get(items, key):
    for k, v in items:
        if k.lower() == key.lower() and not isinstance(v, list):
            return v
    return None


def put(items, key, value):
    for kv in items:
        if kv[0].lower() == key.lower() and not isinstance(kv[1], list):
            kv[1] = value
            return
    items.append([key, value])


# Launch options: per Steam login, in userdata/<id>/config/localconfig.vdf.
done = 0
for cfg in sorted(glob.glob(os.path.join(root, "userdata", "*", "config", "localconfig.vdf"))):
    uid = cfg.split(os.sep)[-3]
    if not uid.isdigit() or uid == "0":
        continue
    try:
        tree = parse(cfg)
        node = child(tree, "UserLocalConfigStore")
        for key in ("Software", "Valve", "Steam", "apps", appid):
            node = child(node, key)
        put(node, "LaunchOptions", opts)
        save(cfg, tree)
        done += 1
    except Exception as e:
        warn("could not update %s: %s" % (cfg, e))
if done:
    say("launch options set (%d Steam login%s): %s" % (done, "" if done == 1 else "s", opts))
else:
    warn("no Steam login found in this account: log in to Steam once, then re-run")

# Find the game in every Steam library; game updates only when launched.
libs = [root]
for lf in (os.path.join(root, "steamapps", "libraryfolders.vdf"), os.path.join(root, "config", "libraryfolders.vdf")):
    if os.path.exists(lf):
        try:
            for _, entry in child(parse(lf), "libraryfolders", create=False) or []:
                if isinstance(entry, list) and get(entry, "path"):
                    libs.append(get(entry, "path"))
        except Exception as e:
            warn("could not read %s: %s" % (lf, e))
seen = set()
game = None
for lib in libs:
    lib = os.path.realpath(lib)
    if lib in seen:
        continue
    seen.add(lib)
    acf = os.path.join(lib, "steamapps", "appmanifest_%s.acf" % appid)
    if not os.path.exists(acf):
        continue
    try:
        tree = parse(acf)
        state = child(tree, "AppState", create=False)
        if state is None:
            raise ValueError("no AppState")
        # 0 = always keep updated, 1 = only when launched.
        put(state, "AutoUpdateBehavior", "1")
        save(acf, tree)
        say("game updates: only when the game is launched")
        installdir = get(state, "installdir")
        if installdir:
            game = os.path.join(lib, "steamapps", "common", installdir)
    except Exception as e:
        warn("could not update %s: %s" % (acf, e))
    break
if game:
    print(game)
PY
    GAME_DIR=$(python3 -I "$tmp/steam.py" "$STEAM_ROOT" "$APPID" "$LAUNCH_OPTIONS") ||
        warn "updating Steam's settings failed (see above)"
    if [ -n "$GAME_DIR" ]; then
        step "Kathana installed at ${DIM}$GAME_DIR${RESET}"
    else
        warn "Kathana isn't installed in this account: install it in Steam, then re-run for engine.cfg."
    fi
fi

# --------------------------------------------------------------- engine.cfg

if [ -n "$GAME_DIR" ] && [ -d "$GAME_DIR" ]; then
    src="$HOME/engine.cfg"
    if [ ! -f "$src" ]; then
        src="$tmp/engine.cfg"
        curl -fsSL -o "$src" "https://raw.githubusercontent.com/$REPO/main/engine.cfg" ||
            die "no ~/engine.cfg, and downloading it failed."
    fi
    # A saved 404 page must not replace the game's config.
    [ "$(head -c 4 "$src")" = "KTCF" ] || die "$src is not a Kathana engine.cfg."
    dest="$GAME_DIR/userdata/engine.cfg"
    mkdir -p "$GAME_DIR/userdata"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        step "engine.cfg already in place"
    else
        [ -f "$dest" ] && cp -p "$dest" "$dest.bak"
        cp "$src" "$dest"
        step "engine.cfg copied to the game ${DIM}(old one: engine.cfg.bak)${RESET}"
    fi
fi

# ---------------------------------------------------------- steam launchers

desktop="$HOME/Desktop"
if command -v xdg-user-dir >/dev/null 2>&1; then
    found=$(xdg-user-dir DESKTOP 2>/dev/null || true)
    [ -n "$found" ] && [ "$found" != "$HOME" ] && desktop="$found"
fi

add_steam_flags() {
    # Insert the flags after the steam command on Exec= lines. Written back
    # in place (cat, not mv) so the file keeps its permissions.
    awk -v f="$STEAM_FLAGS" '
        /^Exec=/ && !/-cef-disable-gpu/ {
            if (match($0, /^Exec=(\/usr\/bin\/|\/usr\/games\/)?steam/) &&
                (length($0) == RLENGTH || substr($0, RLENGTH + 1, 1) == " "))
                $0 = substr($0, 1, RLENGTH) " " f substr($0, RLENGTH + 1)
        }
        { print }' "$1" >"$tmp/launcher" && cat "$tmp/launcher" >"$1"
}
trust() {
    chmod u+x "$1"
    command -v gio >/dev/null 2>&1 && gio set -t string "$1" metadata::trusted true >/dev/null 2>&1 || true
}

say ""
say "Steam window"
launchers=0
for f in "$desktop/steam.desktop" "$desktop/Kathana.desktop"; do
    [ -f "$f" ] || continue
    add_steam_flags "$f"
    trust "$f"
    launchers=$((launchers + 1))
done
# The app grid and dock use the system launcher; a copy in ~/.local wins.
if [ -f /usr/share/applications/steam.desktop ]; then
    mkdir -p "$HOME/.local/share/applications"
    [ -f "$HOME/.local/share/applications/steam.desktop" ] ||
        cp /usr/share/applications/steam.desktop "$HOME/.local/share/applications/steam.desktop"
    add_steam_flags "$HOME/.local/share/applications/steam.desktop"
    launchers=$((launchers + 1))
fi
if [ "$launchers" -gt 0 ]; then
    step "GPU drawing off in the Steam window ${DIM}($launchers launcher(s))${RESET}"
else
    warn "no Steam launcher found to update"
fi

# ----------------------------------------------------------------- display

say ""
say "Display"
mon="$HOME/.config/monitors.xml"
if [ ! -f "$mon" ] && [ -f /etc/skel/.config/monitors.xml ]; then
    mkdir -p "$HOME/.config"
    cp /etc/skel/.config/monitors.xml "$mon"
    step "monitors.xml copied from the new-account template"
fi
if [ -f "$mon" ]; then
    r=$(python3 -I - "$mon" "$SCALE" <<'PY'
import shutil, sys
import xml.etree.ElementTree as ET

path, scale = sys.argv[1:3]
tree = ET.parse(path)
found = changed = 0
for lm in tree.getroot().iter("logicalmonitor"):
    found += 1
    s = lm.find("scale")
    if s is None:
        s = ET.Element("scale")
        kids = list(lm)
        lm.insert(next((i + 1 for i, c in enumerate(kids) if c.tag == "y"), 0), s)
    if (s.text or "").strip() != scale:
        s.text = scale
        changed += 1
if found and changed:
    shutil.copy2(path, path + ".bak")
    ET.indent(tree, space="  ")
    tree.write(path, encoding="unicode")
print("none" if not found else changed)
PY
    ) || r=error
    case "$r" in
        0) step "scale already $SCALE" ;;
        none) warn "monitors.xml has no monitor in it; set the scale once in Settings > Displays, then re-run" ;;
        error) warn "could not read $mon" ;;
        *) step "scale set to $SCALE ${DIM}(applies at next login)${RESET}" ;;
    esac
else
    warn "no ~/.config/monitors.xml: change any setting once in Settings > Displays (Apply, Keep), then re-run"
fi

# ----------------------------------------------------------------- desktop

say ""
say "Desktop"
# gsettings needs the desktop session's bus; find it when run over a console.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
fi

gset() { # SCHEMA KEY VALUE LABEL
    if ! command -v gsettings >/dev/null 2>&1 || [ "$(gsettings writable "$1" "$2" 2>/dev/null)" != true ]; then
        warn "$4: setting not available ($1 $2)"
        return 0
    fi
    if gsettings set "$1" "$2" "$3" 2>/dev/null; then
        step "$4"
    else
        warn "$4: failed (run this from a terminal on the desktop)"
    fi
}

gset org.gnome.mutter dynamic-workspaces false "workspaces: fixed number"
gset org.gnome.desktop.wm.preferences num-workspaces 1 "workspaces: 1"
gset org.gnome.shell.extensions.dash-to-dock dock-position "'BOTTOM'" "dock at the bottom"
gset org.gnome.shell.extensions.dash-to-dock dash-max-icon-size "$ICON_SIZE" "dock icon size $ICON_SIZE"
# Animations cost CPU time when the CPU also draws the screen.
gset org.gnome.desktop.interface enable-animations false "animations off"

# ------------------------------------------------------------------- done

say ""
if [ "$WARNINGS" -gt 0 ]; then
    say "${YELLOW}Done, with $WARNINGS warning(s) above.${RESET}"
else
    say "${GREEN}Done.${RESET}"
fi
say "Log out and back in for the display scale. Then start Steam."
say "${DIM}Steam's own setting still worth turning off by hand once:${RESET}"
say "${DIM}  Steam > Settings > Downloads > Shader Pre-caching${RESET}"
