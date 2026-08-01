# Victim VM Setup

Create isolated target machines **you own** on the VirtualBox
host-only network. The attacker VM and victims share
`192.168.56.0/24` and nothing else.

> Windows Evaluation ISOs are legally free and last 90 days.
> Metasploitable images are intentionally vulnerable practice
> servers published by Rapid7 for this exact purpose.

## 1. Create the host-only network

1. VirtualBox → **File → Tools → Network Manager** (or
   **Global Tools → Network**).
2. **Create** a host-only adapter: `vboxnet0`,
   IPv4 `192.168.56.1/24`, DHCP **off** (we assign static IPs).
3. For every VM below, set **Settings → Network → Adapter 1 →
   Attached to: Host-only Adapter → `vboxnet0`**.

They now have no route to your LAN or the internet. Verify from the
attacker VM later with `ip a` and `arp-scan` (or `nmap -sn 192.168.56.0/24`).

## 2. Windows 10/11 Evaluation VM (primary target)

1. Download the 64-bit **Evaluation ISO** (free, 90-day):
   - Windows 11: `https://www.microsoft.com/en-us/evalcenter/download-windows-11-enterprise`
   - Windows 10: `https://www.microsoft.com/en-us/evalcenter/download-windows-10-enterprise`
     (Enterprise Eval needs no key; during setup choose **"I don't have a product key"**.)
2. Create VM: **8GB+ RAM, 80GB VDI** (dynamic), 2–4 vCPU. Windows 11
   requires TPM 2.0 → in VM settings enable **TPM** (VirtualBox 7+)
   and **UEFI**. Windows 10 works with BIOS/no TPM — simplest path.
3. Install Windows with a local account, note the password. Run
   Windows Update once.
4. **Tune for a target (not a daily driver):**
   - Disable real-time Windows Defender: `Set-MpPreference -DisableRealtimeMonitoring $true`
   - Disable tamper protection if prompted (or just leave Defender
     on for the detection drills — recommended).
5. Set a static IP: `192.168.56.20/24`, gateway `192.168.56.1`.
   Test: `ping 192.168.56.10` (attacker VM).
6. Now you have a host you can legally infect/execute against. Use it
   for both Sliver (mTLS implant) and Metasploit (staged payload)
   exercises.

### Windows firewall note (for later exercises)

- Inbound connections to the victim from a HTTP(S)/mTLS listener are
  initiated **outbound** by the implant, so usually no firewall opens
  are needed.
- For SMB/exploit drills (Metasploit `exploit/windows/smb` etc.) you'll
  want firewall off or rules added on the victim:
  `netsh advfirewall set allprofiles state off` (lab only).

## 3. Metasploitable 3 (Windows) — alternative Windows target

Rapid7's scripted Windows VM (packer + Vagrant). The prebuilt boxes are
the easiest route:

```bash
# On your lab host (not the attacker VM) with Vagrant + VirtualBox:
vagrant init rapid7/metasploitable3-win14
vagrant up
```

Then attach it to `vboxnet0` in VirtualBox (the packer build only wires
a NAT adapter by default), and set a static IP `192.168.56.30/24`.

> `ms3win` ships with a weak default auth (`vagrant:vagrant`, blank `Administrator`
> password). It's deliberately vulnerable — use only in the lab.

## 4. Metasploitable 2 (Linux) — quick Linux target

1. Download the OVA:
   `https://sourceforge.net/projects/metasploitable/files/Metasploitable2/`
2. VirtualBox → **File → Import Appliance** → select `Metasploitable.ova`.
   Default login `msfadmin:msfadmin`.
3. Attach to `vboxnet0`, static IP `192.168.56.40/24`
   (edit `/etc/network/interfaces` or use
   `sudo ifconfig eth0 192.168.56.40 netmask 255.255.255.0 up`).

It runs ~30 intentionally vulnerable services (vsftpd 2.3.4, Samba
3.0.20, distcc, etc.) — the classic first-scan → first-shell target.

## 5. Verify the lab

From the attacker VM:

```bash
# Tools if missing:
sudo apt-get install -y netdiscover nmap

# See all victims:
sudo nmap -sn 192.168.56.0/24
# e.g. 192.168.56.20  (Windows eval)
#      192.168.56.30  (MS3 Win, if built)
#      192.168.56.40  (Metasploitable 2)
```

Victim-to-attacker: `ping 192.168.56.10` from each victim.
Network is healthy when every host pings every other host on
`192.168.56.0/24` and **nothing** reaches the internet.

## Snapshot before you start firing tools

Before any exploit session, take a VirtualBox **snapshot** of each
victim ("clean baseline"). You can hammer a machine, then restore in
seconds. This is good practice in real engagements too.

---

Next: `sliver-quickstart.md`
