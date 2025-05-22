# Tesla USB Dashcam Archiver on Raspberry Pi

This project transforms a Raspberry Pi Zero 2 W (or any Raspberry Pi) into an offline Tesla USB Dashcam video archiving system using a single SD card and LVM snapshots. It captures and preserves TeslaCam footage without interrupting Tesla's writing process, and manages disk space intelligently with SQLite tracking.

---

## Project Objectives

- Safely read Tesla USB partition while Tesla is actively writing
- Implement low-level Linux technologies: LVM, snapshots, filesystems, bash scripting
- Store TeslaCam video files on local SD storage
- Automatically manage storage through deletion of oldest files when disk capacity is reached
- Maintain file history and metadata in a local SQLite database
- Automate execution via `systemd` timer
- Implement robust recovery mechanisms for unexpected system shutdowns

---

## System Requirements

| Item                  | Notes                                                          |
| --------------------- | -------------------------------------------------------------- |
| Raspberry Pi Zero 2 W | Any Pi model is compatible; Pi 4/5 offers improved performance |
| 1TB microSD card      | Recommended for adequate storage capacity                      |
| Raspberry Pi OS Lite  | Headless configuration (GUI not required)                      |
| USB OTG cable         | Optional (for direct Tesla USB connection)                     |
| smartctl (optional)   | Required for disk temperature monitoring                       |

---

## Architecture Overview

```
[ Tesla USB Partition (FAT32) ]
            |
       [ LVM Snapshot ]
            ↓
    /mnt/tesla_snap (ro)
            ↓
  Copy new files → /home/pi/tesla-archive/TeslaCam/
            ↓
Update file index → SQLite DB (.file_index.sqlite)
            ↓
When disk space <10% → Delete oldest files
```

---

## USB Emulation (Mass Storage Gadget)

To allow the Raspberry Pi Zero 2 W to emulate a USB drive for Tesla, configure the Pi in USB OTG mode using the g_mass_storage kernel module.

### 1. Edit /boot/firmware/config.txt

Append the following lines:

```ini
dtoverlay=dwc2
```

### 2. Edit /boot/firmware/cmdline.txt

