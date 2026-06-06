#!/usr/bin/env bash
#
# SunSync — stop streaming on an EDID-injected output and restore displays.
#
# Runs as a Sunshine prep-cmd "undo" command when the game exits. Mirrors
# sunshine-start-edid.sh: re-enables the physical outputs it turned off and
# drops the injected output back out of the way. The EDID injection itself is
# a boot-time setting and is never touched here.
set -u

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
export QT_QPA_PLATFORM=wayland

OUT="${SUNSYNC_EDID_OUTPUT:-}"
STATE_DIR="${XDG_RUNTIME_DIR}/sunsync-edid"
DE="$(cat "$STATE_DIR/de" 2>/dev/null || echo unknown)"

# --- KDE / KWin ---------------------------------------------------------------
stop_kde() {
    if [ -f "$STATE_DIR/disabled-outputs" ]; then
        first=""
        while IFS= read -r o; do
            [ -n "$o" ] || continue
            kscreen-doctor "output.${o}.enable" 2>/dev/null || true
            [ -z "$first" ] && first="$o"
        done < "$STATE_DIR/disabled-outputs"
        [ -n "$first" ] && kscreen-doctor "output.${first}.priority.1" 2>/dev/null || true
        rm -f "$STATE_DIR/disabled-outputs"
    fi
    sleep 1
    [ -n "$OUT" ] && kscreen-doctor "output.${OUT}.disable" 2>/dev/null || true
}

# --- GNOME / Mutter. EXPERIMENTAL — see README restore caveat. ----------------
# Mutter has no "restore previous layout" call. The most reliable recovery is
# to let the desktop re-apply its saved configuration; unplugging/replugging or
# toggling a physical output in Settings forces this. We make a best effort by
# disabling the injected monitor, which makes Mutter fall back to the physical
# ones, then nudge it to re-detect.
stop_gnome() {
    # Re-apply with no logical-monitor for the injected output: name the first
    # other connected monitor as primary so Mutter brings the desk back.
    other="$(gdctl show 2>/dev/null \
        | awk '/Monitor / {gsub(/[:]/,"",$2); if ($2 != "'"$OUT"'") {print $2; exit}}')"
    if [ -n "$other" ]; then
        gdctl set --logical-monitor --primary --monitor "$other" 2>/dev/null || true
    fi
}

stop_gnome_legacy() {
    other="$(gnome-randr 2>/dev/null | awk '/^[^ ]/ {if ($1 != "'"$OUT"'") {print $1; exit}}')"
    [ -n "$other" ] && gnome-randr modify "$other" --primary 2>/dev/null || true
}

# --- wlroots ------------------------------------------------------------------
stop_wlroots() {
    if [ -f "$STATE_DIR/disabled-outputs" ]; then
        while IFS= read -r o; do
            [ -n "$o" ] || continue
            wlr-randr --output "$o" --on 2>/dev/null || true
        done < "$STATE_DIR/disabled-outputs"
        rm -f "$STATE_DIR/disabled-outputs"
    fi
    [ -n "$OUT" ] && wlr-randr --output "$OUT" --off 2>/dev/null || true
}

case "$DE" in
    kde)          stop_kde ;;
    gnome)        stop_gnome ;;
    gnome-legacy) stop_gnome_legacy ;;
    wlroots)      stop_wlroots ;;
esac

# --- Release the screensaver inhibitor ----------------------------------------
if [ -f "$STATE_DIR/ss-cookie" ] && command -v qdbus6 >/dev/null 2>&1; then
    qdbus6 org.freedesktop.ScreenSaver /ScreenSaver \
        org.freedesktop.ScreenSaver.UnInhibit "$(cat "$STATE_DIR/ss-cookie")" 2>/dev/null || true
    rm -f "$STATE_DIR/ss-cookie"
fi
