#!/usr/bin/env bash
#
# Tesla USB Dashcam Archiver – Wi-Fi Auto-Disable Setup
# 1. Wi-Fi always starts ENABLED at boot
# 2. X minutes later it is soft-blocked (unless /boot/keep_wifi.txt exists)
# 3. Power-cycle → grace window opens again
#
# Changelog 2025-05-22
#   • enable timer *without* --now  → no chance of killing SSH mid-install
#   • numeric validation of delay
#   • graceful fallback if NetworkManager isn’t installed
#   • optional auto-creation of /boot/keep_wifi.txt (after remount RW)
#   • use daemon-reload instead of daemon-reexec
# ---------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# ── coloured log helpers ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YEL='\033[0;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YEL}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -eq 0 ]] || { log_error "Run as root (sudo)"; exit 1; }

# ── banner ─────────────────────────────────────────────────────────────────
clear
cat <<'BANNER'
==========================================================
 Tesla USB Dashcam Archiver – Wi-Fi Auto-Disable Setup
----------------------------------------------------------
 • At boot : Wi-Fi is ON so you can SSH in.
 • Later   : Wi-Fi turns OFF to save power/RF.
 • Recover : Power-cycle, then stop the timer inside window.
==========================================================
BANNER

read -rp "Continue with installation? (y/N) " -n1 REPLY; echo
[[ $REPLY =~ ^[Yy]$ ]] || { log_info "Cancelled."; exit 0; }

# ── get delay ──────────────────────────────────────────────────────────────
read -rp "Delay before disabling Wi-Fi (minutes) [15]: " DELAY_MIN; echo
DELAY_MIN=${DELAY_MIN:-15}
[[ $DELAY_MIN =~ ^[0-9]+$ ]] || { log_error "Delay must be a positive integer"; exit 1; }

# ── install helper script ──────────────────────────────────────────────────
log_info "Creating /usr/local/bin/disable_wifi.sh"
cat > /usr/local/bin/disable_wifi.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -f /boot/keep_wifi.txt ]; then
  echo "[disable_wifi] Guard file found – skipping" | systemd-cat -t disable_wifi
  exit 0
fi
echo "[disable_wifi] Blocking Wi-Fi" | systemd-cat -t disable_wifi
if command -v nmcli >/dev/null; then
  nmcli radio wifi off || true
fi
rfkill block wifi || true
EOF
chmod +x /usr/local/bin/disable_wifi.sh

# ── systemd units ──────────────────────────────────────────────────────────
log_info "Creating disable-wifi.service"
cat > /etc/systemd/system/disable-wifi.service <<'EOF'
[Unit]
Description=Disable Wi-Fi after boot delay
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disable_wifi.sh
EOF

log_info "Creating disable-wifi.timer (${DELAY_MIN} min)"
cat > /etc/systemd/system/disable-wifi.timer <<EOF
[Unit]
Description=Disable Wi-Fi ${DELAY_MIN} minutes after boot

[Timer]
OnBootSec=${DELAY_MIN}min
AccuracySec=1s
Unit=disable-wifi.service

[Install]
WantedBy=timers.target
EOF

# ── ask about guard file BEFORE enabling the timer ─────────────────────────
read -rp "Create /boot/keep_wifi.txt now to KEEP Wi-Fi on? (Y/n): " -n1 GUARD; echo
if [[ ! $GUARD =~ ^[Nn]$ ]]; then
  log_info "Creating guard file /boot/keep_wifi.txt"
  mountpoint -q /boot || true
  if ! touch /boot/keep_wifi.txt 2>/dev/null; then
    log_warn "/boot is read-only; remounting rw temporarily"
    mount -o remount,rw /boot
    touch /boot/keep_wifi.txt
    mount -o remount,ro /boot
  fi
else
  log_info "You can create /boot/keep_wifi.txt later if needed."
fi

# ── enable (but DO NOT start) the timer ────────────────────────────────────
log_info "Enabling timer (will start on next boot)…"
systemctl daemon-reload
systemctl enable disable-wifi.timer   # no --now ⇒ safe during install

# ── summary ────────────────────────────────────────────────────────────────
cat <<EOF

==========================================================
 Setup finished.
 • Wi-Fi will disable ${DELAY_MIN} min after each boot
   unless /boot/keep_wifi.txt exists.
 • Grace window always opens on a power-cycle.

 Common commands
 ──────────────────────────────────────────────────────────
  ▸ Cancel feature permanently
      sudo systemctl disable --now disable-wifi.timer

  ▸ Keep Wi-Fi up THIS session
      sudo rfkill unblock wifi   (or nmcli radio wifi on)

  ▸ Keep Wi-Fi up EVERY boot
      sudo touch /boot/keep_wifi.txt
==========================================================
EOF
