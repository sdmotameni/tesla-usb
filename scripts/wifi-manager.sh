#!/usr/bin/env bash
###############################################################################
# WiFi Manager - Handles timed WiFi disable without using rfkill block
# Runs every minute via systemd timer
###############################################################################

set -euo pipefail

# Configuration
WIFI_TIMEOUT=${WIFI_TIMEOUT:-300}  # 5 minutes default
STATE_FILE="/run/wifi-manager-state"  # In RAM, never persists across reboots
LOG_FILE="/var/log/wifi-manager.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Check if wifi should be permanently on
if [[ -f "/run/wifi-permanent" ]]; then
    exit 0  # Don't manage wifi if permanent flag exists
fi

# Get uptime in seconds
UPTIME=$(awk '{print int($1)}' /proc/uptime)

# LED control
set_led() {
    local state=$1  # "on" or "off"
    for LED in ACT led0 led1 PWR; do
        if [[ -d /sys/class/leds/$LED ]]; then
            if [[ "$state" == "on" ]]; then
                echo default-on > /sys/class/leds/$LED/trigger 2>/dev/null || true
            else
                echo none > /sys/class/leds/$LED/trigger 2>/dev/null || true
                echo 0 > /sys/class/leds/$LED/brightness 2>/dev/null || true
            fi
            break
        fi
    done
}

# Check if WiFi should be on or off
if [[ $UPTIME -lt $WIFI_TIMEOUT ]]; then
    # Should be ON
    if [[ ! -f "$STATE_FILE" ]] || [[ "$(cat $STATE_FILE)" != "on" ]]; then
        log "Uptime ${UPTIME}s < ${WIFI_TIMEOUT}s - Enabling WiFi"
        
        # Bring interface up (doesn't use rfkill!)
        ip link set wlan0 up 2>/dev/null || true
        
        # Start services if not running
        if ! systemctl is-active --quiet wpa_supplicant; then
            systemctl start wpa_supplicant 2>/dev/null || true
        fi
        if ! systemctl is-active --quiet dhcpcd; then
            systemctl start dhcpcd 2>/dev/null || true
        fi
        
        # Force reconnect
        wpa_cli -i wlan0 reconnect 2>/dev/null || true
        
        set_led "on"
        echo "on" > "$STATE_FILE"
        log "WiFi enabled"
    fi
else
    # Should be OFF
    if [[ ! -f "$STATE_FILE" ]] || [[ "$(cat $STATE_FILE)" != "off" ]]; then
        log "Uptime ${UPTIME}s >= ${WIFI_TIMEOUT}s - Disabling WiFi"
        
        # Bring interface down (doesn't persist across reboots!)
        ip link set wlan0 down 2>/dev/null || true
        
        set_led "off"
        echo "off" > "$STATE_FILE"
        log "WiFi disabled"
    fi
fi
