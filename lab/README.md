# Red Team Lab — Sliver + Metasploit (self-hosted)

Practice adversary emulation **on machines you own**, in an isolated
network. This is the standard setup used for OSCP / eCPPT / CRTO /
offensive-security self-study. Keep the lab network host-only — never
give the attacker VM a route to your LAN or the internet-facing
machines you don't control.

## Topology

```
┌────────────────────────────────────────────────────────────┐
│  Lab host (your laptop/desktop, macOS etc.)                │
│                                                            │
│  VirtualBox (host-only: 192.168.56.0/24)                   │
│                                                            │
│  ┌───────────────────┐     ┌──────────────────────────┐    │
│  │ Attacker VM       │     │ Victim VM(s)             │    │
│  │ Ubuntu 24.04 x64  │     │ - Win 10/11 Eval         │    │
│  │ Sliver server     │◄───►│ - Metasploitable3 (Win)  │    │
│  │ Metasploit        │     │ - Metasploitable2 (Lin)  │    │
│  │ 192.168.56.10     │     │   192.168.56.x           │    │
│  └───────────────────┘     └──────────────────────────┘    │
└────────────────────────────────────────────────────────────┘
```

- **Attacker VM**: Ubuntu 24.04 LTS (x86_64). Sliver server officially
  supports Linux (and Windows); this VM is the C2 server + Metasploit.
- **Victim VMs**: Windows 10/11 Evaluation (90-day license, free from
  Microsoft) and Rapid7's Metasploitable 2/3 practice images.
- **Network**: VirtualBox host-only adapter so VMs never reach the
  internet.

## Files in this folder

| File                         | Purpose                                                               |
| ---------------------------- | --------------------------------------------------------------------- |
| `setup-attacker.sh`          | Installs Sliver + Metasploit on the attacker VM and verifies versions |
| `setup-victims.md`           | Windows eval VM + Metasploitable setup, networking guide              |
| `sliver-quickstart.md`       | First mTLS implant, listener, session walkthrough                     |
| `msf-quickstart.md`          | msfdb init, first exploit exercise, Meterpreter basics                |
| `phishing-sim-drill.md`      | Authorized self-targeted phishing sim (you are both sides)            |
| `exercises-and-detection.md` | Practice drills + the defensive mirror (YARA/Sigma)                   |

## Scope rules (non-negotiable)

1. Targets are VMs in the host-only network that you own.
2. No pivot from the lab into your LAN/host network.
3. No use against machines you do not own outright.
4. When you're done, tear down or keep the VMs isolated.

## Quick start

```bash
# 1. Create attacker VM (Ubuntu 24.04), then inside it:
bash lab/setup-attacker.sh

# 2. Build victim VMs per setup-victims.md

# 3. Follow sliver-quickstart.md then msf-quickstart.md
```

That's it — everything else is in the individual guides.
