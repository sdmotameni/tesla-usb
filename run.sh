#!/usr/bin/env bash
###############################################################################
# TeslaCam snapshot → archive
# Takes a snapshot of Tesla USB drive, archives footage, then cleans up
# Optimized for Raspberry Pi Zero 2 W
###############################################################################

set -euo pipefail
IFS=$'\n\t'

###############################################################################
# CONFIGURATION
# Define default values and environment variables for script operation
###############################################################################
: "${VG_NAME:=tesla_vg}"
: "${LV_NAME:=tesla_usb}"
: "${SNAP_NAME:=tesla_snap}"
: "${SNAP_SIZE:=3G}"
: "${SNAP_MOUNT:=/mnt/tesla_snap}"
: "${ARCHIVE_DIR:=/home/pi/tesla-archive}"
: "${DB:=$ARCHIVE_DIR/.file_index.sqlite}"
: "${LOG:=$ARCHIVE_DIR/tesla_archive.log}"
: "${MIN_DISK_SPACE_PCT:=10}"  # Minimum disk space threshold (percentage)
: "${BATCH_SIZE:=50}"  # Number of files to batch process before DB insert
: "${MAX_LOG_SIZE:=1073741824}"  # Maximum log file size (1GB)

LOCK_FD=200
LOCK_FILE=/var/lock/teslacam_archive.lock

###############################################################################
# INITIALIZATION
# Create required directories and set up logging
###############################################################################
mkdir -p "$SNAP_MOUNT" "$ARCHIVE_DIR"
touch "$LOG"

# Check log size and truncate if needed
if [[ -f "$LOG" ]]; then
  LOG_SIZE=$(stat -c %s "$LOG" 2>/dev/null || echo "0")
  if (( LOG_SIZE > MAX_LOG_SIZE )); then
    echo "[$(date '+%F %T')] 📝 Log file exceeds 1GB, truncating..." > "$LOG.new"
    # Keep the last 10000 lines (approximately) of the log
    tail -n 10000 "$LOG" >> "$LOG.new"
    mv "$LOG.new" "$LOG"
    echo "[$(date '+%F %T')] 📝 Log truncated successfully" >> "$LOG"
  fi
fi

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

###############################################################################
# SCRIPT LOCKING
# Ensure only one instance of the script runs at a time
###############################################################################
log "🚀 Starting TeslaCam archive process"
log "📂 Archive directory: $ARCHIVE_DIR"
log "💾 Database: $DB"

exec {LOCK_FD}>"$LOCK_FILE" || { log "❌ Failed to acquire lock file: $LOCK_FILE"; exit 1; }
flock -n "$LOCK_FD" || { log "⏱️ Another instance is already running, exiting gracefully"; exit 0; }

###############################################################################
# RECOVERY SAFEGUARDS
# Check for and clean up after interrupted runs (e.g., after power loss)
###############################################################################
log "🛡️ Running recovery checks for power loss or interrupted previous runs"

# Check if snapshot from previous run exists and clean it up
if sudo lvs "$VG_NAME" 2>/dev/null | grep -q "$SNAP_NAME"; then
  log "⚠️ Found stale snapshot from previous interrupted run, cleaning up"
  
  # Check if it's mounted and unmount if needed
  if mount | grep -q "$SNAP_MOUNT"; then
    log "🔄 Unmounting stale snapshot from $SNAP_MOUNT"
    sudo umount -l "$SNAP_MOUNT" 2>/dev/null || log "⚠️ Warning: umount failed, continuing anyway"
  fi
  
  # Remove the stale snapshot
  log "🗑️ Removing stale LVM snapshot /dev/$VG_NAME/$SNAP_NAME"
  sudo lvremove -f "/dev/$VG_NAME/$SNAP_NAME" >>"$LOG" 2>&1 || log "⚠️ Warning: lvremove failed"
fi

# Verify SQLite database integrity and repair if needed
log "🔍 Verifying database integrity"
if [[ -f "$DB" ]]; then
  if ! sqlite3 "$DB" "PRAGMA integrity_check;" | grep -q "ok"; then
    log "⚠️ Database corruption detected, attempting repair"
    # Create backup of corrupted database
    cp "$DB" "$DB.corrupted.$(date +%Y%m%d%H%M%S)"
    
    # Try to recover with dump and restore
    if sqlite3 "$DB" ".dump" > "$DB.dump" 2>/dev/null; then
      rm "$DB"
      sqlite3 "$DB" < "$DB.dump" && rm "$DB.dump" && log "✅ Database recovered successfully" || log "❌ Database recovery failed"
    else
      log "❌ Database too corrupted to recover, reinitializing"
      rm "$DB"
    fi
  else
    log "✅ Database integrity verified"
  fi
