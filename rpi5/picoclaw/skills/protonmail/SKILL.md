<!-- vendored via `npx skills add steipete/clawdis@himalaya` (commit 27e5d49); locally adapted for personal ProtonMail via the hydroxide bridge on rpi5 -->
---
name: protonmail
description: Read, search, and send the user's personal ProtonMail using the himalaya CLI against the local hydroxide bridge (IMAP :1143 / SMTP :1025).
homepage: https://github.com/pimalaya/himalaya
metadata: {"openclaw":{"emoji":"📧","os":["linux"],"requires":{"bins":["himalaya"]}}}
---

# ProtonMail (himalaya + hydroxide)

> **PERSONAL mail only.** This skill is wired to the user's personal ProtonMail
> (`nicolas.simon@protonmail.com`) via the local hydroxide bridge. Work mail is out of scope.

`himalaya` is a CLI email client. On the rpi5 it talks to **hydroxide**, a third-party
ProtonMail bridge running as a system service that exposes IMAP on `127.0.0.1:1143` and SMTP
on `127.0.0.1:1025`. Both authenticate with the bridge password at
`/run/agenix/protonmail-bridge-password` (group-readable by `hydroxide`, which `nsimon` is a
member of). The himalaya config at `~/.config/himalaya/config.toml` is Nix-managed in
`rpi5/picoclaw/picoclaw.nix` — do **not** hand-edit. Edit the Nix module instead.

## References

- `references/configuration.md` (himalaya config file + IMAP/SMTP authentication; informational only)
- `references/message-composition.md` (MML syntax for composing emails)

## Configuration (informational — already Nix-managed)

```toml
[accounts.proton]
default = true
email = "nicolas.simon@protonmail.com"
display-name = "Nicolas Simon"

backend.type = "imap"
backend.host = "127.0.0.1"
backend.port = 1143
backend.encryption.type = "none"
backend.login = "nicolas.simon@protonmail.com"
backend.auth.type = "raw"
backend.auth.raw.cmd = "cat /run/agenix/protonmail-bridge-password"

message.send.backend.type = "smtp"
message.send.backend.host = "127.0.0.1"
message.send.backend.port = 1025
message.send.backend.encryption.type = "none"
message.send.backend.login = "nicolas.simon@protonmail.com"
message.send.backend.auth.type = "raw"
message.send.backend.auth.raw.cmd = "cat /run/agenix/protonmail-bridge-password"
```

Plaintext on `127.0.0.1` is fine — the bridge terminates locally.

## Common Operations

### List Folders

```bash
himalaya folder list
```

### List Emails

List emails in INBOX (default):

```bash
himalaya envelope list
```

List emails in a specific folder:

```bash
himalaya envelope list --folder "Sent"
```

List with pagination:

```bash
himalaya envelope list --page 1 --page-size 20
```

### Search Emails

```bash
himalaya envelope list from john@example.com subject meeting
```

### Read an Email

Read email by ID (shows plain text):

```bash
himalaya message read 42
```

Export raw MIME:

```bash
himalaya message export 42 --full
```

### Reply to an Email

Interactive reply (opens $EDITOR):

```bash
himalaya message reply 42
```

Reply-all:

```bash
himalaya message reply 42 --all
```

### Forward an Email

```bash
himalaya message forward 42
```

### Write a New Email

Interactive compose (opens $EDITOR):

```bash
himalaya message write
```

Send directly using template:

```bash
cat << 'EOF' | himalaya template send
From: you@example.com
To: recipient@example.com
Subject: Test Message

Hello from Himalaya!
EOF
```

Or with headers flag:

```bash
himalaya message write -H "To:recipient@example.com" -H "Subject:Test" "Message body here"
```

### Move/Copy Emails

Move to folder:

```bash
himalaya message move 42 "Archive"
```

Copy to folder:

```bash
himalaya message copy 42 "Important"
```

### Delete an Email

```bash
himalaya message delete 42
```

### Manage Flags

Add flag:

```bash
himalaya flag add 42 --flag seen
```

Remove flag:

```bash
himalaya flag remove 42 --flag seen
```

## Multiple Accounts

List accounts:

```bash
himalaya account list
```

Use a specific account:

```bash
himalaya --account work envelope list
```

## Attachments

Save attachments from a message:

```bash
himalaya attachment download 42
```

Save to specific directory:

```bash
himalaya attachment download 42 --dir ~/Downloads
```

## Output Formats

Most commands support `--output` for structured output:

```bash
himalaya envelope list --output json
himalaya envelope list --output plain
```

## Debugging

Enable debug logging:

```bash
RUST_LOG=debug himalaya envelope list
```

Full trace with backtrace:

```bash
RUST_LOG=trace RUST_BACKTRACE=1 himalaya envelope list
```

## Tips

- Use `himalaya --help` or `himalaya <command> --help` for detailed usage.
- Message IDs are relative to the current folder; re-list after folder changes.
- For composing rich emails with attachments, use MML syntax (see `references/message-composition.md`).
- Default account is `proton`; no need to pass `--account`.

## Troubleshooting

- **Auth fails** → bridge password lives at `/run/agenix/protonmail-bridge-password`
  (mode `0440 hydroxide:hydroxide`). `nsimon` must be in the `hydroxide` group;
  `id nsimon` should list it. The agenix file changes path on rebuild — restart
  picoclaw (`systemctl --user restart picoclaw`) if it has stale env.
- **Bridge offline** → `systemctl status hydroxide` and `journalctl -u hydroxide -e`.
  Hydroxide can crashloop after a rotation of `~/.config/hydroxide/auth.json`; re-auth
  via the FIRST-TIME SETUP block at the top of `rpi5/hydroxide.nix`.
- **Connection refused** on `127.0.0.1:1143` / `:1025` → check `ss -tlnp | grep -E '1143|1025'`;
  hydroxide binds `0.0.0.0` on those ports.
- **TLS errors** → encryption is intentionally `none` on the loopback hop; if himalaya
  insists on TLS, double-check the config block above against `~/.config/himalaya/config.toml`.
