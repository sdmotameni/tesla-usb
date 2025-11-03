#!/usr/bin/env bash
###############################################################################
# SD Card Prep Script - Run on your COMPUTER (not the Pi)
# Run this AFTER flashing Raspberry Pi OS but BEFORE first boot
###############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || error "Run as root: sudo $0"

echo "=============================================="
echo "  Tesla USB - SD Card Prep"
echo "  (Run on your computer, not the Pi)"
echo "=============================================="
warn "This should be run AFTER flashing Raspberry Pi OS"
warn "but BEFORE the first boot of the Pi"
echo

# Show available devices
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL
echo

read -p "Enter SD card device (e.g., sdb or mmcblk0): " DEVICE
[[ -b "/dev/$DEVICE" ]] || error "Device /dev/$DEVICE not found"

# Determine partition naming
if [[ "$DEVICE" == mmcblk* ]]; then
    P="${DEVICE}p"
else
    P="${DEVICE}"
fi

# Verify it looks like a fresh Raspberry Pi OS flash
if [[ ! -b "/dev/${P}2" ]]; then
    error "This doesn't look like a Raspberry Pi OS SD card (no partition 2)"
fi

info "Found Raspberry Pi OS on /dev/$DEVICE"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL /dev/$DEVICE
echo

read -p "Size for root partition (OS) in GB [32]: " ROOT_GB
ROOT_GB=${ROOT_GB:-32}

warn "This will:"
echo "  1. Shrink partition 2 (root) to ${ROOT_GB}GB"
echo "  2. Create partition 3 with remaining space"
echo "  3. Prepare for LVM setup"
echo
read -p "Type 'YES' to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 0

# Unmount everything
info "Unmounting partitions..."
umount /dev/${P}* 2>/dev/null || true

# Resize the partition FIRST (expand it to desired size)
info "Expanding partition 2 to ${ROOT_GB}GB..."
parted -s /dev/$DEVICE resizepart 2 ${ROOT_GB}GB || error "Failed to resize partition"

# Check filesystem
info "Checking filesystem on partition 2..."
e2fsck -f -y /dev/${P}2 || warn "Filesystem check had issues (may be normal)"

# Now resize filesystem to fill the partition
info "Expanding filesystem to fill partition..."
resize2fs /dev/${P}2 || error "Failed to resize filesystem"

# Create partition 3 with remaining space
info "Creating partition 3..."
parted -s /dev/$DEVICE mkpart primary ${ROOT_GB}GB 100% || error "Failed to create partition 3"

# Update partition table
partprobe /dev/$DEVICE
sleep 2

echo
echo "=============================================="
info "SD Card prep complete!"
echo
info "Partition layout:"
lsblk -o NAME,SIZE,TYPE,FSTYPE /dev/$DEVICE
echo
echo "Next steps:"
echo "  1. Eject SD card safely"
echo "  2. Insert into Raspberry Pi"
echo "  3. Boot the Pi"
echo "  4. SSH in and run: sudo ./scripts/setup_partitions.sh"
echo "=============================================="

