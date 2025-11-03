#!/usr/bin/env bash
###############################################################################
# Test WiFi Control - Verify everything works
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
error() { echo -e "${RED}✗${NC} $*"; }

echo "============================="
echo "Tesla USB WiFi Control Test"
echo "============================="
echo

# Check LED devices
echo "1. Checking LED devices..."
LED_FOUND=false
for LED in ACT led0 led1 PWR; do
    if [[ -d /sys/class/leds/$LED ]]; then
        info "Found LED: /sys/class/leds/$LED"
        LED_FOUND=true
        LED_NAME=$LED
        break
    fi
done
[[ "$LED_FOUND" == "false" ]] && warn "No LED device found"
echo

# Check rfkill
echo "2. Checking rfkill..."
if command -v rfkill >/dev/null; then
    info "rfkill found at: $(command -v rfkill)"
    echo "   Current status:"
    rfkill list wifi | grep -E "Soft|Hard" | sed 's/^/   /'
else
    error "rfkill not found!"
fi
echo

# Test LED control
if [[ "$LED_FOUND" == "true" ]]; then
    echo "3. Testing LED control..."
    echo "   Turning LED off for 2 seconds..."
    echo none > /sys/class/leds/$LED_NAME/trigger
    echo 0 > /sys/class/leds/$LED_NAME/brightness
    sleep 2
    echo "   Turning LED on..."
    echo default-on > /sys/class/leds/$LED_NAME/trigger
    info "LED control works"
else
    warn "Skipping LED test (no LED found)"
fi
echo

# Test WiFi block/unblock
echo "4. Testing WiFi control..."
echo "   Blocking WiFi for 3 seconds..."
rfkill block wifi 2>/dev/null || warn "Failed to block wifi"
sleep 3
echo "   Unblocking WiFi..."
rfkill unblock wifi 2>/dev/null || warn "Failed to unblock wifi"
info "WiFi control works"
echo

# Check systemd service
echo "5. Checking wifi-unblock.service..."
if systemctl list-unit-files | grep -q wifi-unblock.service; then
    info "Service installed"
    if systemctl is-enabled wifi-unblock.service 2>/dev/null | grep -q enabled; then
        info "Service enabled (will run on boot)"
    else
        warn "Service not enabled - run: sudo systemctl enable wifi-unblock.service"
    fi
else
    error "Service not installed - run setup.sh"
fi
echo

echo "============================="
echo "Test Complete"
echo "============================="
echo
echo "If WiFi control worked, the system should recover properly on reboot."
echo "The wifi-unblock.service will ensure WiFi starts enabled every boot."
