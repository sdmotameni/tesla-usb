#!/usr/bin/env bash
###############################################################################
# Emergency WiFi Fix - Run this to recover from rfkill issues
###############################################################################

echo "==================================="
echo "Emergency WiFi Recovery"
echo "==================================="
echo

# Unblock everything
echo "Unblocking all rfkill blocks..."
rfkill unblock all
rfkill unblock wifi
rfkill unblock 0
rfkill unblock 1
rfkill unblock 2

# Restart services
echo "Restarting WiFi services..."
systemctl restart wpa_supplicant
systemctl restart dhcpcd

# Bring interface up
echo "Bringing wlan0 up..."
ip link set wlan0 up

# Wait for connection
echo "Waiting for connection..."
sleep 5

# Check status
if ip addr show wlan0 | grep -q "inet "; then
    echo "✓ WiFi is working!"
    ip addr show wlan0 | grep "inet "
else
    echo "✗ WiFi not connected yet. Try:"
    echo "  sudo wpa_cli -i wlan0 reconfigure"
    echo "  sudo dhcpcd -n wlan0"
fi

echo
echo "==================================="
echo "To prevent future lockouts:"
echo "The system now uses service stop/start"
echo "instead of rfkill block."
echo "==================================="
