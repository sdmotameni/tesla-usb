#!/usr/bin/env bash
###############################################################################
# Verify Installation - Check that all components are properly installed
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

success() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*"; }

echo "========================================"
echo "  Tesla USB Installation Verification"
echo "========================================"
echo

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    warn "Running as root"
else
    fail "Not running as root - some checks may fail"
fi

# Check LVM volumes
echo "Checking LVM volumes..."
if lvs tesla_vg/tesla_usb &>/dev/null; then
    success "tesla_usb volume exists"
else
    fail "tesla_usb volume missing"
fi

if lvs tesla_vg/tesla_archive &>/dev/null; then
    success "tesla_archive volume exists"
else
    fail "tesla_archive volume missing"
fi

# Check mount points
echo -e "\nChecking mount points..."
if mountpoint -q /mnt/tesla_archive; then
    success "/mnt/tesla_archive is mounted"
else
    fail "/mnt/tesla_archive not mounted"
fi

# Check USB gadget mode
echo -e "\nChecking USB gadget mode..."
if lsmod | grep -q g_mass_storage; then
    success "g_mass_storage module loaded"
else
    warn "g_mass_storage not loaded (normal if not rebooted yet)"
fi

# Check configuration files
echo -e "\nChecking configuration..."
if [[ -f /etc/tesla-usb/tesla-usb.conf ]]; then
    success "Configuration file exists"
else
    fail "Configuration file missing"
fi

if [[ -f /etc/modprobe.d/g_mass_storage.conf ]]; then
    success "USB gadget config exists"
else
    warn "USB gadget config missing"
fi

# Check scripts
echo -e "\nChecking scripts..."
if [[ -x /usr/local/bin/tesla-usb-archive.sh ]]; then
    success "Archive script installed"
else
    fail "Archive script missing"
fi

if [[ -x /usr/local/bin/tesla-ctl ]]; then
    success "Control script installed"
else
    fail "Control script missing"
fi

if [[ -x /usr/local/bin/wifi-manager.sh ]]; then
    success "WiFi manager installed"
else
    fail "WiFi manager missing"
fi

# Check systemd services
echo -e "\nChecking systemd services..."
for service in wifi-unblock wifi-manager teslacam-archive; do
    if systemctl list-unit-files | grep -q "${service}"; then
        success "${service} service installed"
        
        # Check if enabled
        if systemctl is-enabled "${service}.service" &>/dev/null || \
           systemctl is-enabled "${service}.timer" &>/dev/null; then
            success "  └─ enabled"
        else
            warn "  └─ not enabled"
        fi
        
        # Check if active
        if systemctl is-active "${service}.service" &>/dev/null || \
           systemctl is-active "${service}.timer" &>/dev/null; then
            success "  └─ active"
        else
            warn "  └─ not active"
        fi
    else
        fail "${service} service missing"
    fi
done

# Check WiFi status
echo -e "\nChecking WiFi status..."
if ip link show wlan0 2>/dev/null | grep -q "state UP"; then
    success "WiFi is UP"
    UPTIME=$(awk '{print int($1)}' /proc/uptime)
    TIMEOUT=${WIFI_DISABLE_AFTER:-300}
    REMAINING=$((TIMEOUT - UPTIME))
    if [[ $REMAINING -gt 0 ]]; then
        warn "WiFi will disable in ${REMAINING} seconds"
    else
        warn "WiFi should be disabled (uptime > ${TIMEOUT}s)"
    fi
else
    warn "WiFi is DOWN"
fi

# Check LED
echo -e "\nChecking LED status..."
for LED in ACT led0 led1 PWR; do
    if [[ -d /sys/class/leds/$LED ]]; then
        TRIGGER=$(cat /sys/class/leds/$LED/trigger 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')
        if [[ "$TRIGGER" == "default-on" ]]; then
            success "LED is ON (WiFi enabled indicator)"
        elif [[ "$TRIGGER" == "none" ]]; then
            success "LED is OFF (WiFi disabled indicator)"
        else
            warn "LED trigger: $TRIGGER"
        fi
        break
    fi
done

# Check boot config
echo -e "\nChecking boot configuration..."
if grep -q "dtoverlay=dwc2" /boot/firmware/config.txt 2>/dev/null; then
    success "dwc2 overlay configured"
else
    fail "dwc2 overlay not in config.txt"
fi

if grep -q "modules-load=dwc2,g_mass_storage" /boot/firmware/cmdline.txt 2>/dev/null; then
    success "USB gadget modules configured"
else
    warn "USB gadget modules not in cmdline.txt"
fi

# Summary
echo -e "\n========================================"
echo "  Summary"
echo "========================================"

if command -v tesla-ctl &>/dev/null; then
    echo -e "\nRun 'tesla-ctl status' for current status"
fi

echo -e "\nNext steps:"
echo "1. If USB gadget not configured: Follow Step 3 in README"
echo "2. Reboot: sudo reboot"
echo "3. Verify: tesla-ctl status"
echo "4. Connect to Tesla!"
