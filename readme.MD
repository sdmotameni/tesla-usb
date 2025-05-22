# Tesla USB Dashcam Archiver

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform: Raspberry Pi](https://img.shields.io/badge/Platform-Raspberry%20Pi-C51A4A.svg)](https://www.raspberrypi.org/)

This project transforms a Raspberry Pi Zero 2 W (or any Raspberry Pi) into an offline Tesla USB Dashcam video archiving system using a single SD card and LVM snapshots. It captures and preserves TeslaCam footage without interrupting Tesla's writing process, and manages disk space intelligently with SQLite tracking.

## Project Objectives

- Safely read Tesla USB partition while Tesla is actively writing
- Implement low-level Linux technologies: LVM, snapshots, filesystems, bash scripting
- Store TeslaCam video files on local SD storage
- Automatically manage storage through deletion of oldest files when disk capacity is reached
- Maintain file history and metadata in a local SQLite database
- Automate execution via `systemd` timer
- Implement robust recovery mechanisms for unexpected system shutdowns

## System Requirements

| Item                  | Notes                                                          |
| --------------------- | -------------------------------------------------------------- |
| Raspberry Pi Zero 2 W | Any Pi model is compatible; Pi 4/5 offers improved performance |
| 1TB microSD card      | Recommended for adequate storage capacity                      |
| Raspberry Pi OS Lite  | Headless configuration (GUI not required)                      |
| USB OTG cable         | Optional (for direct Tesla USB connection)                     |
| smartctl (optional)   | Required for disk temperature monitoring                       |

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/yourusername/tesla-usb.git
cd tesla-usb
```

### 2. Partition Your SD Card

Either:

- **Automated approach**: Run the partitioning script: `sudo ./scripts/setup_partitions.sh`
- **Manual approach**: Follow the instructions in the [Detailed Setup Guide](#detailed-setup-guide) section

### 3. Run the Installer

```bash
sudo ./scripts/install.sh
```

The installer will:

- Install required dependencies
- Set up configuration files
- Configure systemd services
- Guide you through customization options

### 4. Configure USB Mass Storage Gadget (if using Pi Zero)

Follow the USB emulation instructions in the [USB Emulation](#usb-emulation-mass-storage-gadget) section.

## Project Structure

```
tesla-usb/
├── config/               - Configuration files
│   └── tesla-usb.conf    - Default configuration
├── docs/                 - Documentation
├── etc/                  - System files
│   ├── teslacam-archive.service  - Systemd service
│   └── teslacam-archive.timer    - Systemd timer
├── scripts/              - Executable scripts
│   ├── install.sh        - Installation script
│   └── run.sh            - Main archiving script
├── CONTRIBUTING.md       - Contribution guidelines
├── LICENSE               - MIT License
└── README.md             - This file
```

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

## Detailed Setup Guide

This section provides manual instructions for those who want to understand the underlying process or need to customize the setup beyond what the automated scripts provide.

### 1. Flash Raspberry Pi OS

Use Raspberry Pi Imager to flash Raspberry Pi OS Lite to the microSD card.

### 2. Create Partition Layout

Using `gparted` or `parted` on your Linux machine:

- Create a 128 GB FAT32 partition for Tesla USB functionality
- Create an additional partition with the remaining space for LVM storage

> **Important:** When creating logical volumes, always make them about 5% smaller than their parent physical partition. For example, if you want a 120GB logical volume, the partition should be at least 128GB. This is necessary because:
>
> 1. LVM requires space for metadata storage
> 2. Snapshots (which this project uses extensively) need extra space to track changes
> 3. Having some free extents in the volume group provides flexibility for future growth
> 4. It prevents performance degradation that can occur when a volume group is 100% allocated

### 3. Set Up LVM on Raspberry Pi

```bash
sudo apt update
sudo apt install lvm2

# Make sure the partition is unmounted before creating physical volume
sudo umount /dev/mmcblk0p3 2>/dev/null || true

# Create LVM physical volume and volume group
sudo pvcreate /dev/mmcblk0p3
sudo vgcreate tesla_vg /dev/mmcblk0p3

# Create logical volume (note: 120G is ~5% smaller than the 128GB partition)
sudo lvcreate -L 120G -n tesla_usb tesla_vg
sudo mkfs.vfat /dev/tesla_vg/tesla_usb

# Initialize the TeslaCam directory
sudo mkdir -p /mnt/tesla_init
sudo mount /dev/tesla_vg/tesla_usb /mnt/tesla_init
sudo mkdir -p /mnt/tesla_init/TeslaCam
sudo umount /mnt/tesla_init
```

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

## Configuration

The default configuration is in `config/tesla-usb.conf`. You can customize it during installation or by editing the file at `/etc/tesla-usb/tesla-usb.conf` after installation.

Key configuration options:

```bash
# LVM Configuration
VG_NAME=tesla_vg         # Volume group name
LV_NAME=tesla_usb        # Logical volume name
SNAP_NAME=tesla_snap     # Snapshot name
SNAP_SIZE=3G             # Snapshot size

# Archive Configuration
ARCHIVE_DIR=/home/pi/tesla-archive  # Where to store archived footage
MIN_DISK_SPACE_PCT=10    # Min free space before cleanup
```

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

## Security & Power Optimization

See the detailed WiFi Auto-Disable instructions in the [original documentation section](#security--power-optimization).

## Technical Features

- **Disk Temperature Monitoring**: Execution is skipped when disk temperature exceeds 100°C
- **Recovery Safeguards**: Automatic detection and cleanup of stale snapshots
- **Database Integrity**: SQLite integrity verification with automatic corruption repair
- **Lock Management**: Process serialization via flock to prevent concurrent execution
- **Transaction batching**: Performance optimization for SQLite operations
- **Automatic log rotation**: When file exceeds 1GB
- **Storage Management**: Automatic deletion of oldest videos when free space falls below threshold

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
