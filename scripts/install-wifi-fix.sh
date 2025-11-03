#!/usr/bin/env bash
###############################################################################
# Install WiFi Fix - Apply robust WiFi management to existing installation
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Check if running as root
[[ $EUID -eq 0 ]] || error "Run as root: sudo $0"

info "Installing WiFi fix..."

# Stop any existing services
systemctl stop teslacam-archive.timer 2>/dev/null || true
systemctl stop wifi-manager.timer 2>/dev/null || true

# Install new wifi-manager script
info "Installing wifi-manager..."
cat > /usr/local/bin/wifi-manager.sh << 'SCRIPT_EOF'
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
SCRIPT_EOF
chmod +x /usr/local/bin/wifi-manager.sh

# Install wifi-manager service
cat > /etc/systemd/system/wifi-manager.service << 'EOF'
[Unit]
Description=WiFi Manager - Timed WiFi Control
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wifi-manager.sh
StandardOutput=null
StandardError=journal
EOF

# Install wifi-manager timer
cat > /etc/systemd/system/wifi-manager.timer << 'EOF'
[Unit]
Description=WiFi Manager Timer - Check every minute
After=multi-user.target

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
Unit=wifi-manager.service

[Install]
WantedBy=timers.target
EOF

# Update wifi-unblock service to be more robust
cat > /etc/systemd/system/wifi-unblock.service << 'EOF'
[Unit]
Description=Ensure WiFi starts enabled on boot
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
# Clear any rfkill blocks that may have persisted
ExecStartPre=/bin/rm -f /var/lib/systemd/rfkill/*
# Unblock all rfkill
ExecStart=/usr/sbin/rfkill unblock all
ExecStart=/usr/sbin/rfkill unblock wifi
ExecStart=/usr/sbin/rfkill unblock 0
ExecStart=/usr/sbin/rfkill unblock 1
# Ensure interface is up
ExecStartPost=/sbin/ip link set wlan0 up
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

# Update the main archiver script to remove WiFi control
info "Updating archiver script..."
if grep -q "check_wifi_timer" /usr/local/bin/tesla-usb-archive.sh; then
    # Remove wifi functions
    sed -i '/set_led_wifi_on()/,/^}/d' /usr/local/bin/tesla-usb-archive.sh 2>/dev/null || true
    sed -i '/set_led_wifi_off()/,/^}/d' /usr/local/bin/tesla-usb-archive.sh 2>/dev/null || true
    sed -i '/disable_wifi()/,/^}/d' /usr/local/bin/tesla-usb-archive.sh 2>/dev/null || true
    sed -i '/check_wifi_timer()/,/^}/d' /usr/local/bin/tesla-usb-archive.sh 2>/dev/null || true
    # Remove call to check_wifi_timer
    sed -i '/check_wifi_timer/d' /usr/local/bin/tesla-usb-archive.sh 2>/dev/null || true
    # Remove WIFI_DISABLE_AFTER variable
    sed -i '/WIFI_DISABLE_AFTER/d' /usr/local/bin/tesla-usb-archive.sh 2>/dev/null || true
fi

# Enable services
info "Enabling services..."
systemctl daemon-reload
systemctl enable wifi-unblock.service
systemctl enable wifi-manager.timer
systemctl start wifi-manager.timer

info "WiFi fix installed!"
info "WiFi will:"
info "  - Always start ON after boot"
info "  - Auto-disable after 5 min uptime (configurable)"
info "  - Re-enable on power cycle"
info ""
info "Commands:"
info "  tesla-ctl wifi-enable   - Force WiFi on"
info "  tesla-ctl wifi-disable  - Force WiFi off"
info "  tesla-ctl wifi-keep     - Keep WiFi on permanently (this boot)"
info ""
info "To change timeout, edit /etc/tesla-usb/tesla-usb.conf"
