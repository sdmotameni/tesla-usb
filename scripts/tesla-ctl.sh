#!/usr/bin/env bash
###############################################################################
# Tesla USB Control - Simple API for managing the archiver
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }
error() { echo -e "${RED}$*${NC}"; }

# Load config
CONFIG_FILE="${CONFIG_FILE:-/etc/tesla-usb/tesla-usb.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
: "${WIFI_DISABLE_AFTER:=300}"
: "${ARCHIVE_DIR:=/mnt/tesla_archive}"

###############################################################################
# Commands
###############################################################################

cmd_status() {
    echo "Tesla USB Archiver - Status"
    echo "================================"
    
    # System uptime
    UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
    UPTIME_MIN=$((UPTIME_SEC / 60))
    echo "System uptime: ${UPTIME_MIN} minutes"
    
    # WiFi status
    if rfkill list wifi | grep -q "Soft blocked: yes" 2>/dev/null; then
        error "WiFi: DISABLED (LED OFF)"
    else
        info "WiFi: ENABLED (LED ON)"
        REMAINING=$((WIFI_DISABLE_AFTER - UPTIME_SEC))
        if [[ $REMAINING -gt 0 ]]; then
            info "  Auto-disable in: $((REMAINING / 60)) min $((REMAINING % 60)) sec"
        fi
    fi
    
    # Archive space
    if mountpoint -q "$ARCHIVE_DIR" 2>/dev/null; then
        echo
        echo "Archive Storage:"
        df -h "$ARCHIVE_DIR" | tail -1 | awk '{print "  Total: "$2"\n  Used:  "$3" ("$5")\n  Free:  "$4}'
        
        # File count
        FILE_COUNT=$(find "$ARCHIVE_DIR/TeslaCam" -type f -name '*.mp4' 2>/dev/null | wc -l)
        echo "  Files: $FILE_COUNT videos"
        
        # Oldest file
        OLDEST=$(find "$ARCHIVE_DIR/TeslaCam" -type f -name '*.mp4' -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | cut -d' ' -f2-)
        if [[ -n "$OLDEST" ]]; then
            OLDEST_DATE=$(stat -c %y "$OLDEST" | cut -d' ' -f1)
            echo "  Oldest: $OLDEST_DATE"
        fi
    else
        warn "Archive not mounted at $ARCHIVE_DIR"
    fi
    
    # Service status
    echo
    echo "Archiver Service:"
    if systemctl is-active --quiet teslacam-archive.timer; then
        info "  Timer: ACTIVE (runs every 15 min)"
        LAST_RUN=$(systemctl show teslacam-archive.service -p ActiveEnterTimestamp --value)
        [[ -n "$LAST_RUN" ]] && echo "  Last run: $LAST_RUN"
    else
        error "  Timer: INACTIVE"
    fi
}

cmd_wifi_enable() {
    info "Enabling WiFi..."
    sudo rfkill unblock wifi
    
    # Set LED on
    if [[ -d /sys/class/leds/PWR ]]; then
        echo default-on | sudo tee /sys/class/leds/PWR/trigger >/dev/null
    elif [[ -d /sys/class/leds/led1 ]]; then
        echo default-on | sudo tee /sys/class/leds/led1/trigger >/dev/null
    fi
    
    info "WiFi enabled (LED ON)"
    warn "Note: Will auto-disable after $((WIFI_DISABLE_AFTER / 60)) min uptime"
}

cmd_wifi_disable() {
    info "Disabling WiFi..."
    sudo rfkill block wifi
    
    # Turn LED off
    if [[ -d /sys/class/leds/PWR ]]; then
        echo none | sudo tee /sys/class/leds/PWR/trigger >/dev/null
        echo 0 | sudo tee /sys/class/leds/PWR/brightness >/dev/null
    elif [[ -d /sys/class/leds/led1 ]]; then
        echo none | sudo tee /sys/class/leds/led1/trigger >/dev/null
        echo 0 | sudo tee /sys/class/leds/led1/brightness >/dev/null
    fi
    
    info "WiFi disabled (LED OFF)"
}

cmd_wifi_keep() {
    info "Keeping WiFi enabled permanently..."
    sudo rfkill unblock wifi
    
    # Stop the timer so wifi doesn't get auto-disabled
    sudo systemctl stop teslacam-archive.timer
    info "Stopped auto-archive timer"
    
    warn "To resume auto-archiving: tesla-ctl resume"
}

cmd_resume() {
    info "Resuming normal operation..."
    sudo systemctl start teslacam-archive.timer
    info "Auto-archive timer restarted"
    warn "WiFi will auto-disable after $((WIFI_DISABLE_AFTER / 60)) min uptime"
}

cmd_logs() {
    if [[ -f "$ARCHIVE_DIR/archive.log" ]]; then
        tail -50 "$ARCHIVE_DIR/archive.log"
    else
        error "No logs found at $ARCHIVE_DIR/archive.log"
    fi
}

cmd_logs_live() {
    if [[ -f "$ARCHIVE_DIR/archive.log" ]]; then
        tail -f "$ARCHIVE_DIR/archive.log"
    else
        error "No logs found at $ARCHIVE_DIR/archive.log"
    fi
}

cmd_archive_now() {
    info "Running archive now..."
    sudo systemctl start teslacam-archive.service
    info "Archive job started"
}

cmd_help() {
    cat <<EOF
Tesla USB Control - Simple API

Usage: tesla-ctl <command>

Commands:
  status           Show system status (uptime, wifi, storage, service)
  wifi-enable      Enable WiFi and turn LED on
  wifi-disable     Disable WiFi and turn LED off
  wifi-keep        Keep WiFi enabled permanently (stops auto-disable)
  resume           Resume normal operation (re-enable auto-disable)
  logs             Show last 50 log lines
  logs-live        Follow logs in real-time
  archive-now      Run archive job immediately
  help             Show this help

LED Indicators:
  ON  = WiFi enabled (can SSH)
  OFF = WiFi disabled (archiving mode)

Examples:
  tesla-ctl status          # Check everything
  tesla-ctl wifi-enable     # Turn on WiFi to SSH in
  tesla-ctl logs            # View recent logs
EOF
}

###############################################################################
# Main
###############################################################################

COMMAND="${1:-help}"

case "$COMMAND" in
    status)       cmd_status ;;
    wifi-enable)  cmd_wifi_enable ;;
    wifi-disable) cmd_wifi_disable ;;
    wifi-keep)    cmd_wifi_keep ;;
    resume)       cmd_resume ;;
    logs)         cmd_logs ;;
    logs-live)    cmd_logs_live ;;
    archive-now)  cmd_archive_now ;;
    help|--help|-h) cmd_help ;;
    *)            error "Unknown command: $COMMAND"; echo; cmd_help; exit 1 ;;
esac