fi

###############################################################################
# CLEANUP FUNCTION
# Define cleanup function that runs on script exit
###############################################################################
cleanup() {
  local rv=$?
  log "🧽 Starting cleanup process"
  [[ -e "/dev/$VG_NAME/$SNAP_NAME" ]] && {
    log "🔄 Unmounting snapshot from $SNAP_MOUNT"
    sudo umount -l "$SNAP_MOUNT" 2>/dev/null || log "⚠️ Warning: umount failed, continuing anyway"
    log "🗑️ Removing LVM snapshot /dev/$VG_NAME/$SNAP_NAME"
    sudo lvremove -f "/dev/$VG_NAME/$SNAP_NAME" >>"$LOG" 2>&1 || log "⚠️ Warning: lvremove failed"
  }
  log "🔓 Releasing lock"
  flock -u "$LOCK_FD"
  [[ $rv -eq 0 ]] && log "✅ Process completed successfully" || log "❌ Process exited with code $rv"
  exit "$rv"
}
trap cleanup EXIT INT TERM

###############################################################################
# DATABASE INITIALIZATION
# Create and initialize the SQLite database if it doesn't exist
###############################################################################
# Ensure DB
log "🛠️ Initializing database if needed"
sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS files (
  path       TEXT PRIMARY KEY,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
SQL
log "✅ Database initialized"

###############################################################################
# PRE-FLIGHT CHECKS
# Verify conditions before proceeding with snapshot creation
###############################################################################
log "🔍 Running pre-flight checks"

# Check if mount point is already in use
if mount | grep -q "$SNAP_MOUNT"; then
  log "⚠️ Mount point $SNAP_MOUNT is already in use"
  log "🔄 Attempting to unmount $SNAP_MOUNT"
  sudo umount -l "$SNAP_MOUNT" 2>/dev/null
  if mount | grep -q "$SNAP_MOUNT"; then
    log "❌ Failed to unmount $SNAP_MOUNT - aborting run"
    exit 1
  else
    log "✅ Successfully unmounted $SNAP_MOUNT"
  fi
fi

# Check disk temperature
DISK_TEMP=0
if command -v smartctl >/dev/null 2>&1; then
  DISK_DEVICE=$(df -P "$ARCHIVE_DIR" | awk 'NR==2 {print $1}' | sed 's/[0-9]*$//')
  if [[ -n "$DISK_DEVICE" ]]; then
    DISK_TEMP=$(sudo smartctl -A "$DISK_DEVICE" 2>/dev/null | grep -i "temperature" | awk '{print $10}' | head -n 1 || echo "0")
    log "🌡️ Current disk temperature: ${DISK_TEMP}°C"
    if [[ -z "$DISK_TEMP" || "$DISK_TEMP" = "0" ]]; then
      log "⚠️ Could not determine disk temperature, continuing anyway"
    elif (( DISK_TEMP > 100 )); then
      log "🔥 Disk temperature too high (${DISK_TEMP}°C > 100°C) - skipping this run for safety"
      exit 0
    fi
  else
    log "⚠️ Could not determine disk device for temperature check"
  fi
else
  log "⚠️ smartctl not available for temperature check, continuing anyway"
fi

log "✅ Pre-flight checks completed"

###############################################################################
# SNAPSHOT CREATION
# Create LVM snapshot of Tesla USB drive for consistent archiving
###############################################################################
log "📸 Creating LVM snapshot of Tesla USB drive (/dev/$VG_NAME/$LV_NAME → /dev/$VG_NAME/$SNAP_NAME)"
sudo lvcreate -L "$SNAP_SIZE" -s -n "$SNAP_NAME" "/dev/$VG_NAME/$LV_NAME" >>"$LOG" 2>&1 || {
  log "❌ Snapshot creation failed - check LVM status and available space"
  exit 1
}
log "✅ Snapshot created successfully (size: $SNAP_SIZE)"

log "🔌 Mounting snapshot to $SNAP_MOUNT (read-only)"
sudo mount -o ro,norelatime "/dev/$VG_NAME/$SNAP_NAME" "$SNAP_MOUNT" >>"$LOG" 2>&1 || {
  log "❌ Failed to mount snapshot - check mount point and device status"
  exit 1
}
log "✅ Snapshot mounted successfully"

###############################################################################
# FOOTAGE ARCHIVING
# Find and copy new TeslaCam footage to archive directory
###############################################################################
log "🔍 Scanning for new TeslaCam footage in $SNAP_MOUNT/TeslaCam"
FILE_COUNT=0
TOTAL_SIZE=0
BATCH_COUNT=0
BATCH_SQL=""
TEMP_SQL_FILE=$(mktemp)

# Create start of SQL transaction
echo "BEGIN TRANSACTION;" > "$TEMP_SQL_FILE"

# Find new footage and copy to archive
find "$SNAP_MOUNT/TeslaCam" -type f -name '*.mp4' -print0 |
while IFS= read -r -d '' FILE; do
  REL=${FILE#"$SNAP_MOUNT"/}
  DEST="$ARCHIVE_DIR/$REL"
  DIR=$(dirname "$DEST")
  
  if [[ ! -d "$DIR" ]]; then
    log "📁 Creating directory: $DIR"
    mkdir -p "$DIR"
  fi
  
  # Get source file size
  FILE_SIZE=$(stat -c %s "$FILE" 2>/dev/null || echo "unknown")
  
  # Check if destination file doesn't exist or has different size (potentially incomplete)
  if [[ ! -f "$DEST" ]] || [[ "$FILE_SIZE" != "unknown" && "$FILE_SIZE" != "$(stat -c %s "$DEST" 2>/dev/null || echo "0")" ]]; then
    if [[ -f "$DEST" ]]; then
      log "🔄 Re-copying incomplete file: $REL (source: $(numfmt --to=iec --suffix=B $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes"), dest: $(numfmt --to=iec --suffix=B $(stat -c %s "$DEST" 2>/dev/null || echo "0") 2>/dev/null || echo "0 bytes"))"
    else
      log "📼 Copying: $REL (size: $(numfmt --to=iec --suffix=B $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes"))"
    fi
    rsync -a --no-whole-file --inplace "$FILE" "$DEST"
    COPY_STATUS=$?
    
    if [[ $COPY_STATUS -eq 0 ]]; then
      # Add to batch instead of immediate insert
      # Properly escape single quotes in file paths for SQL
      SQL_SAFE_REL="${REL//\'/\'\'}"
      BATCH_SQL="INSERT OR IGNORE INTO files (path) VALUES ('$SQL_SAFE_REL');"
      echo "$BATCH_SQL" >> "$TEMP_SQL_FILE"
      
      ((FILE_COUNT++))
      ((BATCH_COUNT++))
      [[ "$FILE_SIZE" != "unknown" ]] && TOTAL_SIZE=$((TOTAL_SIZE + FILE_SIZE))
      
      # Execute batch when we reach batch size
      if (( BATCH_COUNT >= BATCH_SIZE )); then
        log "📦 Processing batch of $BATCH_COUNT database inserts"
        echo "COMMIT;" >> "$TEMP_SQL_FILE"
        sqlite3 "$DB" < "$TEMP_SQL_FILE"
        
        # Reset for next batch
        BATCH_COUNT=0
        echo "BEGIN TRANSACTION;" > "$TEMP_SQL_FILE"
      fi
    else
      log "⚠️ Failed to copy $REL (rsync exit code: $COPY_STATUS)"
    fi
  fi
