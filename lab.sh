#!/usr/bin/env bash
# ======================================================================
# Red Team Lab Bootstrap - one-command server setup
#
#   curl -fsSL https://raw.githubusercontent.com/Mizyal13/script/main/lab.sh | bash
#
# What this does:
#   - Installs Sliver C2     (official BishopFox installer)
#   - Installs Metasploit    (official Rapid7 omnibus installer)
#   - Initializes msfdb (Metasploit's PostgreSQL)
#   - Downloads the full lab guide + detection pack into ~/redteam-lab/
#   - Prints the server IP to use with `generate --mtls <IP>`
#
# SCOPE: practice against machines YOU OWN. Keep lab targets isolated
# from anything you do not control.
# ======================================================================
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Mizyal13/script/main"
LAB_DIR="${REDTEAM_LAB_DIR:-$HOME/redteam-lab}"

STEP() { echo; echo "==> $*"; }

# ------------------------------------------------------------------
STEP "1/7  Checking prerequisites"
# ------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  echo "[-] Run as a normal user with sudo rights, not as root."
  exit 1
fi
command -v sudo >/dev/null 2>&1 || { echo "[-] sudo is required."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[*] Installing curl..."; sudo apt-get update -qq && sudo apt-get install -y -qq curl; }
command -v jq   >/dev/null 2>&1 || { echo "[*] Installing jq...";   sudo apt-get update -qq && sudo apt-get install -y -qq jq; }

# ------------------------------------------------------------------
STEP "2/7  Installing Sliver (official installer)"
# ------------------------------------------------------------------
if command -v sliver >/dev/null 2>&1; then
  echo "[+] sliver already present"
else
  echo "[*] curl https://sliver.sh/install | sudo bash"
  curl https://sliver.sh/install | sudo bash
fi

# ------------------------------------------------------------------
STEP "3/7  Installing Metasploit (official Rapid7 installer)"
# ------------------------------------------------------------------
if command -v msfconsole >/dev/null 2>&1; then
  echo "[+] msfconsole already present"
else
  echo "[*] Fetching official msfinstall script..."
  cd /tmp
  curl -L "https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb" -o msfinstall
  chmod +x msfinstall
  echo "[*] Running msfinstall (downloads the framework - takes a while)..."
  sudo ./msfinstall
  cd -
fi

# ------------------------------------------------------------------
STEP "4/7  Initializing Metasploit database"
# ------------------------------------------------------------------
command -v msfdb >/dev/null 2>&1 && { sudo msfdb init >/dev/null 2>&1 || echo "[!] msfdb init had issues (check: msfdb status)"; }

# ------------------------------------------------------------------
STEP "5/7  Downloading lab guides + detection pack"
# ------------------------------------------------------------------
mkdir -p "$LAB_DIR/detections"

declare -A FILES=(
  ["lab/README.md"]="README.md"
  ["lab/setup-attacker.sh"]="setup-attacker.sh"
  ["lab/setup-victims.md"]="setup-victims.md"
  ["lab/sliver-quickstart.md"]="sliver-quickstart.md"
  ["lab/msf-quickstart.md"]="msf-quickstart.md"
  ["lab/phishing-sim-drill.md"]="phishing-sim-drill.md"
  ["lab/exercises-and-detection.md"]="exercises-and-detection.md"
  ["lab/detections/persist_runkey.yar"]="detections/persist_runkey.yar"
  ["lab/detections/beacon_http.yar"]="detections/beacon_http.yar"
  ["lab/detections/create_runkey.yml"]="detections/create_runkey.yml"
  ["lab/detections/periodic_http_beacon.yml"]="detections/periodic_http_beacon.yml"
)

for src in "${!FILES[@]}"; do
  dst="$LAB_DIR/${FILES[$src]}"
  echo "[*]   $src -> $dst"
  curl -fsSL "$REPO_RAW/$src" -o "$dst"
done
chmod +x "$LAB_DIR/setup-attacker.sh"
echo "[+] Lab files at $LAB_DIR"

# ------------------------------------------------------------------
STEP "6/7  Detecting server IP for the C2 listener"
# ------------------------------------------------------------------
PUB_IP=""
command -v curl >/dev/null 2>&1 && PUB_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
echo "    Public IP : ${PUB_IP:-<not detectable>}"
echo "    Local IP  : $(hostname -I 2>/dev/null | awk '{print $1}')"

# ------------------------------------------------------------------
STEP "7/7  Verifying install"
# ------------------------------------------------------------------
echo
echo "--- Sliver ---"
sliver version 2>/dev/null | grep -E "Version|OS/Arch" || sliver version || true
echo
echo "--- Metasploit ---"
msfconsole --version 2>/dev/null | head -n2 || true
echo
echo "--- Databases ---"
msfdb status 2>/dev/null | tail -n3 || true

echo
echo "=============================================================="
echo " LAB READY. Quick start:"
echo "  1) sliver"
echo "     generate --mtls ${PUB_IP:-<SERVER_IP>} --os windows --arch amd64 --save /tmp/"
echo "     mtls"
echo "  2) Guides:  $LAB_DIR/sliver-quickstart.md  and  msf-quickstart.md"
echo "  3) Detection pack:  $LAB_DIR/detections/"
echo "  4) If targets are cloud VMs, open the mTLS port (default 8888)"
echo "     in the server firewall; if they are local VMs, follow"
echo "     setup-victims.md and keep them isolated."
echo "=============================================================="
