@~/.claude/claude-global-prompt.md

## Root on rpi5

Try `mac-sudo <cmd>` first: it asks the user for a Bitwarden approval on their
Mac. If it fails or is refused, tell the user a push is coming and run
`phone-sudo <cmd>`: a ShellWatch notification on their phone, approved with Face
ID within 60 s. If that fails too, ask for a 6-digit TOTP code and run
`printf '%s\n' CODE | sudo -S -p '' <cmd>`: one code, one command. Never retry
`mac-sudo` or `phone-sudo` in a loop.


Version everything you build: commit per iteration (`git init` if outside a repo), then offer a private `nSimonFR` remote pushed as `nSimonFR-ai`.

## Job hunting

CV, job applications or my work record (incl. "help me apply to <URL>"):
work in `~/MyDocuments/PERSO/career` and read its `AGENTS.md` first.
