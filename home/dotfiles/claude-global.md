@~/.claude/claude-global-prompt.md

## Root on rpi5

Try `mac-sudo <cmd>` first: it asks the user for a Bitwarden approval on their
Mac. If it fails or is refused, ask for a 6-digit TOTP code and run
`printf '%s\n' CODE | sudo -S -p '' <cmd>`: one code, one command. Never retry
`mac-sudo` in a loop.
