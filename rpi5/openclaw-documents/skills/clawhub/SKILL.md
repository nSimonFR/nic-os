---
name: clawhub
description: Install and inspect skills from ClawHub, then add installed skills into the nClaw plugin repo.
homepage: https://clawhub.ai
metadata:
  openclaw:
    emoji: "🦀"
    requires:
      bins: ["npx", "mv", "mkdir"]
      env: ["NCLAW_AUTH_FILE"]
---

# ClawHub Helper

Use this skill to search, inspect, and install skills with `npx --yes clawhub`.

## Defaults

- Use temporary workspace for installs:
  - `--workdir /tmp/clawhub-work`
  - `--dir skills`
- Canonical `nClaw` destination:
  - `/home/nsimon/nic-os/rpi5/openclaw-documents/skills`

## Core Commands

```bash
# Search
CLAWHUB_AUTH_FILE="$NCLAW_AUTH_FILE" npx --yes clawhub search "<query>" --limit 5

# Inspect files without install
CLAWHUB_AUTH_FILE="$NCLAW_AUTH_FILE" npx --yes clawhub inspect <slug> --files

# Install to temp workspace
CLAWHUB_AUTH_FILE="$NCLAW_AUTH_FILE" npx --yes clawhub install <slug> --workdir /tmp/clawhub-work --dir skills --no-input
```

## Mandatory Rule

After EVERY install/inspect/search flow, ask this exact question before ending:

`Do you want me to add this skill to the nClaw plugin repo now?`

If user says **yes**:

```bash
mkdir -p /home/nsimon/nic-os/rpi5/openclaw-documents/skills
mv /tmp/clawhub-work/skills/<slug> /home/nsimon/nic-os/rpi5/openclaw-documents/skills/<slug>
```

If user says **no**, do not move anything.

## Notes

- Prefer read-only commands first (`search`, `inspect`) when slug is uncertain.
- `clawhub` auth is configured by env via `NCLAW_AUTH_FILE` -> `CLAWHUB_AUTH_FILE`.
- Do not publish/delete/hide/unhide unless user explicitly asks.
