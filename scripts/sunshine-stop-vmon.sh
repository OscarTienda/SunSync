#!/usr/bin/env bash
#
# SunSync — stop the KDE virtual monitor and restore physical displays.
#
# Runs as a Sunshine prep-cmd "undo" command when the game exits.
#
set -u

# Find the Qt D-Bus utility across distributions.
QDBUS=""

if command -v qdbus6 >/dev/null 2>&1; then
    QDBUS=qdbus6
elif command -v qdbus >/dev/null 2>&1; then
    QDBUS=qdbus
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
export QT_QPA_PLATFORM=wayland

STATE_DIR="${XDG_RUNTIME_DIR}/sunsync-vmon"

# --- Re-enable the physical outputs we turned off -----------------------------
if [ -f "$STATE_DIR/disabled-outputs" ]; then
    first=""
    while IFS= read -r out; do
        [ -n "$out" ] || continue
        kscreen-doctor "output.${out}.enable" 2>/dev/null || true
        [ -z "$first" ] && first="$out"
    done < "$STATE_DIR/disabled-outputs"
    [ -n "$first" ] && kscreen-doctor "output.${first}.priority.1" 2>/dev/null || true
    rm -f "$STATE_DIR/disabled-outputs"
fi

sleep 1

# --- Tear down the virtual monitor --------------------------------------------
if [ -f "$STATE_DIR/vmon.pid" ]; then
    kill "$(cat "$STATE_DIR/vmon.pid")" 2>/dev/null || true
    rm -f "$STATE_DIR/vmon.pid"
fi
pkill -f krfb-virtualmonitor 2>/dev/null || true

# --- Release the screensaver inhibitor ----------------------------------------
if [ -f "$STATE_DIR/ss-cookie" ]; then
    [ -n "$QDBUS" ] && "$QDBUS" \
        org.freedesktop.ScreenSaver /ScreenSaver \
        org.freedesktop.ScreenSaver.UnInhibit \
        "$(cat "$STATE_DIR/ss-cookie")" 2>/dev/null || true
    rm -f "$STATE_DIR/ss-cookie"
fi
