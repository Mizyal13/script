#!/usr/bin/env bash
# ======================================================================
# Disk recovery + cleanup for Ubuntu servers hitting
# "No space left on device" (ENOSPC) during installs/deploys.
#
#   curl -fsSL https://raw.githubusercontent.com/Mizyal13/script/main/cleanup.sh | sudo bash
#
# Safe defaults: clears apt state, old kernels, journals, logs, /tmp,
# snap retention. Docker prune only runs if DOCKER_PRUNE=1 is set
# (it can remove containers/images - opt in on purpose).
# ======================================================================
set -euo pipefail

C() { echo; echo "==> $*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root:  sudo bash cleanup.sh"; exit 1; }

C "Before"
df -h / || true
df -i / || true

C "Clearing broken apt state + package cache"
rm -rf /var/lib/apt/lists/partial/*
apt-get clean || true
rm -rf /var/lib/apt/lists/* || true

C "Removing old kernels + orphaned packages"
apt-get -y autoremove --purge || true

C "Vacuuming systemd journals"
journalctl --vacuum-size=50M 2>/dev/null || true

C "Rotating/truncating large log files (>=100M, skips journal dir)"
find /var/log -maxdepth 2 -type f -size +100M \
     ! -path "/var/log/journal*" -exec truncate -s 0 {} \; 2>/dev/null || true
find /var/log -maxdepth 2 -type f -name "*.gz" -mtime +1 -delete 2>/dev/null || true

C "Clearing /tmp files older than 2 days"
find /tmp -type f -mtime +2 -delete 2>/dev/null || true

if command -v snap >/dev/null 2>&1; then
    C "Limiting snap revision retention" 
    snap set system refresh.retain=2 || true
fi

if [ "${DOCKER_PRUNE:-0}" = "1" ] && command -v docker >/dev/null 2>&1; then
    C "Docker prune (DOCKER_PRUNE=1)"
    docker system prune -af || true
fi

C "Largest directories (top 15) - see where space went"
du -xh --max-depth=1 / 2>/dev/null | sort -h | tail -15 || true

C "After"
df -h / || true
df -i / || true

echo
echo "=============================================================="
echo " If you still need more space, the biggest non-OS consumer on"
echo " this box is likely the unpacked Sliver server:"
echo "   sudo du -sh /root/sliver-server* /root/.sliver 2>/dev/null"
echo " Removing it (only if you don't run the lab) reclaims ~1GB:"
echo "   sudo systemctl disable --now sliver 2>/dev/null || true"
echo "   sudo rm -rf /root/sliver-server* /root/.sliver /usr/local/bin/sliver*"
echo "=============================================================="
