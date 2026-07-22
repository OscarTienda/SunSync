#!/usr/bin/env bash
#
# SunSync — start a KDE virtual monitor for Sunshine streaming.
#
# Runs as a Sunshine prep-cmd "do" command. Creates a krfb virtual monitor
# matching the resolution and frame rate requested by the Moonlight client,
# then powers off the physical displays so they don't waste electricity while
# you stream. The companion stop script restores everything.
#
# Sunshine exports SUNSHINE_CLIENT_WIDTH / _HEIGHT / _FPS into this environment.
# Requires: krfb-virtualmonitor (krfb), kscreen-doctor (libkscreen), qdbus.
#
set -u

# Find the Qt D-Bus utility across distributions.
if command -v qdbus6 >/dev/null 2>&1; then
    QDBUS=qdbus6
elif command -v qdbus >/dev/null 2>&1; then
    QDBUS=qdbus
else
    echo "Error: neither qdbus6 nor qdbus was found." >&2
    exit 1
fi

# --- Wayland / D-Bus session environment (Sunshine's service env is minimal) --
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
export QT_QPA_PLATFORM=wayland

NAME="sunshine-vmon"
VMON="Virtual-${NAME}"

# --- Resolution / fps from the Moonlight client (with sane fallbacks) ---------
WIDTH="${SUNSHINE_CLIENT_WIDTH:-1920}"
HEIGHT="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS:-60}"; FPS="${FPS%.*}"
FPS_MHZ=$(( FPS * 1000 ))
RES="${WIDTH}x${HEIGHT}"

STATE_DIR="${XDG_RUNTIME_DIR}/sunsync-vmon"
mkdir -p "$STATE_DIR"

# krfb-virtualmonitor always opens a network port. Use a random password so the
# virtual monitor isn't trivially reachable from the LAN. The capture path
# (capture=kwin) is local and does not need this password.
PASS="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
PORT=5910

# --- Keep the session awake ---------------------------------------------------
loginctl unlock-session "${XDG_SESSION_ID:-}" 2>/dev/null \
    || loginctl unlock-sessions 2>/dev/null || true
"$QDBUS" org.freedesktop.ScreenSaver /ScreenSaver \
    org.freedesktop.ScreenSaver.Inhibit "Sunshine" "Game streaming" \
    > "$STATE_DIR/ss-cookie" 2>/dev/null || true

# --- Create the virtual monitor ----------------------------------------------
pkill -f krfb-virtualmonitor 2>/dev/null || true
krfb-virtualmonitor --resolution "$RES" --scale 1 --name "$NAME" \
    --password "$PASS" --port "$PORT" &
echo $! > "$STATE_DIR/vmon.pid"

# Wait for KWin to register the new output.
sleep 3

kscreen-doctor "output.${VMON}.addCustomMode.${WIDTH}.${HEIGHT}.${FPS_MHZ}.full" 2>/dev/null || true
kscreen-doctor "output.${VMON}.enable"            2>/dev/null || true
kscreen-doctor "output.${VMON}.mode.${RES}@${FPS}" 2>/dev/null || true
kscreen-doctor "output.${VMON}.priority.1"        2>/dev/null || true

# Let KWin finish reloading its config after the new output.
sleep 4

# --- Power off the physical displays ------------------------------------------
# By default, auto-detect every enabled + connected output (except the virtual
# one) so this works on any machine, not just one with DP-1/DP-2. Two optional
# environment overrides (space- or comma-separated output names):
#   SUNSYNC_VMON_DISABLE_OUTPUTS — disable exactly these, skipping auto-detect
#   SUNSYNC_VMON_KEEP_OUTPUTS    — never disable these (e.g. keep one screen on)
DISABLE_OVERRIDE="${SUNSYNC_VMON_DISABLE_OUTPUTS:-}"
KEEP_OUTPUTS="${SUNSYNC_VMON_KEEP_OUTPUTS:-}"
DISABLE_OVERRIDE="${DISABLE_OVERRIDE//,/ }"
KEEP_OUTPUTS="${KEEP_OUTPUTS//,/ }"

_is_kept() {
    local target="$1" kept
    # shellcheck disable=SC2086
    for kept in $KEEP_OUTPUTS; do
        [ "$kept" = "$target" ] && return 0
    done
    return 1
}

if [ -n "$DISABLE_OVERRIDE" ]; then
    CANDIDATE_OUTPUTS="$DISABLE_OVERRIDE"
else
    CANDIDATE_OUTPUTS="$(
        kscreen-doctor -o 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*m//g' \
            | awk '
                $1=="Output:"   { if (name && en && conn) print name; name=$3; en=0; conn=0; next }
                $1=="enabled"   { en=1 }
                $1=="connected" { conn=1 }
                END             { if (name && en && conn) print name }
            '
    )"
fi

# Record disabled outputs so the stop script can restore exactly these.
: > "$STATE_DIR/disabled-outputs"
# Word-splitting is intentional: output names never contain spaces.
# shellcheck disable=SC2086
for out in $CANDIDATE_OUTPUTS; do
    [ "$out" = "$VMON" ] && continue
    _is_kept "$out" && continue
    echo "$out" >> "$STATE_DIR/disabled-outputs"
    kscreen-doctor "output.${out}.disable" 2>/dev/null || true
done

sleep 0.5
"$QDBUS" org.kde.KWin /KWin org.kde.KWin.minimizeAll 2>/dev/null || true