Find the single long line (don't add line breaks). Add `modules-load=dwc2,g_mass_storage` after `rootwait`, like this:

```txt
... rootwait modules-load=dwc2,g_mass_storage ...
```

❗ Make sure you keep it as a single line. Don't add newlines to this file.

### 3. Configure Mass Storage Device

Create the file `/etc/modprobe.d/g_mass_storage.conf` and add the following content to point to your Tesla USB volume (the FAT32 logical volume we created):

```bash
options g_mass_storage file=/dev/tesla_vg/tesla_usb stall=0 removable=1 ro=0
```

This tells the Pi to present the LVM volume `/dev/tesla_vg/tesla_usb` as a USB drive to the Tesla.

### 4. Reboot

```bash
sudo reboot
```

After reboot, the Tesla should recognize the Pi as a USB device and start writing footage to it. Your script will periodically take snapshots and safely archive the contents.

---

## Initial Configuration

### 1. Flash Raspberry Pi OS

Use Raspberry Pi Imager to flash Raspberry Pi OS Lite to the microSD card.

### 2. Resize Partitions

Using `gparted` or `parted`:

- Shrink root partition to approximately 32 GB
- Create 128 GB FAT32 partition for Tesla USB
- Leave remaining space unallocated for LVM

### 3. Set Up LVM on Raspberry Pi

```bash
sudo apt update
sudo apt install lvm2
sudo pvcreate /dev/mmcblk0p3
sudo vgcreate tesla_vg /dev/mmcblk0p3
sudo lvcreate -L 120G -n tesla_usb tesla_vg
sudo mkfs.vfat /dev/tesla_vg/tesla_usb
sudo mkdir /mnt/tesla_init
sudo mount /dev/tesla_vg/tesla_usb /mnt/tesla_init
sudo mkdir -p /mnt/tesla_init/TeslaCam
sudo umount /mnt/tesla_init
```

---

## Script Deployment

### 1. Install the Archiver Script

```bash
sudo nano /usr/local/bin/run.sh
```

Paste the script content and set execution permissions:

```bash
sudo chmod +x /usr/local/bin/run.sh
```

### 2. Configure systemd Service

Create the service definition in `/etc/systemd/system/teslacam-archive.service`:

```ini
[Unit]
Description=TeslaCam Snapshot & Archive Script
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/run.sh
TimeoutSec=3600
Nice=10
IOSchedulingClass=2
IOSchedulingPriority=7
StandardOutput=append:/home/pi/tesla-archive/tesla_archive.log
StandardError=inherit

[Install]
WantedBy=multi-user.target
```

Enable the service:

```bash
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable teslacam-archive.service
```

### 3. Optional Timer Configuration

Create a timer definition in `/etc/systemd/system/teslacam-archive.timer`:

```ini
[Unit]
Description=Run TeslaCam Archive Script Periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Unit=teslacam-archive.service

[Install]
WantedBy=timers.target
```

Enable the timer:

```bash
sudo systemctl enable --now teslacam-archive.timer
```

**Note**: The `OnUnitActiveSec=15min` parameter can be modified to adjust execution frequency.

---

## File Structure

```
/home/pi/tesla-archive/
├── TeslaCam/                  ← Archived footage
├── .file_index.sqlite         ← SQLite DB tracking processed files
└── tesla_archive.log          ← Operation logs (auto-truncated at 1GB)
```

---

## Technical Features

### System Safety Mechanisms

- **Disk Temperature Monitoring**: Execution is skipped when disk temperature exceeds 100°C
- **Recovery Safeguards**: Automatic detection and cleanup of stale snapshots
- **Database Integrity**: SQLite integrity verification with automatic corruption repair
- **Lock Management**: Process serialization via flock to prevent concurrent execution

### Database Performance Optimization

- Transaction batching for SQLite operations
- Performance optimization when processing large file volumes
- Configurable batch size (default: 50 files per transaction)

### Log Management

- Automatic log rotation when file exceeds 1GB
- Retention of most recent 10,000 log entries
- Prevention of unlimited log growth

### Storage Management

- Volume utilization monitoring after each archive operation
- Automatic deletion of oldest videos when free space falls below 10% threshold
- Age-based file deletion using SQLite `created_at` timestamp
- Database maintenance to remove records older than 6 months
- Cleanup of database backup files older than 30 days

---

## Testing and Diagnostics

Manually initiate an archive operation:

```bash
sudo systemctl start teslacam-archive.service
```

Monitor operation logs:

```bash
tail -f /home/pi/tesla-archive/tesla_archive.log
```

Inspect the database:

```bash
sqlite3 /home/pi/tesla-archive/.file_index.sqlite \
"SELECT path, created_at FROM files ORDER BY created_at ASC;"
```

---

## Implementation Concepts

- **LVM Snapshots**: Secure access to Tesla USB content while mounted by Tesla
- **SQLite**: Efficient file tracking with transaction batching
- **Filesystem I/O Optimization**: rsync with --inplace, readonly mounts, ionice
- **Process Management**: systemd services and flock for reliable execution
- **Storage Monitoring**: Automatic content pruning and health verification
- **Log Rotation**: Prevention of log file growth beyond defined limits
- **Fault Recovery**: Handling of power loss and unexpected system terminations

---

## Extension Opportunities

- Addition of USB SSD for expanded storage capacity
- Implementation of web-based footage viewer
- Video thumbnail generation
- Event-based trigger mechanisms
- Customizable retention policies by event type

---

## Security & Power Optimization

### WiFi Auto-Disable

This configuration enhances security and reduces power consumption by automatically disabling WiFi after boot.

#### Summary

- At boot: Wi-Fi is enabled so you can access the Pi if needed.
- After 15 minutes: A script runs (via systemd timer) and disables Wi-Fi.
- To re-enable access: Physically power cycle the Pi and SSH in before the script runs.

#### Implementation

1. **Create the Wi-Fi Disabling Script**

```bash
#!/bin/bash
# /usr/local/bin/disable_wifi.sh

echo "[INFO] Disabling Wi-Fi..." | systemd-cat -t disable_wifi
nmcli radio wifi off 2>/dev/null || rfkill block wifi
```

Make it executable:

```bash
sudo chmod +x /usr/local/bin/disable_wifi.sh
```

2. **Set up a systemd Timer**

Create the service:

```ini
# /etc/systemd/system/disable-wifi.service
[Unit]
Description=Disable Wi-Fi after boot delay

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable_wifi.sh
```

Create the timer:

```ini
# /etc/systemd/system/disable-wifi.timer
[Unit]
Description=Run disable-wifi.service 15 minutes after boot

[Timer]
OnBootSec=15min
AccuracySec=1s
Unit=disable-wifi.service

[Install]
WantedBy=timers.target
```

Enable the timer:

```bash
sudo systemctl daemon-reexec
sudo systemctl enable --now disable-wifi.timer
```

#### Recovery Access

When you need to access the Pi:

1. Power-cycle the Pi
2. SSH in during the 15-minute window
3. Disable the auto-shutdown timer:

```bash
sudo systemctl stop disable-wifi.timer
sudo systemctl disable disable-wifi.timer
```

This configuration maintains g_mass_storage functionality while minimizing power usage and attack surface.

---

## Technical Notes

- Designed for reliability with zero interruption to Tesla operations
- Performance optimizations for resource-constrained hardware
- Fully automated maintenance requiring no manual intervention
- Maximized footage retention within storage constraints
- Comprehensive recovery mechanisms for system interruption scenarios

---

# tesla-usb

# tesla-usb
