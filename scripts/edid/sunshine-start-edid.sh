#!/usr/bin/env bash
#
# SunSync — start streaming on an EDID-injected output (DE-agnostic).
#
# Runs as a Sunshine prep-cmd "do" command. Unlike the KDE krfb path, the
# display here already exists: a connector whose EDID was overridden at boot
# (drm.edid_firmware=...) so it reports the resolution you want — typically a
# cheap dummy plug, or a forced headless connector. See scripts/edid/README.md.
#
# This script does NOT create the output. It just makes that output the one
# Sunshine captures: enables it, switches it to the requested mode, makes it
# primary, and powers off the physical displays. The stop script restores them.
#
# Because the connector is fixed at boot, this works the same on KDE (KWin),
# GNOME (Mutter) and wlroots — only the "set the modes" tool differs, which is
# why we detect the compositor below.
#
# Sunshine exports SUNSHINE_CLIENT_WIDTH / _HEIGHT / _FPS into this environment.
# You MUST tell the script which connector carries the injected EDID via
# SUNSYNC_EDID_OUTPUT (e.g. SUNSYNC_EDID_OUTPUT=DP-3). Find it with the helper
# documented in the README. Without it the script exits without touching
# anything, so a misconfigured prep-cmd can never black out your real desktop.
set -u

# --- Wayland / D-Bus session environment (Sunshine's service env is minimal) --
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
export QT_QPA_PLATFORM=wayland

# --- The EDID-injected connector (required, no auto-guess on purpose) ---------
OUT="${SUNSYNC_EDID_OUTPUT:-}"
if [ -z "$OUT" ]; then
    echo "SUNSYNC_EDID_OUTPUT is not set; refusing to touch displays." >&2
    echo "Set it to the connector carrying the injected EDID, e.g. DP-3." >&2
    exit 0
fi

# --- Resolution / fps from the Moonlight client (with sane fallbacks) ---------
WIDTH="${SUNSHINE_CLIENT_WIDTH:-1920}"
HEIGHT="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS%.*}"; FPS="${FPS:-60}"
FPS_MHZ=$(( FPS * 1000 ))
RES="${WIDTH}x${HEIGHT}"

STATE_DIR="${XDG_RUNTIME_DIR}/sunsync-edid"
mkdir -p "$STATE_DIR"

# --- Detect the compositor's display tool -------------------------------------
detect_de() {
    case "${XDG_CURRENT_DESKTOP:-}" in
        *KDE*)   command -v kscreen-doctor >/dev/null 2>&1 && { echo kde;     return; } ;;
        *GNOME*) command -v gdctl          >/dev/null 2>&1 && { echo gnome;   return; }
                 command -v gnome-randr     >/dev/null 2>&1 && { echo gnome-legacy; return; } ;;
    esac
    command -v kscreen-doctor >/dev/null 2>&1 && { echo kde;          return; }
    command -v gdctl          >/dev/null 2>&1 && { echo gnome;        return; }
    command -v gnome-randr    >/dev/null 2>&1 && { echo gnome-legacy; return; }
    command -v wlr-randr      >/dev/null 2>&1 && { echo wlroots;      return; }
    echo unknown
}
DE="$(detect_de)"
echo "$DE" > "$STATE_DIR/de"

# --- Keep the session awake ---------------------------------------------------
loginctl unlock-session "${XDG_SESSION_ID:-}" 2>/dev/null \
    || loginctl unlock-sessions 2>/dev/null || true
if command -v qdbus6 >/dev/null 2>&1; then
    qdbus6 org.freedesktop.ScreenSaver /ScreenSaver \
        org.freedesktop.ScreenSaver.Inhibit "Sunshine" "Game streaming" \
        > "$STATE_DIR/ss-cookie" 2>/dev/null || true
fi

# --- KDE / KWin ---------------------------------------------------------------
start_kde() {
    : > "$STATE_DIR/disabled-outputs"
    kscreen-doctor "output.${OUT}.addCustomMode.${WIDTH}.${HEIGHT}.${FPS_MHZ}.full" 2>/dev/null || true
    kscreen-doctor "output.${OUT}.enable"             2>/dev/null || true
    kscreen-doctor "output.${OUT}.mode.${RES}@${FPS}" 2>/dev/null || true
    kscreen-doctor "output.${OUT}.priority.1"         2>/dev/null || true
    sleep 2
    # Disable every other connected + enabled output, recording them for restore.
    while IFS= read -r o; do
        [ -n "$o" ] || continue
        [ "$o" = "$OUT" ] && continue
        echo "$o" >> "$STATE_DIR/disabled-outputs"
        kscreen-doctor "output.${o}.disable" 2>/dev/null || true
    done < <(
        kscreen-doctor -o 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*m//g' \
            | awk '
                $1=="Output:"   { if (name && en && conn) print name; name=$3; en=0; conn=0; next }
                $1=="enabled"   { en=1 }
                $1=="connected" { conn=1 }
                END             { if (name && en && conn) print name }
            '
    )
    sleep 0.5
    qdbus6 org.kde.KWin /KWin org.kde.KWin.minimizeAll 2>/dev/null || true
}

# --- GNOME / Mutter (gdctl, GNOME 48+). EXPERIMENTAL, untested. ----------------
# gdctl's `set` replaces the whole layout, so naming only the injected monitor
# implicitly disables the rest. We cannot cleanly snapshot the previous layout,
# so the stop script restores by asking Mutter to re-detect (gdctl set --auto-...
# is not available); see README for the manual-restore caveat.
start_gnome() {
    gdctl set --logical-monitor --primary \
        --monitor "$OUT" --mode "${RES}@${FPS}" 2>/dev/null \
        || gdctl set --logical-monitor --primary --monitor "$OUT" 2>/dev/null || true
}

# --- GNOME legacy (gnome-randr). EXPERIMENTAL, untested. ----------------------
start_gnome_legacy() {
    gnome-randr modify "$OUT" --mode "${RES}@${FPS}" --primary 2>/dev/null \
        || gnome-randr modify "$OUT" --primary 2>/dev/null || true
}

# --- wlroots (wlr-randr). EXPERIMENTAL, untested. -----------------------------
start_wlroots() {
    : > "$STATE_DIR/disabled-outputs"
    wlr-randr --output "$OUT" --on --mode "${RES}@${FPS}" 2>/dev/null \
        || wlr-randr --output "$OUT" --on 2>/dev/null || true
    while IFS= read -r o; do
        [ -n "$o" ] || continue
        [ "$o" = "$OUT" ] && continue
        echo "$o" >> "$STATE_DIR/disabled-outputs"
        wlr-randr --output "$o" --off 2>/dev/null || true
    done < <(wlr-randr 2>/dev/null | awk '/^[^ ]/ {print $1}')
}

case "$DE" in
    kde)          start_kde ;;
    gnome)        start_gnome ;;
    gnome-legacy) start_gnome_legacy ;;
    wlroots)      start_wlroots ;;
    *)            echo "No supported display tool found; left displays untouched." >&2 ;;
esac
