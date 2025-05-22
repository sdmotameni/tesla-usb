#!/usr/bin/env bash
#
# Tesla USB Dashcam Archiver - Installation Script
# Automates installation of the Tesla USB Dashcam Archiver on a Raspberry Pi
#

set -euo pipefail
IFS=$'\n\t'

# Default configuration (can be overridden)
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/tesla-usb"
SERVICE_DIR="/etc/systemd/system"
ARCHIVE_DIR="/home/pi/tesla-archive"
USER_CONFIG="${HOME}/.config/tesla-usb.conf"

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
echo "   Tesla USB Dashcam Archiver - Installation Script"
echo "=========================================================="
echo ""
log_info "This script will install the Tesla USB Dashcam Archiver"
echo ""

# Check system requirements
log_info "Checking system requirements..."

# Check for Raspberry Pi
if ! grep -q "Raspberry Pi" /proc/device-tree/model 2>/dev/null; then
  log_warn "This system does not appear to be a Raspberry Pi"
  echo -n "Continue anyway? [y/N] "
  read -r response
  if [[ ! "$response" =~ ^[Yy]$ ]]; then
    log_info "Installation cancelled"
    exit 0
  fi
fi

# Install dependencies
log_info "Installing required packages..."
apt-get update
apt-get install -y lvm2 sqlite3 rsync smartmontools

# Create directories
log_info "Creating directories..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$ARCHIVE_DIR" /mnt/tesla_snap

# Copy files
log_info "Installing scripts..."
cp "$(dirname "$0")/run.sh" "$INSTALL_DIR/tesla-usb-archive.sh"
chmod +x "$INSTALL_DIR/tesla-usb-archive.sh"

# Copy config
log_info "Installing configuration..."
cp "$(dirname "$0")/../config/tesla-usb.conf" "$CONFIG_DIR/tesla-usb.conf"

# Install systemd service and timer
log_info "Installing systemd service and timer..."
cp "$(dirname "$0")/../etc/teslacam-archive.service" "$SERVICE_DIR/"
cp "$(dirname "$0")/../etc/teslacam-archive.timer" "$SERVICE_DIR/"

# Customize configuration based on user input
echo ""
log_info "Configuration setup"
echo ""

# Ask if user wants to customize configuration
echo -n "Would you like to customize the configuration? [y/N] "
read -r customize
if [[ "$customize" =~ ^[Yy]$ ]]; then
  # LVM configuration
  echo -n "LVM Volume Group name [tesla_vg]: "
  read -r vg_name
  vg_name=${vg_name:-tesla_vg}
  
  echo -n "LVM Logical Volume name [tesla_usb]: "
  read -r lv_name
  lv_name=${lv_name:-tesla_usb}
  
  echo -n "LVM Snapshot name [tesla_snap]: "
  read -r snap_name
  snap_name=${snap_name:-tesla_snap}
  
  echo -n "Snapshot size [3G]: "
  read -r snap_size
  snap_size=${snap_size:-3G}
  
  # Archive configuration
  echo -n "Archive directory [$ARCHIVE_DIR]: "
  read -r custom_archive_dir
  custom_archive_dir=${custom_archive_dir:-$ARCHIVE_DIR}
  ARCHIVE_DIR="$custom_archive_dir"
  
  echo -n "Minimum free disk space percentage [10]: "
  read -r min_disk_space
  min_disk_space=${min_disk_space:-10}
  
  # Update configuration file
  sed -i "s/VG_NAME=.*/VG_NAME=$vg_name/" "$CONFIG_DIR/tesla-usb.conf"
  sed -i "s/LV_NAME=.*/LV_NAME=$lv_name/" "$CONFIG_DIR/tesla-usb.conf"
  sed -i "s/SNAP_NAME=.*/SNAP_NAME=$snap_name/" "$CONFIG_DIR/tesla-usb.conf"
  sed -i "s/SNAP_SIZE=.*/SNAP_SIZE=$snap_size/" "$CONFIG_DIR/tesla-usb.conf"
  sed -i "s|ARCHIVE_DIR=.*|ARCHIVE_DIR=$ARCHIVE_DIR|" "$CONFIG_DIR/tesla-usb.conf"
  sed -i "s/MIN_DISK_SPACE_PCT=.*/MIN_DISK_SPACE_PCT=$min_disk_space/" "$CONFIG_DIR/tesla-usb.conf"
  
  # Update service file with correct path
  sed -i "s|ExecStart=.*|ExecStart=$INSTALL_DIR/tesla-usb-archive.sh|" "$SERVICE_DIR/teslacam-archive.service"
  sed -i "s|StandardOutput=.*|StandardOutput=append:$ARCHIVE_DIR/tesla_archive.log|" "$SERVICE_DIR/teslacam-archive.service"
fi

# Create archive directory with correct permissions
log_info "Setting up archive directory..."
mkdir -p "$ARCHIVE_DIR"
chown -R pi:pi "$ARCHIVE_DIR"

# Enable and start services
log_info "Enabling systemd services..."
systemctl daemon-reload
systemctl enable teslacam-archive.service
systemctl enable teslacam-archive.timer
systemctl start teslacam-archive.timer

# Final instructions
echo ""
echo "=========================================================="
log_info "Installation complete!"
echo ""
log_info "Next steps:"
echo "1. Set up LVM partitioning as described in the README"
echo "2. Configure USB Mass Storage Gadget if using a Pi Zero"
echo "3. Reboot your Raspberry Pi"
echo ""
log_info "To manually start archiving: sudo systemctl start teslacam-archive.service"
log_info "To view logs: tail -f $ARCHIVE_DIR/tesla_archive.log"
echo "==========================================================" 