#!/usr/bin/env bash
###############################################################################
# Tesla USB - Partition Setup
# Creates LVM partition for Tesla USB volume
###############################################################################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || error "Run as root: sudo $0"

# Check tools
command -v parted &>/dev/null || { info "Installing parted..."; apt-get update -qq && apt-get install -y parted; }
command -v lvm &>/dev/null || { info "Installing lvm2..."; apt-get update -qq && apt-get install -y lvm2; }

echo "=============================================="
echo "  Tesla USB - Partition Setup"
echo "=============================================="
echo

# Detect the boot device (usually mmcblk0 for SD cards)
DEVICE=$(lsblk -ndo NAME,TYPE | grep disk | head -1 | awk '{print $1}')
if [[ -z "$DEVICE" ]]; then
    error "Could not detect boot device"
fi

info "Detected device: /dev/$DEVICE"
echo

# Show current partition layout
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT /dev/$DEVICE
echo

# Determine partition naming (mmcblk0p1 vs sda1)
if [[ "$DEVICE" == mmcblk* ]]; then
    PART_PREFIX="${DEVICE}p"
else
    PART_PREFIX="${DEVICE}"
fi

# Check if partition 3 already exists
if [[ -b "/dev/${PART_PREFIX}3" ]]; then
    info "Partition 3 already exists, will use it for LVM"
    PART="/dev/${PART_PREFIX}3"
else
    # Check available free space
    FREE_SPACE=$(parted /dev/$DEVICE unit GB print free 2>/dev/null | grep 'Free Space' | tail -1 | awk '{print $3}' | sed 's/GB//')
    
    if [[ -z "$FREE_SPACE" ]] || (( $(echo "$FREE_SPACE < 10" | bc -l) )); then
        error "No free space available to create partition 3

This happens because Raspberry Pi OS auto-expands to fill the entire SD card.

SOLUTION: Run this BEFORE first boot of Raspberry Pi OS:
==========================================
From another Linux computer:

1. Flash Raspberry Pi OS to SD card
2. BEFORE booting the Pi, run this on your computer:

   # Shrink partition 2 to 32GB
   sudo parted /dev/sdX resizepart 2 32GB
   
   # Create partition 3 with remaining space  
   sudo parted /dev/sdX mkpart primary 32GB 100%
   
   # Resize the filesystem to match
   sudo e2fsck -f /dev/sdX2
   sudo resize2fs /dev/sdX2

3. THEN boot the Pi and run this script again
=========================================="
    fi
    
    info "Found ${FREE_SPACE}GB of free space"
    
    # Get desired size
    read -p "Size for Tesla USB volume in GB [128]: " TESLA_GB
    TESLA_GB=${TESLA_GB:-128}
    
    # Confirm
    warn "This will create partition 3 on /dev/$DEVICE"
    read -p "Type 'YES' to confirm: " CONFIRM
    [[ "$CONFIRM" == "YES" ]] || exit 0
    
    # Unmount if mounted
    umount /dev/${PART_PREFIX}3 2>/dev/null || true
    
    # Create partition 3
    info "Creating partition 3..."
    END_SECTOR=$(parted /dev/$DEVICE unit s print free | grep 'Free Space' | tail -1 | awk '{print $1}' | sed 's/s//')
    parted -s /dev/$DEVICE mkpart primary ${END_SECTOR}s 100%
    
    # Wait for device to appear
    sleep 2
    partprobe /dev/$DEVICE
    sleep 1
    
    PART="/dev/${PART_PREFIX}3"
    
    if [[ ! -b "$PART" ]]; then
        error "Failed to create partition 3"
    fi
    
    info "Created partition 3: $PART"
fi

# Calculate available space in partition 3
PART_SIZE_BYTES=$(blockdev --getsize64 "$PART" 2>/dev/null || echo "0")
PART_SIZE_GB=$(echo "scale=0; $PART_SIZE_BYTES / 1024 / 1024 / 1024" | bc)