done

# Commit any remaining batched operations
if (( BATCH_COUNT > 0 )); then
  log "📦 Processing final batch of $BATCH_COUNT database inserts"
  echo "COMMIT;" >> "$TEMP_SQL_FILE"
  sqlite3 "$DB" < "$TEMP_SQL_FILE"
fi

# Clean up temp file
rm -f "$TEMP_SQL_FILE"

if [[ $FILE_COUNT -eq 0 ]]; then
  log "📊 No new files found to archive"
else
  HUMAN_SIZE=$(numfmt --to=iec --suffix=B $TOTAL_SIZE 2>/dev/null || echo "$TOTAL_SIZE bytes")
  log "📊 Archive summary: copied $FILE_COUNT new file(s) totaling $HUMAN_SIZE"
fi

###############################################################################
# DISK SPACE MANAGEMENT
# Check free space and clean up oldest files if below threshold
###############################################################################
log "💾 Checking disk space for maintenance"
DISK_USED_PCT=$(df -P "$ARCHIVE_DIR" | awk 'NR==2 {print $5}' | tr -d '%')
FREE_PCT=$((100 - DISK_USED_PCT))

log "💽 Current disk space: ${DISK_USED_PCT}% used, ${FREE_PCT}% free"

# Clean up oldest files if below threshold
if (( FREE_PCT < MIN_DISK_SPACE_PCT )); then
  log "🧹 Available space (${FREE_PCT}%) below threshold (${MIN_DISK_SPACE_PCT}%) - cleaning up oldest footage"
  
  DELETED_COUNT=0
  FREED_SPACE=0
  TEMP_SQL_FILE=$(mktemp)
  
  # Start transaction in temp file
  echo "BEGIN TRANSACTION;" > "$TEMP_SQL_FILE"
  
  # Process oldest files first, up to 100 at a time to avoid excessive deletions
  while IFS=$'\t' read -r FILE_PATH; do
    [[ -z "$FILE_PATH" ]] && continue
    
    FULL_PATH="$ARCHIVE_DIR/$FILE_PATH"
    if [[ -f "$FULL_PATH" ]]; then
      FILE_SIZE=$(stat -c %s "$FULL_PATH" 2>/dev/null || echo "0")
      log "🗑️ Removing old footage: $FILE_PATH ($(numfmt --to=iec --suffix=B $FILE_SIZE 2>/dev/null || echo "$FILE_SIZE bytes"))"
      
      rm -f "$FULL_PATH" && {
        # Add delete command to transaction file
        # Properly escape single quotes in file paths for SQL
        SQL_SAFE_PATH="${FILE_PATH//\'/\'\'}"
        echo "DELETE FROM files WHERE path='$SQL_SAFE_PATH';" >> "$TEMP_SQL_FILE"
        FREED_SPACE=$((FREED_SPACE + FILE_SIZE))
        ((DELETED_COUNT++))
        
        # Periodically check if we've reached the threshold
        if (( DELETED_COUNT % 5 == 0 )); then
          CURRENT_FREE_PCT=$(( 100 - $(df -P "$ARCHIVE_DIR" | awk 'NR==2 {print $5}' | tr -d '%') ))
          if (( CURRENT_FREE_PCT >= MIN_DISK_SPACE_PCT )); then
            log "✅ Space maintenance complete: ${CURRENT_FREE_PCT}% free"
            break
          fi
        fi
      } || {
        log "⚠️ Failed to remove file: $FULL_PATH"
      }
    else
      # Clean up DB if file doesn't exist
      # Properly escape single quotes in file paths for SQL
      SQL_SAFE_PATH="${FILE_PATH//\'/\'\'}"
      echo "DELETE FROM files WHERE path='$SQL_SAFE_PATH';" >> "$TEMP_SQL_FILE"
    fi
  done < <(sqlite3 -list -separator $'\t' "$DB" "SELECT path FROM files ORDER BY created_at ASC LIMIT 100;")
  
  # Commit all the deletes in one transaction
  echo "COMMIT;" >> "$TEMP_SQL_FILE"
  sqlite3 "$DB" < "$TEMP_SQL_FILE"
  rm -f "$TEMP_SQL_FILE"
  
  log "🧹 Space maintenance summary: removed $DELETED_COUNT file(s), freed $(numfmt --to=iec --suffix=B $FREED_SPACE 2>/dev/null || echo "$FREED_SPACE bytes")"
  FINAL_FREE_PCT=$(( 100 - $(df -P "$ARCHIVE_DIR" | awk 'NR==2 {print $5}' | tr -d '%') ))
  log "💽 Disk space after maintenance: ${FINAL_FREE_PCT}% free"
