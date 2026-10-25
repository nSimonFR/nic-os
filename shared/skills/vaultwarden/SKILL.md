---
name: vaultwarden
description: Save a login, password or secure note into the user's Vaultwarden (Bitwarden) vault. Use when asked to store credentials in the password manager, or right after creating an account or key whose secret must be kept.
---

# Vaultwarden

`vault-agent` (rpi5 only) writes into the **Agents** collection of the "Agents"
org, which the user sees in every Bitwarden client. It logs in as a bot account
that can open that org only — the user's personal items are out of reach, so
"read my password for X" is not something this skill can do.

## Add a login

The secret travels through a file or stdin, so it stays out of argv, the
transcript and shell history:

```bash
# from a secret file (sudo cat for root-owned agenix files)
sudo cat /run/agenix/<name> | vault-agent add --name "<Service>" \
  --username <user> --uri https://<host> --notes "<where it is used>" --password-file -

# a new account: generate the password, then use the one printed back
vault-agent add --name "<Service>" --username <user> --uri https://<host> --generate [LENGTH]
```

- `--uri` is repeatable and needs a scheme; `--totp` takes an `otpauth://` URI.
- `--note --name X --notes "…"` stores a secure note instead.
- Output is one JSON line: `{"action": "created"|"updated", "id", "name"}`, plus
  `"password"` only with `--generate`.

Done when the command exits 0 and `vault-agent list` shows the item.

## Exit codes

- **3**: an item with that name exists. Replace it only when the user asked to
  change it: rerun with `--update` (the old password moves to its history).
- **1**: `FATAL …` on stderr. `run init` means the org is gone; tell the user.
- **2**: the wrapper's env is missing — you are not on rpi5.

## Setup (already done)

`vault-agent init` creates the org and invites the owner; after the owner
accepts the email, `vault-agent confirm` hands them the org key. Wiring:
`hosts/rpi5/vaultwarden.nix`, code `nicos_scripts/vaultwarden/agents.py`.
