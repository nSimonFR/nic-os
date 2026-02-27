---
name: manage-skills
description: Search skills with ClawHub CLI and install them into openclaw through nic-os/nClaw-skills
metadata:
  openclaw:
    requires:
      bins: ["npx", "mkdir"]
---

Use this skill when the user asks for a capability, a workflow, or "is there a skill for X".

Flow (minimal):
- Understand intent in 3 words or less (domain + task).
- Search:
  - `npx --yes clawhub search "<query>" --limit 5`
- Return top 1-3 results only: `<slug>` + one-line purpose.
- Ask once: `Install one now?`
- If user picks one, install:
  - `npx --yes clawhub install <slug> --workdir ~/nic-os/rpi5/openclaw --dir skills --no-input`
- If no good match, say no strong hit and continue without installing.

Rules:
- Prefer specific search terms; retry once with alternate wording if empty.
- Do not run publish/delete/hide/unhide unless explicitly requested.
