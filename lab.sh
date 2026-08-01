#!/usr/bin/env bash
# ======================================================================
# Red Team Lab Bootstrap - one-command server setup
#
#   curl -fsSL https://raw.githubusercontent.com/Mizyal13/script/main/lab.sh | bash
#
# What this does:
#   - Cleans up disk space and verifies room before large installs
#   - Installs Sliver C2     (official BishopFox installer)
#   - Installs Metasploit    (official Rapid7 installer, apt fallback)
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
# Housekeeping: clear broken apt state + free disk so big installs fit.
# ------------------------------------------------------------------
housekeeping() {
  echo "    before: $(df -h / | awk 'NR==2 {print $4" free of "$2}')"
  sudo rm -rf /var/lib/apt/lists/partial/* 2>/dev/null || true
  sudo apt-get clean 2>/dev/null || true
  sudo apt-get -y autoremove --purge >/dev/null 2>&1 || true
  echo "    after : $(df -h / | awk 'NR==2 {print $4" free of "$2}')"
}

# ------------------------------------------------------------------
STEP "1/8  Checking prerequisites"
# ------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  echo "[-] Run as a normal user with sudo rights, not as root."
  exit 1
fi
command -v sudo >/dev/null 2>&1 || { echo "[-] sudo is required."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[*] Installing curl..."; sudo apt-get update -qq && sudo apt-get install -y -qq curl; }
command -v jq   >/dev/null 2>&1 || { echo "[*] Installing jq...";   sudo apt-get update -qq && sudo apt-get install -y -qq jq; }
echo "    Arch: $(dpkg --print-architecture 2>/dev/null || uname -m)"

# ------------------------------------------------------------------
STEP "2/8  Disk space check + cleanup"
# ------------------------------------------------------------------
housekeeping

# ------------------------------------------------------------------
STEP "3/8  Installing Sliver (official installer)"
# ------------------------------------------------------------------
if command -v sliver >/dev/null 2>&1; then
  echo "[+] sliver already present"
else
  echo "[*] curl https://sliver.sh/install | sudo bash"
  curl https://sliver.sh/install | sudo bash
  echo "[+] sliver installed"
fi

# ------------------------------------------------------------------
STEP "4/8  Installing Metasploit"
# ------------------------------------------------------------------
if command -v msfconsole >/dev/null 2>&1; then
  echo "[+] msfconsole already present"
else
  housekeeping   # Sliver unpacked a lot; make room before Metasploit
  echo "[*] Fetching official msfinstall script (Rapid7 omnibus)..."
  cd /tmp
  curl -L "https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb" -o msfinstall
  chmod +x msfinstall
  echo "[*] Running msfinstall (downloads the framework - takes a while)..."
  if sudo ./msfinstall; then
    echo "[+] Metasploit installed via msfinstall"
  else
    echo "[!] msfinstall failed - retrying via plain apt (repo was already added)..."
    housekeeping
    sudo apt-get update || true
    if sudo apt-get install -y metasploit-framework; then
      echo "[+] Metasploit installed via apt"
    else
      echo "[!] Metasploit could not be installed."
      echo "    Likely causes:"
      echo "      - Disk still full:   df -h /"
      echo "      - arm64: Rapid7's apt repo may lack arm64 packages."
      echo "        Check:  apt-cache policy metasploit-framework"
      echo "        Docs:   https://docs.metasploit.com/docs/using-metasploit/install.html"
      echo "    The lab still works with Sliver alone; re-run this script"
      echo "    once the above is sorted and it will pick up where it left off."
    fi
  fi
  cd -
fi

# ------------------------------------------------------------------
STEP "5/8  Initializing Metasploit database"
# ------------------------------------------------------------------
command -v msfdb >/dev/null 2>&1 && { sudo msfdb init >/dev/null 2>&1 || echo "[!] msfdb init had issues (check: msfdb status)"; }

# ------------------------------------------------------------------
STEP "6/8  Downloading lab guides + detection pack"
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
STEP "7/8  Detecting server IP for the C2 listener"
# ------------------------------------------------------------------
PUB_IP=""
command -v curl >/dev/null 2>&1 && PUB_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
echo "    Public IP : ${PUB_IP:-<not detectable>}"
echo "    Local IP  : $(hostname -I 2>/dev/null | awk '{print $1}')"

# ------------------------------------------------------------------
STEP "8/8  Verifying install"
# ------------------------------------------------------------------
echo
echo "--- Sliver ---"
sliver version 2>/dev/null | grep -E "Version|OS/Arch" || sliver version || true
echo
echo "--- Metasploit ---"
msfconsole --version 2>/dev/null | head -n2 || echo "    (not installed)"
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
echo "     Phishing sim drill:  $LAB_DIR/phishing-sim-drill.md"
echo "  3) Detection pack:  $LAB_DIR/detections/"
echo "  4) If targets are cloud VMs, open the mTLS port (default 8888)"
echo "     in the server firewall; if they are local VMs, follow"
echo "     setup-victims.md and keep them isolated."
echo "=============================================================="
