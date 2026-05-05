#!/usr/bin/env bash
# ==============================================================================
# DUSKY TIME DAEMON - LIVE OSD UPDATER (WITH SOUND)
# ==============================================================================

set -euo pipefail

APP_NAME="dusky-time"
SYNC_ID="${APP_NAME}-sync"

# 1. NUCLEAR CLEANUP: Nuke ALL existing instances of this script from orbit
for pid in $(pgrep -f "dusky_time_daemon.sh"); do
    if [[ "$pid" != "$$" && "$pid" != "$BASHPID" ]]; then
        kill -9 "$pid" 2>/dev/null || true
    fi
done

# 2. HELPER: Wipe the notification securely
clear_osd() {
    # Send a blank payload just to clear the Wayland buffer
    notify-send -a "$APP_NAME" -h string:x-canonical-private-synchronous:"$SYNC_ID" -t 1 " " " " 2>/dev/null || true
    # Native command to forcefully delete it from the screen
    makoctl dismiss -a "$APP_NAME" 2>/dev/null || true
}

# 3. If the user just clicked "Stop", clear it and exit
if [[ "${1:-}" == "--stop" ]]; then
    clear_osd
    exit 0
fi

# Ensure it wipes the screen whenever it naturally exits or gets killed
trap 'clear_osd; exit 0' EXIT INT TERM

# --- HELPER: FORMAT SECONDS ---
format_time() {
    local total_sec=$1
    local h=$((total_sec / 3600))
    local m=$(( (total_sec % 3600) / 60 ))
    local s=$((total_sec % 60))
    
    if (( h > 0 )); then
        printf "%02d:%02d:%02d\n" "$h" "$m" "$s"
    else
        printf "%02d:%02d\n" "$m" "$s"
    fi
}

# --- HELPER: FIRE NOTIFICATION ---
send_osd() {
    local icon="$1"
    local text="$2"
    local body="<span font='monospace 20' weight='bold'>${icon}  ${text}</span>"
    
    notify-send -a "$APP_NAME" \
        -h string:x-canonical-private-synchronous:"$SYNC_ID" \
        -t 2000 \
        " " "$body"
}

# --- HELPER: PLAY SOUND ---
play_sound() {
    local sound_file="$1"
    # Smart detection for standard Arch audio players
    if command -v pw-play >/dev/null 2>&1; then
        pw-play "$sound_file" 2>/dev/null &
    elif command -v paplay >/dev/null 2>&1; then
        paplay "$sound_file" 2>/dev/null &
    fi
}

# --- MODES ---
MODE=$1
START_TIME=$(date +%s)

case "$MODE" in
    --clock)
        while true; do
            send_osd "🕒" "$(date +"%I:%M:%S %p")"
            sleep 1
        done
        ;;
        
    --stopwatch)
        while true; do
            elapsed=$(($(date +%s) - START_TIME))
            send_osd "⏱️" "$(format_time $elapsed)"
            sleep 1
        done
        ;;
        
    --timer|--pomodoro)
        DURATION_SEC=$2
        TARGET_TIME=$((START_TIME + DURATION_SEC))
        ICON="⏳"
        [[ "$MODE" == "--pomodoro" ]] && ICON="🍅"
        
        while true; do
            left=$((TARGET_TIME - $(date +%s)))
            
            if (( left <= 0 )); then
                notify-send -u critical -a "dusky-time-alert" "Time's Up!" "Your $ICON timer has finished."
                
                # Play the specific sound based on the mode
                if [[ "$MODE" == "--pomodoro" ]]; then
                    play_sound "/usr/share/sounds/gnome/default/alarms/glass-bell.oga"
                else
                    play_sound "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"
                fi
                
                # Flash the timer at 00:00 for a few seconds concurrently
                for i in {1..5}; do
                    send_osd "🔔" "00:00"
                    sleep 0.5
                    send_osd "  " "00:00"
                    sleep 0.5
                done
                
                clear_osd
                exit 0
            fi
            
            send_osd "$ICON" "$(format_time $left)"
            sleep 1
        done
        ;;
esac
