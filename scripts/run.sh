#!/usr/bin/env bash
###############################################################################
# TeslaCam Archiver - Simplified
# Takes snapshot of Tesla USB, syncs files, manages disk space
###############################################################################

set -euo pipefail

###############################################################################
# CONFIGURATION
###############################################################################
CONFIG_FILE="${CONFIG_FILE:-/etc/tesla-usb/tesla-usb.conf}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Defaults
: "${VG_NAME:=tesla_vg}"
: "${LV_NAME:=tesla_usb}"
: "${SNAP_NAME:=tesla_snap}"
: "${SNAP_SIZE:=3G}"
: "${SNAP_MOUNT:=/mnt/tesla_snap}"
: "${ARCHIVE_DIR:=/mnt/tesla_archive}"
: "${LOG_FILE:=$ARCHIVE_DIR/archive.log}"
: "${MIN_DISK_SPACE_PCT:=10}"
: "${MAX_DISK_TEMP:=100}"
###############################################################################
# HELPERS
###############################################################################
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

###############################################################################
# SETUP
###############################################################################
mkdir -p "$SNAP_MOUNT" "$ARCHIVE_DIR"
touch "$LOG_FILE"

# Single instance lock
exec 200>/var/lock/teslacam.lock
flock -n 200 || { log "Already running, exiting"; exit 0; }

###############################################################################
# CLEANUP ON EXIT
###############################################################################
cleanup() {
    local rv=$?
    if [[ -e "/dev/$VG_NAME/$SNAP_NAME" ]]; then
        umount "$SNAP_MOUNT" 2>/dev/null || true
        lvremove -f "/dev/$VG_NAME/$SNAP_NAME" &>/dev/null || true
    fi
    [[ $rv -eq 0 ]] && log "✓ Complete" || log "✗ Failed (exit $rv)"
    exit $rv
}
trap cleanup EXIT INT TERM

###############################################################################
# PRE-FLIGHT CHECKS
###############################################################################
log "Starting archive run"

# Clean stale snapshot if exists
if lvs "$VG_NAME/$SNAP_NAME" &>/dev/null; then
    log "Cleaning stale snapshot"
    umount "$SNAP_MOUNT" 2>/dev/null || true
    lvremove -f "/dev/$VG_NAME/$SNAP_NAME" &>/dev/null || true
fi

# Temperature check (optional - skip if smartctl not available)
if command -v smartctl &>/dev/null; then
    DISK_DEV=$(df "$ARCHIVE_DIR" | awk 'NR==2 {print $1}' | sed 's/[0-9]*$//')
    if [[ -n "$DISK_DEV" ]]; then
        TEMP=$(smartctl -A "$DISK_DEV" 2>/dev/null | awk '/Temperature/ {print $10; exit}' || echo 0)
        if [[ "$TEMP" -gt "$MAX_DISK_TEMP" ]]; then
            log "Disk too hot (${TEMP}°C), skipping"
            exit 0
        fi
    fi
fi

###############################################################################
# SNAPSHOT & SYNC
###############################################################################
log "Creating snapshot"
lvcreate -L "$SNAP_SIZE" -s -n "$SNAP_NAME" "/dev/$VG_NAME/$LV_NAME" &>/dev/null || die "Snapshot creation failed"

log "Mounting snapshot"
mount -o ro "/dev/$VG_NAME/$SNAP_NAME" "$SNAP_MOUNT" || die "Mount failed"

# Sync files - rsync does all the heavy lifting!
# -a = archive mode (preserves timestamps, permissions)
# --ignore-existing = skip files that exist in destination
# --stats = show transfer statistics
log "Syncing files"
if [[ -d "$SNAP_MOUNT/TeslaCam" ]]; then
    rsync -a --ignore-existing --stats "$SNAP_MOUNT/TeslaCam/" "$ARCHIVE_DIR/TeslaCam/" 2>&1 | \
        grep -E "Number of files transferred|Total file size" | tee -a "$LOG_FILE" || true
else
    log "No TeslaCam directory found"
fi

log "Unmounting snapshot"
umount "$SNAP_MOUNT"
lvremove -f "/dev/$VG_NAME/$SNAP_NAME" &>/dev/null

###############################################################################
# DISK SPACE MANAGEMENT
###############################################################################
USED_PCT=$(df "$ARCHIVE_DIR" | awk 'NR==2 {print $5}' | tr -d '%')
FREE_PCT=$((100 - USED_PCT))
log "Disk usage: ${USED_PCT}% used, ${FREE_PCT}% free"

if [[ $FREE_PCT -lt $MIN_DISK_SPACE_PCT ]]; then
    log "Low disk space, deleting oldest files"
    
    # Find oldest .mp4 files and delete until we have enough space
    find "$ARCHIVE_DIR/TeslaCam" -type f -name '*.mp4' -printf '%T@ %s %p\n' 2>/dev/null | \
        sort -n | \
        while read -r timestamp size filepath; do
            rm -f "$filepath" && log "Deleted: $(basename "$filepath")"
            
            # Check if we have enough space now
            CURRENT_FREE=$(df "$ARCHIVE_DIR" | awk 'NR==2 {print 100 - $5}' | tr -d '%')
            [[ $CURRENT_FREE -ge $MIN_DISK_SPACE_PCT ]] && break
        done
    
    # Clean up empty directories
    find "$ARCHIVE_DIR/TeslaCam" -type d -empty -delete 2>/dev/null || true
    
    FINAL_FREE=$((100 - $(df "$ARCHIVE_DIR" | awk 'NR==2 {print $5}' | tr -d '%')))
    log "After cleanup: ${FINAL_FREE}% free"
fi
