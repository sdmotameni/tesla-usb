#!/usr/bin/env bash
#
# Tesla USB Dashcam Archiver - Partition Setup Script
# Helps set up partitions for the Tesla USB Dashcam Archiver
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
echo "   Tesla USB Dashcam Archiver - Partition Setup Script"
echo "=========================================================="
echo ""
log_warn "⚠️  WARNING: This script will modify partitions on your SD card."
log_warn "⚠️  Make sure you have backed up any important data."
log_warn "⚠️  This script is potentially DANGEROUS and could result in DATA LOSS."
echo ""
read -p "Are you sure you want to continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  log_info "Operation cancelled."
  exit 0
fi

# Check for required tools
log_info "Checking for required tools..."
for tool in parted lvm2 mkfs.vfat; do
  if ! command -v $tool &> /dev/null; then
    log_error "Required tool '$tool' is not installed. Please install it first."
    if [[ "$tool" == "lvm2" ]]; then
      log_info "You can install it with: sudo apt install lvm2"
    elif [[ "$tool" == "parted" ]]; then
      log_info "You can install it with: sudo apt install parted"
    fi
    exit 1
  fi
done
log_info "All required tools are installed."

# List available devices
echo ""
log_info "Available devices:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
echo ""

# Get device to partition
read -p "Enter the device to partition (e.g., mmcblk0): " DEVICE
if [[ ! -b "/dev/$DEVICE" ]]; then
  log_error "Device /dev/$DEVICE does not exist or is not a block device."
  exit 1
fi

# Confirm device selection
log_warn "⚠️  You have selected /dev/$DEVICE"
log_warn "⚠️  ALL DATA ON THIS DEVICE WILL BE LOST!"
read -p "Are you absolutely sure? (Type 'YES' to confirm): " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
  log_info "Operation cancelled."
  exit 0
fi

# Get total size of the device
TOTAL_SIZE=$(blockdev --getsize64 /dev/$DEVICE)
TOTAL_SIZE_GB=$(echo "scale=2; $TOTAL_SIZE / 1024 / 1024 / 1024" | bc)
log_info "Device size: $TOTAL_SIZE_GB GB"

# Get partition sizes
echo ""
log_info "Please specify partition sizes:"
echo "1. Root partition - Raspberry Pi OS"
echo "2. Tesla USB partition - Used by Tesla for recording"
echo "3. LVM partition - Used for archive storage (remaining space)"
echo ""

read -p "Root partition size in GB [32]: " ROOT_SIZE
ROOT_SIZE=${ROOT_SIZE:-32}

read -p "Tesla USB partition size in GB [128]: " TESLA_SIZE
TESLA_SIZE=${TESLA_SIZE:-128}

# Calculate remaining space for LVM
LVM_SIZE=$(echo "scale=2; $TOTAL_SIZE_GB - $ROOT_SIZE - $TESLA_SIZE" | bc)
if (( $(echo "$LVM_SIZE <= 0" | bc -l) )); then
  log_error "Not enough space left for LVM partition."
  exit 1
fi

log_info "Partition allocation:"
echo "1. Root partition: $ROOT_SIZE GB"
echo "2. Tesla USB partition: $TESLA_SIZE GB"
echo "3. LVM partition: $LVM_SIZE GB (remaining space)"
echo ""

read -p "Proceed with partitioning? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  log_info "Operation cancelled."
  exit 0
fi

# Unmount any mounted partitions
log_info "Unmounting any mounted partitions..."
for part in $(mount | grep "/dev/$DEVICE" | awk '{print $1}'); do
  log_info "Unmounting $part"
  umount -f "$part" || true
done

# Create partition table
log_info "Creating new partition table..."
parted -s /dev/$DEVICE mklabel msdos

# Calculate partition sizes in MB
ROOT_SIZE_MB=$((ROOT_SIZE * 1024))
TESLA_SIZE_MB=$((TESLA_SIZE * 1024))

# Create partitions
log_info "Creating partitions..."
parted -s /dev/$DEVICE mkpart primary fat32 1MiB "${ROOT_SIZE_MB}MiB"
parted -s /dev/$DEVICE mkpart primary fat32 "${ROOT_SIZE_MB}MiB" "$((ROOT_SIZE_MB + TESLA_SIZE_MB))MiB"
parted -s /dev/$DEVICE mkpart primary "$((ROOT_SIZE_MB + TESLA_SIZE_MB))MiB" 100%

# Set boot flag on first partition
parted -s /dev/$DEVICE set 1 boot on

log_info "Partitions created successfully."

# Format Tesla USB partition as FAT32
log_info "Formatting Tesla USB partition (FAT32)..."
if [[ "$DEVICE" == mmcblk* ]]; then
  TESLA_PART="/dev/${DEVICE}p2"
else
  TESLA_PART="/dev/${DEVICE}2"
fi

mkfs.vfat -F 32 -n "TESLA_CAM" "$TESLA_PART"

# Set up LVM
log_info "Setting up LVM..."
if [[ "$DEVICE" == mmcblk* ]]; then
  LVM_PART="/dev/${DEVICE}p3"
else
  LVM_PART="/dev/${DEVICE}3"
fi

# Make sure the partition is unmounted before creating physical volume
if mount | grep -q "$LVM_PART"; then
  log_info "Unmounting $LVM_PART before creating physical volume"
  umount -f "$LVM_PART" || true
fi

# Create physical volume
log_info "Creating LVM physical volume on $LVM_PART"
pvcreate "$LVM_PART"

# Create volume group
vgcreate tesla_vg "$LVM_PART"

# Calculate logical volume size (about 5% smaller than partition size for LVM overhead)
# This provides space for LVM metadata, snapshots, and prevents performance issues
LV_SIZE=$(echo "scale=0; ${TESLA_SIZE} * 0.95 / 1" | bc)
log_info "Creating logical volume with size ${LV_SIZE}G (5% smaller than partition for LVM overhead)"
log_info "This space is needed for LVM metadata, snapshots, and to prevent performance degradation"

# Create logical volumes
lvcreate -L "${LV_SIZE}G" -n tesla_usb tesla_vg

# Format Tesla USB logical volume
log_info "Formatting Tesla USB logical volume (FAT32)..."
mkfs.vfat -F 32 -n "TESLA_CAM_LV" /dev/tesla_vg/tesla_usb

# Create TeslaCam directory
log_info "Creating TeslaCam directory..."
mkdir -p /mnt/tesla_init
mount /dev/tesla_vg/tesla_usb /mnt/tesla_init
mkdir -p /mnt/tesla_init/TeslaCam
umount /mnt/tesla_init

log_info "Partition setup completed successfully!"
echo ""
log_info "Next steps:"
echo "1. Run the installation script: sudo ./scripts/install.sh"
echo "2. Configure USB Mass Storage Gadget (if using a Pi Zero)"
echo "3. Reboot your Raspberry Pi"
echo ""
log_warn "Note: You will need to reinstall Raspberry Pi OS on the root partition."
echo "==========================================================" 