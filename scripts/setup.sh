#!/usr/bin/env bash
###############################################################################
# Tesla USB Dashcam Archiver - One-Time Setup
# Run this once after installing Raspberry Pi OS
###############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || error "Run as root: sudo $0"

echo "=============================================="
echo "  Tesla USB Archiver - Setup"
echo "=============================================="
echo

# Install dependencies
info "Installing dependencies..."
apt-get update -qq && apt-get install -y lvm2 rsync smartmontools

# Create directories
info "Creating directories..."
mkdir -p /usr/local/bin /etc/tesla-usb /mnt/tesla_snap /mnt/tesla_archive

# Mount archive volume if not already mounted
if ! mountpoint -q /mnt/tesla_archive; then
    info "Mounting archive volume..."
    mount /dev/tesla_vg/tesla_archive /mnt/tesla_archive || error "Failed to mount archive volume. Run setup_partitions.sh first!"
fi

# Add to /etc/fstab for automatic mounting
if ! grep -q "tesla_archive" /etc/fstab; then
    info "Adding archive volume to /etc/fstab..."
    echo "/dev/tesla_vg/tesla_archive  /mnt/tesla_archive  ext4  defaults,nofail  0  2" >> /etc/fstab
fi

# Install scripts
info "Installing archiver script..."
cp "$(dirname "$0")/run.sh" /usr/local/bin/tesla-usb-archive.sh
chmod +x /usr/local/bin/tesla-usb-archive.sh

info "Installing control script..."
cp "$(dirname "$0")/tesla-ctl.sh" /usr/local/bin/tesla-ctl
chmod +x /usr/local/bin/tesla-ctl

info "Installing wifi manager..."
cp "$(dirname "$0")/wifi-manager.sh" /usr/local/bin/wifi-manager.sh
chmod +x /usr/local/bin/wifi-manager.sh

# Install config
info "Installing configuration..."
cat > /etc/tesla-usb/tesla-usb.conf <<'EOF'
# Tesla USB Archiver Configuration
VG_NAME=tesla_vg
LV_NAME=tesla_usb
SNAP_NAME=tesla_snap
SNAP_SIZE=3G
SNAP_MOUNT=/mnt/tesla_snap
ARCHIVE_DIR=/mnt/tesla_archive
MIN_DISK_SPACE_PCT=10
MAX_DISK_TEMP=100
WIFI_DISABLE_AFTER=300
EOF

# Set up log rotation
info "Installing logrotate configuration..."
if [[ -n "$SUDO_USER" ]]; then
    cat > /etc/logrotate.d/tesla-usb <<EOF
/mnt/tesla_archive/archive.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0644 $SUDO_USER $SUDO_USER
}
EOF
else
    cat > /etc/logrotate.d/tesla-usb <<'EOF'
/mnt/tesla_archive/archive.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0644 root root
}
EOF
fi

# Install systemd services
info "Installing systemd services..."

# WiFi unblock on boot service
cp "$(dirname "$0")/../etc/systemd/system/wifi-unblock.service" /etc/systemd/system/

# WiFi manager service and timer
cp "$(dirname "$0")/../etc/systemd/system/wifi-manager.service" /etc/systemd/system/
cp "$(dirname "$0")/../etc/systemd/system/wifi-manager.timer" /etc/systemd/system/

# Archive service
cat > /etc/systemd/system/teslacam-archive.service <<'EOF'
[Unit]
Description=TeslaCam Snapshot & Archive
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/tesla-usb-archive.sh
TimeoutSec=600
Nice=10
IOSchedulingClass=2
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/teslacam-archive.timer <<'EOF'
[Unit]
Description=Run TeslaCam Archive Periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Unit=teslacam-archive.service

[Install]
WantedBy=timers.target
EOF

# Set permissions on archive directory
if [[ -n "$SUDO_USER" ]]; then
    chown -R "$SUDO_USER:$SUDO_USER" /mnt/tesla_archive 2>/dev/null || true
fi

# Enable services
info "Enabling systemd services..."
systemctl daemon-reload
systemctl enable wifi-unblock.service
systemctl enable wifi-manager.timer
systemctl enable teslacam-archive.timer
# Don't start immediately to avoid kicking user out
info "Timers enabled. Will start on next reboot."

echo
echo "=============================================="
info "Setup complete!"
echo
echo "The archiver runs every 15 minutes."
echo "WiFi auto-disables after 5 min uptime (LED turns OFF)"
echo
echo "Storage:"
echo "  Archive: /mnt/tesla_archive (separate LVM volume)"
echo
echo "Control Command:"
info "  tesla-ctl status        # Check everything"
info "  tesla-ctl wifi-enable   # Turn on WiFi + LED"
info "  tesla-ctl wifi-disable  # Turn off WiFi + LED"
info "  tesla-ctl logs          # View recent logs"
info "  tesla-ctl help          # Show all commands"
echo
echo "Advanced:"
echo "  Edit config:    sudo nano /etc/tesla-usb/tesla-usb.conf"
echo "  Manual archive: sudo systemctl start teslacam-archive.service"
echo "=============================================="