if [[ "$PART_SIZE_GB" -lt 10 ]]; then
    error "Partition 3 is too small: ${PART_SIZE_GB}GB"
fi

info "Partition 3 has ${PART_SIZE_GB}GB available"

# Get size for logical volume
read -p "Size for Tesla USB volume in GB [${PART_SIZE_GB}]: " TESLA_GB
TESLA_GB=${TESLA_GB:-$PART_SIZE_GB}

# Validate size
if [[ $TESLA_GB -gt $PART_SIZE_GB ]]; then
    error "Requested size (${TESLA_GB}GB) exceeds partition size (${PART_SIZE_GB}GB)"
fi

# Set up LVM
info "Setting up LVM on $PART..."

# Remove existing LVM if present
vgremove -f tesla_vg 2>/dev/null || true
pvremove -f "$PART" 2>/dev/null || true

# Create LVM structure
pvcreate -f "$PART" || error "Failed to create physical volume"
vgcreate tesla_vg "$PART" || error "Failed to create volume group"

# Calculate sizes - split between Tesla USB and Archive
# Tesla USB gets requested size, Archive gets the rest (minus safety margin)
LV_TESLA_SIZE=$(echo "scale=0; $TESLA_GB * 0.95 / 1" | bc)
LV_ARCHIVE_SIZE=$(echo "scale=0; ($PART_SIZE_GB - $TESLA_GB - 10) / 1" | bc)

if [[ $LV_ARCHIVE_SIZE -lt 50 ]]; then
    error "Not enough space for archive volume (need at least 50GB)"
fi

info "Creating Tesla USB volume: ${LV_TESLA_SIZE}GB"
lvcreate -L "${LV_TESLA_SIZE}G" -n tesla_usb tesla_vg || error "Failed to create tesla_usb volume"

info "Creating Archive volume: ${LV_ARCHIVE_SIZE}GB"
lvcreate -L "${LV_ARCHIVE_SIZE}G" -n tesla_archive tesla_vg || error "Failed to create tesla_archive volume"

# Format Tesla USB as FAT32
info "Formatting Tesla USB volume as FAT32..."
mkfs.vfat -F 32 -n "TESLA" /dev/tesla_vg/tesla_usb || error "Format failed"

# Format Archive as ext4 (more efficient for Linux)
info "Formatting Archive volume as ext4..."
mkfs.ext4 -L "ARCHIVE" /dev/tesla_vg/tesla_archive || error "Format failed"

# Create TeslaCam directory on Tesla USB
info "Creating TeslaCam directory..."
mkdir -p /mnt/tesla_init
mount /dev/tesla_vg/tesla_usb /mnt/tesla_init
mkdir -p /mnt/tesla_init/TeslaCam
umount /mnt/tesla_init

# Mount archive volume
info "Mounting archive volume..."
mkdir -p /mnt/tesla_archive
mount /dev/tesla_vg/tesla_archive /mnt/tesla_archive
mkdir -p /mnt/tesla_archive/TeslaCam

# Set ownership to the user who ran sudo (if available)
if [[ -n "$SUDO_USER" ]]; then
    chown -R "$SUDO_USER:$SUDO_USER" /mnt/tesla_archive
else
    # Fallback: make it world-writable
    chmod 777 /mnt/tesla_archive
fi

umount /mnt/tesla_archive

echo
echo "=============================================="
info "Success! Created volumes:"
echo "  Tesla USB:  /dev/tesla_vg/tesla_usb (${LV_TESLA_SIZE}GB FAT32)"
echo "  Archive:    /dev/tesla_vg/tesla_archive (${LV_ARCHIVE_SIZE}GB ext4)"
echo
info "Volumes are ready"
echo
echo "Next steps:"
echo "  1. Run: sudo ./scripts/setup.sh"
echo "  2. Configure USB gadget mode (see README)"
echo "  3. Reboot and plug into Tesla"
echo "=============================================="
