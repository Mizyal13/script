#!/usr/bin/env bash
# ======================================================================
# Red Team Lab - ONE COMMAND, fully automatic (reset + refresh + heal)
#
#   curl -fsSL https://raw.githubusercontent.com/Mizyal13/script/main/lab.sh | bash
#
# Every run does everything, fresh:
#   1. RESET   - wipes the previous lab folder, re-pulls latest from repo
#   2. REFRESH - re-downloads all guides + detection pack (always current)
#   3. HEAL    - clears broken apt state, frees disk, verifies space
#   4. INSTALL - Sliver (official installer) + Metasploit (official, apt
#                fallback) + msfdb init - all idempotent, safe to re-run
#   5. REPORT  - prints server IP + quick start block
#
# Optional env toggles:
#   LAB_KEEP_FILES=1   keep local notes in $LAB_DIR (skip the wipe)
#   LAB_SKIP_INSTALL=1 refresh files only, don't touch installed tools
#   REDTEAM_LAB_DIR=/path   change install location (default ~/redteam-lab)
#
# SCOPE: practice against machines YOU OWN. Keep lab targets isolated
# from anything you do not control.
# ======================================================================
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Mizyal13/script/main"
LAB_DIR="${REDTEAM_LAB_DIR:-$HOME/redteam-lab}"

STEP() { echo; echo "==> $*"; }

# ------------------------------------------------------------------
# 1. RESET: wipe old lab folder every run unless told to keep it.
#    This guarantees "always fresh" - the same intent as a re-deploy.
# ------------------------------------------------------------------
reset_lab() {
  if [ "${LAB_KEEP_FILES:-0}" != "1" ]; then
    echo "    ($LAB_DIR being reset for a fresh copy)"
    rm -rf "$LAB_DIR"
  fi
  mkdir -p "$LAB_DIR/detections"
}

# ------------------------------------------------------------------
# 2. REFRESH: pull the latest versions of every lab file from the repo.
# ------------------------------------------------------------------
refresh_lab() {
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
    curl -fsSL "$REPO_RAW/$src" -o "$dst"
  done
  chmod +x "$LAB_DIR/setup-attacker.sh"
  echo "    Lab files refreshed at $LAB_DIR"
}

# ------------------------------------------------------------------
# 3. HEAL: fix broken apt state + free disk before installs.
# ------------------------------------------------------------------
housekeeping() {
  echo "    before: $(df -h / | awk 'NR==2 {print $4" free of "$2}')"
  sudo rm -rf /var/lib/apt/lists/partial/* 2>/dev/null || true
  sudo apt-get clean 2>/dev/null || true
  sudo apt-get -y autoremove --purge >/dev/null 2>&1 || true
  echo "    after : $(df -h / | awk 'NR==2 {print $4" free of "$2}')"
}

# ------------------------------------------------------------------
STEP "1/6  Prerequisites"
# ------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || { echo "[-] Run as a normal user with sudo rights, not as root."; exit 1; }
command -v sudo >/dev/null 2>&1 || { echo "[-] sudo is required."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[*] Installing curl..."; sudo apt-get update -qq && sudo apt-get install -y -qq curl; }
command -v jq   >/dev/null 2>&1 || { echo "[*] Installing jq...";   sudo apt-get update -qq && sudo apt-get install -y -qq jq; }
echo "    Arch: $(dpkg --print-architecture 2>/dev/null || uname -m)"

# ------------------------------------------------------------------
STEP "2/6  RESET + REFRESH lab files"
# ------------------------------------------------------------------
reset_lab
refresh_lab

if [ "${LAB_SKIP_INSTALL:-0}" = "1" ]; then
  echo "    LAB_SKIP_INSTALL=1 - tools left untouched."
else
  # ------------------------------------------------------------------
  STEP "3/6  HEAL disk state"
  # ------------------------------------------------------------------
  housekeeping

  # ------------------------------------------------------------------
  STEP "4/6  Install/verify Sliver (idempotent)"
  # ------------------------------------------------------------------
  if command -v sliver >/dev/null 2>&1; then
    echo "[+] sliver already present"
  else
    echo "[*] curl https://sliver.sh/install | sudo bash"
    curl https://sliver.sh/install | sudo bash
    echo "[+] sliver installed"
  fi

  # ------------------------------------------------------------------
  STEP "5/6  Install/verify Metasploit (idempotent, apt fallback)"
  # ------------------------------------------------------------------
  if command -v msfconsole >/dev/null 2>&1; then
    echo "[+] msfconsole already present"
  else
    housekeeping   # Sliver unpacked a lot; make room first
    echo "[*] Fetching official msfinstall script..."
    cd /tmp
    curl -L "https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb" -o msfinstall
    chmod +x msfinstall
    echo "[*] Running msfinstall (downloads the framework - takes a while)..."
    if sudo ./msfinstall; then
      echo "[+] Metasploit installed via msfinstall"
    else
      echo "[!] msfinstall failed - retrying via plain apt..."
      housekeeping
      sudo apt-get update || true
      if sudo apt-get install -y metasploit-framework; then
        echo "[+] Metasploit installed via apt"
      else
        echo "[!] Metasploit could not be installed."
        echo "    Check disk:  df -h /"
        echo "    Check repo:  apt-cache policy metasploit-framework"
        echo "    (arm64 hosts may lack Rapid7 packages - Sliver alone still runs the lab.)"
      fi
    fi
    cd -
  fi

  # ------------------------------------------------------------------
  STEP "6/6  Initialize msfdb (idempotent)"
  # ------------------------------------------------------------------
  command -v msfdb >/dev/null 2>&1 && { sudo msfdb init >/dev/null 2>&1 || echo "[!] msfdb init had issues (check: msfdb status)"; }
fi

# ------------------------------------------------------------------
# Final report
# ------------------------------------------------------------------
PUB_IP=""
command -v curl >/dev/null 2>&1 && PUB_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)

echo
echo "=============================================================="
echo " LAB READY - everything is fresh and verified."
echo "=============================================================="
echo "  IP this run  : ${PUB_IP:-<detect failed>} (public)"
echo "                  $(hostname -I 2>/dev/null | awk '{print $1}') (local)"
echo
echo "  Sliver       : $(command -v sliver >/dev/null 2>&1 && sliver version 2>/dev/null | grep -E 'Version' | head -n1 || echo 'not installed')"
echo "  Metasploit   : $(command -v msfconsole >/dev/null 2>&1 && msfconsole --version 2>/dev/null | head -n1 || echo 'not installed')"
echo
echo "  Quick start  :"
echo "    sliver"
echo "    generate --mtls ${PUB_IP:-<SERVER_IP>} --os windows --arch amd64 --save /tmp/"
echo "    mtls"
echo
echo "  Guides       : $LAB_DIR/sliver-quickstart.md"
echo "                 $LAB_DIR/msf-quickstart.md"
echo "                 $LAB_DIR/phishing-sim-drill.md"
echo "  Detections   : $LAB_DIR/detections/"
echo
echo "  Re-run anytime to auto reset + refresh. Keep targets isolated."
echo "=============================================================="
