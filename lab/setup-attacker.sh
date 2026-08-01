#!/usr/bin/env bash
# ======================================================================
# Attacker VM setup: Sliver + Metasploit
# Target: Ubuntu 24.04 LTS x86_64 (VirtualBox VM, host-only network)
# Run INSIDE the attacker VM. Requires sudo.
#
# What this installs:
#   - Sliver C2 (official BishopFox installer: https://sliver.sh/install)
#   - Metasploit Framework (official Rapid7 omnibus installer)
#   - curl / jq / net-tools (minor helpers)
#
# Scope: this lab is for machines YOU OWN in a host-only network.
# ======================================================================
set -euo pipefail

STEP() { echo; echo "==> $*"; }

# ------------------------------------------------------------------
STEP "1/5  Checking prerequisites"
# ------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  echo "[-] Run this as a normal user with sudo rights, not as root."
  exit 1
fi
if ! command -v sudo >/dev/null 2>&1; then
  echo "[-] sudo is required."
  exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "[*] Installing curl..."; sudo apt-get update -qq && sudo apt-get install -y -qq curl; }
command -v jq   >/dev/null 2>&1 || { echo "[*] Installing jq...";   sudo apt-get update -qq && sudo apt-get install -y -qq jq; }

# ------------------------------------------------------------------
STEP "2/5  Installing Sliver (official installer)"
# ------------------------------------------------------------------
if command -v sliver >/dev/null 2>&1; then
  echo "[+] sliver already present: $(sliver version 2>/dev/null | head -n1 || true)"
else
  echo "[*] Running official install: curl https://sliver.sh/install | sudo bash"
  curl https://sliver.sh/install | sudo bash
fi

# ------------------------------------------------------------------
STEP "3/5  Installing Metasploit (official Rapid7 installer)"
# ------------------------------------------------------------------
if command -v msfconsole >/dev/null 2>&1; then
  echo "[+] msfconsole already present: $(msfconsole --version 2>/dev/null | head -n1 || true)"
else
  echo "[*] Fetching official msfinstall script (Rapid7 omnibus)..."
  cd /tmp
  curl -L https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb -o msfinstall
  chmod +x msfinstall
  echo "[*] Running msfinstall (this downloads the framework, takes a while)..."
  sudo ./msfinstall
  cd -
fi

# ------------------------------------------------------------------
STEP "4/5  Initializing Metasploit database"
# ------------------------------------------------------------------
# msfdb init spins up the local PostgreSQL DB that msfconsole uses
# for workspace + loot storage. Safe to re-run if already initialized.
if command -v msfdb >/dev/null 2>&1; then
  sudo msfdb init || echo "[!] msfdb init had issues (may already be initialized — check with: msfdb status)"
fi

# ------------------------------------------------------------------
STEP "5/5  Verifying install"
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
echo
echo "=============================================================="
echo " DONE. Next steps:"
echo "  1) Start Sliver:            sliver"
echo "  2) Follow lab/sliver-quickstart.md for your first implant"
echo "  3) Metasploit:              msfconsole   (guide in msf-quickstart.md)"
echo "=============================================================="
