#!/usr/bin/env bash
# ==============================================================================
# DUSKY TIME - ROFI FRONTEND
# ==============================================================================

set -euo pipefail

# Automatically finds the daemon script in the exact same folder
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON_SCRIPT="$DIR/dusky_time_daemon.sh"

declare -agr ROFI_CMD=(rofi -dmenu -i -no-custom -theme-str 'window {width: 20%;} listview {lines: 5;}')

declare -agr MENU_OPTIONS=(
    '🍅  Pomodoro (25m)'
    '⏳  Custom Timer'
    '⏱️  Stopwatch'
    '🕒  Live Clock'
    '🛑  Stop / Clear'
)

choice=$(printf '%s\n' "${MENU_OPTIONS[@]}" | "${ROFI_CMD[@]}" -p "Time") || exit 0

case "$choice" in
    '🍅  Pomodoro (25m)')
        "$DAEMON_SCRIPT" --pomodoro 1500 &
        ;;
        
    '⏳  Custom Timer')
        mins=$(rofi -dmenu -i -p "Minutes" -theme-str 'window {width: 15%;} listview {lines: 0;}') || exit 0
        if [[ "$mins" =~ ^[0-9]+$ ]] && (( mins > 0 )); then
            secs=$((mins * 60))
            "$DAEMON_SCRIPT" --timer "$secs" &
        else
            notify-send -u low "Invalid time entered."
        fi
        ;;
        
    '⏱️  Stopwatch')
        "$DAEMON_SCRIPT" --stopwatch &
        ;;
        
    '🕒  Live Clock')
        "$DAEMON_SCRIPT" --clock &
        ;;
        
    '🛑  Stop / Clear')
        "$DAEMON_SCRIPT" --stop &
        ;;
esac
