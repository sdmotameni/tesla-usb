#!/usr/bin/env bash
#
# Tesla USB Dashcam Archiver - WiFi Auto-Disable Setup
# Safely disables WiFi after a delay, with a recovery mechanism
#

set -euo pipefail
IFS=$'\n\t'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Log helper functions
log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root (sudo)"
  exit 1
fi

# Show welcome message
clear
echo "=========================================================="
echo "   Tesla USB Dashcam Archiver - WiFi Auto-Disable Setup"
echo "=========================================================="
echo ""
log_info "This script will set up automatic WiFi disabling after boot."
log_info "This enhances security and reduces power consumption."
echo ""
log_info "How it works:"
echo "1. At boot: WiFi is enabled so you can access the Pi if needed."
echo "2. After a delay: A script runs and disables WiFi."
echo "3. To re-enable access: Power cycle the Pi and SSH in during the window."
echo ""

read -p "Continue with installation? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  log_info "Installation cancelled."
  exit 0
fi

# Ask for delay time
echo ""
read -p "Delay before disabling WiFi (minutes) [15]: " DELAY_MIN
DELAY_MIN=${DELAY_MIN:-15}

# Create the WiFi disabling script
log_info "Creating WiFi disabling script..."
cat > /usr/local/bin/disable_wifi.sh << 'EOF'
#!/bin/bash
# Disable WiFi to save power and enhance security

# If keep_wifi.txt exists on /boot, skip disabling WiFi
if [ -f /boot/keep_wifi.txt ]; then
  echo "[INFO] WiFi disable skipped due to /boot/keep_wifi.txt" | systemd-cat -t disable_wifi
  exit 0
fi

echo "[INFO] Disabling WiFi..." | systemd-cat -t disable_wifi
nmcli radio wifi off 2>/dev/null || rfkill block wifi
EOF

chmod +x /usr/local/bin/disable_wifi.sh

# Create systemd service
log_info "Creating systemd service..."
cat > /etc/systemd/system/disable-wifi.service << EOF
[Unit]
Description=Disable WiFi after boot delay

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable_wifi.sh
EOF

# Create systemd timer
log_info "Creating systemd timer with ${DELAY_MIN} minute delay..."
cat > /etc/systemd/system/disable-wifi.timer << EOF
[Unit]
Description=Run disable-wifi.service ${DELAY_MIN} minutes after boot

[Timer]
OnBootSec=${DELAY_MIN}min
AccuracySec=1s
Unit=disable-wifi.service

[Install]
WantedBy=timers.target
EOF

# Enable the timer
log_info "Enabling systemd timer..."
systemctl daemon-reexec
systemctl enable --now disable-wifi.timer

# Offer to create the WiFi override file
echo ""
read -p "Do you want to create /boot/keep_wifi.txt now to prevent WiFi from being disabled? (Y/n): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  touch /boot/keep_wifi.txt
  log_info "/boot/keep_wifi.txt created. WiFi will NOT be disabled unless this file is deleted."
else
  log_info "You can manually create /boot/keep_wifi.txt later if needed."
fi

echo ""
log_info "WiFi auto-disable has been set up successfully!"
echo ""
log_info "WiFi will automatically disable ${DELAY_MIN} minutes after boot unless /boot/keep_wifi.txt exists."
log_info "To temporarily keep WiFi enabled:"
echo "1. Power cycle the Pi"
echo "2. SSH in during the ${DELAY_MIN} minute window"
echo "3. Run: sudo systemctl stop disable-wifi.timer"
echo ""
log_info "To permanently disable this feature:"
echo "sudo systemctl disable disable-wifi.timer"
echo "sudo systemctl stop disable-wifi.timer"
echo "=========================================================="