fi

###############################################################################
# DATABASE MAINTENANCE
# Prune old records and clean up backup files
###############################################################################
log "🧹 Running database maintenance"
BEFORE_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM files;")
PRUNED=$(sqlite3 "$DB" "DELETE FROM files WHERE created_at < datetime('now','-6 months'); SELECT changes();")
AFTER_COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM files;")
log "🧹 Database pruned: removed $PRUNED old record(s) (before: $BEFORE_COUNT, after: $AFTER_COUNT)"

# Clean up old database backup and dump files (older than 30 days)
log "🧹 Cleaning up old database backup and dump files"
BACKUP_COUNT=0
find "$(dirname "$DB")" -name "$(basename "$DB").corrupted.*" -o -name "$(basename "$DB").dump" -type f -mtime +30 -print0 | 
while IFS= read -r -d '' OLD_BACKUP; do
  log "🗑️ Removing old database backup: $(basename "$OLD_BACKUP")"
  rm -f "$OLD_BACKUP" && ((BACKUP_COUNT++))
done
[[ $BACKUP_COUNT -gt 0 ]] && log "🧹 Removed $BACKUP_COUNT old database backup/dump files" || log "✅ No old database backups to clean"

###############################################################################
# COMPLETION
# Log final statistics and exit
###############################################################################
DISK_FREE=$(df -h "$ARCHIVE_DIR" | awk 'NR==2 {print $4}')
DISK_USED=$(df -h "$ARCHIVE_DIR" | awk 'NR==2 {print $5}')
log "💽 Archive disk usage: $DISK_USED used, $DISK_FREE available"

log "🌟 Done."