# Tesla USB Dashcam Archiver

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform: Raspberry Pi](https://img.shields.io/badge/Platform-Raspberry%20Pi-C51A4A.svg)](https://www.raspberrypi.org/)

Transform a Raspberry Pi Zero 2 W into an offline Tesla dashcam archiving system. Extends Tesla's 1-hour rolling buffer to days or weeks of footage using LVM snapshots for safe concurrent access.

---

## Features

- **Safe Concurrent Access**: LVM snapshots allow reading while Tesla writes
- **Automatic Archiving**: Runs every 15 minutes via systemd timer
- **Smart Storage Management**: Auto-deletes oldest files when space is low
- **WiFi Auto-Disable**: Saves power after 5 minutes, re-enables on power cycle
- **LED Indicators**: Visual wifi status (ON=enabled, OFF=disabled)
- **Simple Control API**: Manage system with `tesla-ctl` command
- **Crash Recovery**: Automatic cleanup of interrupted runs
- **Temperature Monitoring**: Skips archiving if disk too hot

---

## Requirements

| Item                  | Notes                                                |
| --------------------- | ---------------------------------------------------- |
| Raspberry Pi Zero 2 W | Any Pi model works; Pi 4/5 offers better performance |
| 1TB microSD card      | Larger = more footage history                        |
| Raspberry Pi OS Lite  | Headless configuration                               |
| USB OTG cable         | Optional, for Pi Zero direct connection              |

---

## Quick Start

### 1. Prepare SD Card

**Flash Raspberry Pi OS to SD card, then:**

On another Linux computer (or Pi 5):

```bash
git clone https://github.com/yourusername/tesla-usb.git
cd tesla-usb
sudo ./scripts/prep_sdcard.sh
```

This shrinks the OS partition and creates space for LVM.

### 2. Boot Pi and Install

**Insert SD card into Pi Zero 2, boot, then SSH in:**

```bash
ssh pi@tesla-pi.local
```

**Install the archiver:**

```bash
git clone https://github.com/yourusername/tesla-usb.git
cd tesla-usb
sudo ./scripts/setup_partitions.sh  # Creates LVM volumes
sudo ./scripts/setup.sh              # Installs archiver
```

When prompted for Tesla USB volume size, use **128GB** (remaining space becomes archive storage).

### 3. Configure USB Gadget Mode (Pi Zero Only)

**Edit `/boot/firmware/config.txt`:**

```bash
sudo nano /boot/firmware/config.txt
```

Add at end:

```
dtoverlay=dwc2
```

**Edit `/boot/firmware/cmdline.txt`:**

```bash
sudo nano /boot/firmware/cmdline.txt
```

Add after `rootwait` (keep as one line):

```
modules-load=dwc2,g_mass_storage
```

**Create `/etc/modprobe.d/g_mass_storage.conf`:**

```bash
sudo nano /etc/modprobe.d/g_mass_storage.conf
```

```
options g_mass_storage file=/dev/tesla_vg/tesla_usb stall=0 removable=1 ro=0
```

**Reboot:**

```bash
sudo reboot
```

### 4. Plug Into Tesla

Connect Pi Zero 2 to Tesla's USB port. Tesla will recognize it as a USB drive and start recording.

---

## Storage Architecture

```
/dev/mmcblk0 (1TB SD card)
├─ mmcblk0p1 (512MB)      → /boot
├─ mmcblk0p2 (32GB)       → / (OS only)
└─ mmcblk0p3 (925GB LVM)
   ├─ tesla_usb (128GB FAT32)     → Tesla writes here
   └─ tesla_archive (787GB ext4)  → Archives stored at /mnt/tesla_archive
```

**Workflow:**

1. Tesla writes footage to `tesla_usb` (FAT32)
2. Every 15 min: LVM snapshot created, new files copied to `tesla_archive`
3. When archive >90% full: Delete oldest files
4. Root partition stays clean (prevents system crashes)

---

## LED Indicators

| LED State      | Meaning                        |
| -------------- | ------------------------------ |
| **ON** (solid) | WiFi enabled - SSH available   |
| **OFF**        | WiFi disabled - archiving mode |

- WiFi auto-disables **5 minutes** after boot
- Power cycle resets the timer
- Check remaining time: `tesla-ctl status`

---

## Control Commands

Use `tesla-ctl` to manage the system:

```bash
tesla-ctl status        # Show uptime, wifi state, storage, file count
tesla-ctl wifi-enable   # Enable WiFi + turn on LED
tesla-ctl wifi-disable  # Disable WiFi + turn off LED
tesla-ctl wifi-keep     # Keep WiFi on permanently (stops auto-disable)
tesla-ctl resume        # Resume normal operation
tesla-ctl logs          # Show last 50 log entries
tesla-ctl logs-live     # Follow logs in real-time
tesla-ctl archive-now   # Run archive job immediately
tesla-ctl help          # Show all commands
```

---

## Configuration

Edit `/etc/tesla-usb/tesla-usb.conf`:

```bash
VG_NAME=tesla_vg              # LVM volume group
LV_NAME=tesla_usb             # Tesla USB volume
SNAP_SIZE=3G                  # Snapshot size
ARCHIVE_DIR=/mnt/tesla_archive
MIN_DISK_SPACE_PCT=10         # Free space threshold
MAX_DISK_TEMP=100             # Temperature limit (°C)
WIFI_DISABLE_AFTER=300        # WiFi timeout (seconds)
```

---

## Monitoring

**View logs:**

```bash
tesla-ctl logs
# Or
tail -f /mnt/tesla_archive/archive.log
```

**Check storage:**

```bash
tesla-ctl status
# Or
df -h /mnt/tesla_archive
```

**Manual archive run:**

```bash
sudo systemctl start teslacam-archive.service
```

---

## Troubleshooting

### Can't SSH into Pi

- Check LED: OFF = WiFi disabled
- Solution: Power cycle (unplug/replug) for fresh 5-min window
- Or: `tesla-ctl wifi-enable` if you can connect

### Archive not working

```bash
# Check service status
sudo systemctl status teslacam-archive.timer
sudo systemctl status teslacam-archive.service

# View logs
tesla-ctl logs

# Manual test
sudo systemctl start teslacam-archive.service
```

### Disk full

System auto-deletes oldest files when <10% free. Check:

```bash
tesla-ctl status
df -h /mnt/tesla_archive
```

### Tesla not recognizing USB

- Verify USB gadget config in `/boot/firmware/config.txt` and `/boot/firmware/cmdline.txt`
- Check: `ls /dev/tesla_vg/tesla_usb` (should exist)
- Reboot Pi

---

## Advanced

### Change WiFi Timeout

Edit config:

```bash
sudo nano /etc/tesla-usb/tesla-usb.conf
# Change WIFI_DISABLE_AFTER=300 to desired seconds
```

### Disable WiFi Auto-Disable

```bash
tesla-ctl wifi-keep
sudo systemctl stop teslacam-archive.timer
```

### Re-enable Auto-Disable

```bash
tesla-ctl resume
```

---

## Technical Details

- **Snapshot mechanism**: LVM copy-on-write snapshots ensure safe reads while Tesla writes
- **Filesystem**: FAT32 for Tesla compatibility, ext4 for archive efficiency
- **Sync method**: `rsync --ignore-existing` for incremental copying
- **Space management**: Filesystem timestamps determine oldest files (no database)
- **Recovery**: Automatic stale snapshot cleanup on boot
- **Logging**: Auto-rotates daily, keeps 7 days

---

## License

MIT License - see [LICENSE](LICENSE) file for details.

---

## Contributing

Contributions welcome! Please open an issue or pull request.
