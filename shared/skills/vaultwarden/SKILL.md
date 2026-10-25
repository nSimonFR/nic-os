---
name: vaultwarden
description: Save a login, password or secure note into the user's Vaultwarden (Bitwarden) vault. Use when asked to store credentials in the password manager, or right after creating an account or key whose secret must be kept.
---

# Vaultwarden

`vault-agent` (rpi5 only) writes into the user's "Agents" collection. It is
write-only toward the user: their personal items are out of reach.

Pass the secret through stdin or a file, never argv:

```bash
sudo cat /run/agenix/<name> | vault-agent add --name "<Service>" \
  --username <user> --uri https://<host> --notes "<context>" --password-file -
vault-agent add --name "<Service>" --username <user> --uri https://<host> --generate  # prints it
```

`--uri` repeats. Done when it exits 0;
`vault-agent list` shows names, never secrets.

Exit **3** = the name exists: add `--update` only if the user asked to change it.
