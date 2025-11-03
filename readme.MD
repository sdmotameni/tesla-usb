# Tesla USB Dashcam Archiver

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform: Raspberry Pi](https://img.shields.io/badge/Platform-Raspberry%20Pi-C51A4A.svg)](https://www.raspberrypi.org/)

Transform a Raspberry Pi Zero 2 W into a smart Tesla dashcam storage system that extends Tesla's 1-hour rolling buffer to weeks of footage. Uses LVM snapshots for safe concurrent access while Tesla is actively recording.

---

## Key Features

- **Safe Concurrent Access**: LVM snapshots enable reading files while Tesla writes
- **Automatic Archiving**: Copies new footage every 15 minutes
- **Smart Storage**: Auto-deletes oldest files when space runs low
- **WiFi Management**: Auto-disables after 5 minutes to save power, re-enables on power cycle
- **LED Status**: Visual indicator (ON = WiFi enabled, OFF = WiFi disabled)
- **Simple Control**: `tesla-ctl` command for all operations
- **Robust Recovery**: Never locks you out - power cycle always restores access

---

## What You'll Need

| Item                    | Purpose                                     |
| ----------------------- | ------------------------------------------- |
| Raspberry Pi Zero 2 W   | Acts as USB drive for Tesla                 |
| 1TB microSD card        | Storage for footage (larger = more history) |
| USB cable               | Connect Pi to Tesla                         |
| Computer with SD reader | Initial SD card setup                       |

---

## Installation Guide

### Step 1: Prepare SD Card (10 minutes)

1. **Flash Raspberry Pi OS** using [Raspberry Pi Imager](https://www.raspberrypi.org/software/)

   - Choose: Raspberry Pi OS Lite (64-bit)
   - Configure SSH and WiFi in advanced options
   - Set hostname: `tesla-pi`

2. **Partition the SD card** (on another Linux computer):
   ```bash
   git clone https://github.com/sdmotameni/tesla-usb.git
   cd tesla-usb
   sudo ./scripts/prep_sdcard.sh
   ```
   - Enter your SD card device (e.g., `sdb`)
   - Accept default 32GB for OS
   - Creates space for Tesla storage

### Step 2: Install System (15 minutes)

1. **Boot your Pi** with prepared SD card
2. **SSH into Pi**:

   ```bash
   ssh pi@tesla-pi.local
   ```

3. **Run setup**:

   ```bash
   git clone https://github.com/sdmotameni/tesla-usb.git
   cd tesla-usb
   sudo ./scripts/setup_partitions.sh
   ```

   - When prompted for Tesla USB size: Enter **120** (GB)
   - Remaining space becomes archive storage

4. **Install archiver**:
   ```bash
   sudo ./scripts/setup.sh
   ```

### Step 3: Configure USB Mode (5 minutes)

1. **Enable USB gadget mode**:

   ```bash
   # Add to /boot/firmware/config.txt
   echo "dtoverlay=dwc2" | sudo tee -a /boot/firmware/config.txt

   # Edit /boot/firmware/cmdline.txt
   sudo nano /boot/firmware/cmdline.txt
   # Add after rootwait (keep single line): modules-load=dwc2,g_mass_storage

   # Configure mass storage
   echo "options g_mass_storage file=/dev/tesla_vg/tesla_usb stall=0 removable=1 ro=0" | \
     sudo tee /etc/modprobe.d/g_mass_storage.conf
   ```

2. **Verify installation**:

   ```bash
   sudo ./scripts/verify-install.sh  # Check all components
   ```

3. **Reboot**:

   ```bash
   sudo reboot
   ```

4. **Verify USB storage** (after reboot):
   ```bash
   lsmod | grep g_mass_storage  # Should show module loaded
   tesla-ctl status              # Check system status
   ```

### Step 4: Connect to Tesla

1. **Shutdown Pi**: `sudo shutdown now`
2. **Connect to Tesla's USB port**
3. Tesla will format the drive and create TeslaCam folder
4. Recording starts automatically!

---

## How It Works

### Storage Layout

```
1TB SD Card
├─ 32GB   → Raspberry Pi OS
├─ 120GB  → Tesla USB (FAT32) - What Tesla sees
└─ 848GB  → Archive (ext4) - Long-term storage
```

### Archiving Process

Every 15 minutes:

1. Creates LVM snapshot of Tesla USB volume
2. Copies new footage to archive storage
3. Removes snapshot
4. Deletes old files if storage >90% full

### WiFi Power Management

- **First 5 minutes after boot**: WiFi ON (LED solid) - SSH access available
- **After 5 minutes**: WiFi OFF (LED off) - Saves power, reduces interference
- **Power cycle**: Resets timer, WiFi ON again

This ensures you always have a 5-minute window to access the Pi after plugging it in.

---

## Control Commands

All management through `tesla-ctl`:

| Command                  | Description                             |
| ------------------------ | --------------------------------------- |
| `tesla-ctl status`       | Show system status, storage, WiFi state |
| `tesla-ctl wifi-enable`  | Turn WiFi on manually                   |
| `tesla-ctl wifi-disable` | Turn WiFi off manually                  |
| `tesla-ctl wifi-keep`    | Keep WiFi on permanently (this session) |
| `tesla-ctl logs`         | View recent archive logs                |
| `tesla-ctl archive-now`  | Run archive immediately                 |
| `tesla-ctl help`         | Show all commands                       |

### Examples

**Check system status:**

```bash
tesla-ctl status
# Shows:
# - Uptime and WiFi timeout countdown
# - Storage usage and free space
# - Number of archived videos
# - Service status
```

**Keep WiFi on for maintenance:**

```bash
tesla-ctl wifi-keep  # Disables auto-timeout
# Do your work...
tesla-ctl resume      # Re-enable normal operation
```

---

## LED Status Indicators

The Pi's onboard LED shows WiFi status:

| LED State    | Meaning                      | Action Needed                |
| ------------ | ---------------------------- | ---------------------------- |
| **Solid ON** | WiFi enabled, SSH available  | You can connect              |
| **OFF**      | WiFi disabled (power saving) | Power cycle to regain access |

---

## Troubleshooting

### Cannot SSH to Pi

**Symptom**: `ssh: connect to host tesla-pi.local port 22: Connection refused`

**Solution**:

1. Check LED - if OFF, WiFi is disabled
2. Power cycle the Pi (unplug/replug)
3. Wait 30 seconds for boot
4. SSH within 5 minutes

### Tesla Not Recognizing USB

**Check USB gadget status:**

```bash
# Should show g_mass_storage loaded
lsmod | grep g_mass_storage

# Check device exists
ls -la /dev/tesla_vg/tesla_usb

# View kernel messages
dmesg | grep -i "mass storage"
```

**Fix:**

1. Verify `/boot/firmware/config.txt` has `dtoverlay=dwc2`
2. Verify `/boot/firmware/cmdline.txt` has `modules-load=dwc2,g_mass_storage`
3. Reboot: `sudo reboot`

### Archive Not Running

**Check status:**

```bash
systemctl status teslacam-archive.timer
tesla-ctl logs
```

**Manual test:**

```bash
sudo systemctl start teslacam-archive.service
tesla-ctl logs  # Check for errors
```

### Storage Full

The system auto-manages space, but to check:

```bash
tesla-ctl status
df -h /mnt/tesla_archive
```

To manually free space:

```bash
# Remove oldest videos
find /mnt/tesla_archive -type f -name "*.mp4" -mtime +30 -delete
```

---

## Configuration

Edit `/etc/tesla-usb/tesla-usb.conf` to customize:

```bash
# Core settings (usually don't change)
VG_NAME=tesla_vg              # LVM volume group name
LV_NAME=tesla_usb             # Tesla USB volume name
SNAP_SIZE=3G                  # Snapshot size for archiving
ARCHIVE_DIR=/mnt/tesla_archive # Where archives are stored

# Tunable settings
MIN_DISK_SPACE_PCT=10         # Start deleting when <10% free
MAX_DISK_TEMP=100             # Skip archive if disk >100°C
WIFI_DISABLE_AFTER=300        # WiFi timeout (300s = 5 min)
```

### Common Tweaks

**Keep WiFi on longer:**

```bash
# Edit config
sudo nano /etc/tesla-usb/tesla-usb.conf
# Change to 30 minutes:
WIFI_DISABLE_AFTER=1800

# Restart service
sudo systemctl restart wifi-manager.timer
```

**Disable WiFi management entirely:**

```bash
sudo systemctl stop wifi-manager.timer
sudo systemctl disable wifi-manager.timer
```

---

## Advanced Usage

### Access Archives from Computer

1. **Enable WiFi**: `tesla-ctl wifi-enable`
2. **Copy files via SCP**:
   ```bash
   scp -r pi@tesla-pi.local:/mnt/tesla_archive/SavedClips ./
   ```

### Monitor in Real-Time

```bash
# Watch archiver logs
tesla-ctl logs-live

# Monitor system
watch tesla-ctl status

# Check WiFi manager
sudo journalctl -f -u wifi-manager
```

### Manual Maintenance

```bash
# Force archive run
tesla-ctl archive-now

# Check LVM status
sudo lvs

# See snapshot (if active during archive)
sudo lvdisplay tesla_vg/tesla_snap

# Disk temperature (if smartctl installed)
sudo smartctl -A /dev/mmcblk0 | grep Temperature
```

---

## Technical Details

### Why LVM Snapshots?

Tesla continuously writes to the USB drive. Direct copying while Tesla writes could corrupt files. LVM snapshots create a point-in-time copy that's safe to read from.

### Why Separate Archive Volume?

Storing archives on the root partition can fill the OS disk and crash the system. A dedicated volume prevents this.

### WiFi Management Architecture

- **wifi-unblock.service**: Ensures WiFi starts enabled on every boot
- **wifi-manager.timer**: Checks every minute if WiFi should be disabled
- State stored in RAM (`/run/`) - never persists across reboots
- No `rfkill block` used - prevents persistent WiFi blocking

### File Management

- No database needed - filesystem timestamps determine age
- `rsync --ignore-existing` ensures efficient incremental copies
- Automatic cleanup when storage exceeds threshold

---

## Project Structure

```
tesla-usb/
├── scripts/
│   ├── prep_sdcard.sh      # SD card partitioning (run on computer)
│   ├── setup_partitions.sh  # LVM setup (run on Pi)
│   ├── setup.sh            # Main installer
│   ├── run.sh              # Archive worker script
│   ├── tesla-ctl.sh        # Control utility
│   └── wifi-manager.sh     # WiFi timeout manager
├── config/
│   └── tesla-usb.conf      # System configuration
└── etc/systemd/
    └── system/             # Service definitions
```

---

## Contributing

Contributions welcome! Please test changes thoroughly as this system runs unattended in vehicles.

### Testing Checklist

- [ ] Archives run successfully
- [ ] WiFi disables after timeout
- [ ] Power cycle restores WiFi
- [ ] Tesla recognizes USB drive
- [ ] No storage leaks over time

---

## License

MIT License - see [LICENSE](LICENSE) file for details.

---

## Support

For issues or questions:

1. Check [Troubleshooting](#troubleshooting) section
2. Review logs: `tesla-ctl logs`
3. Open an issue with log output

---

## Acknowledgments

- Tesla for the amazing dashcam feature
- Raspberry Pi Foundation for excellent hardware
- Linux LVM2 project for robust snapshot capabilities
