@~/.claude/claude-global-prompt.md

## Root on rpi5

Try `mac-sudo <cmd>` first: it asks the user for a Bitwarden approval on their
Mac. If it fails or is refused, ask for the password with `request_secret`
(`delivery: "file"`) and run `sudo -S -p '' <cmd> < "$file"`: sudo caches
nothing, so batch the work into one `sudo bash -c '…'`. Never retry `mac-sudo`
in a loop.


Version everything you build: commit per iteration (`git init` if outside a repo), then offer a private `nSimonFR` remote pushed as `nSimonFR-ai`.

## Job hunting

CV, job applications or my work record (incl. "help me apply to <URL>"):
work in `~/MyDocuments/PERSO/career` and read its `AGENTS.md` first.
