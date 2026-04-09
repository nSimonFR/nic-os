alias e="cursor" # My current main editor
alias ai="cursor-agent --force"
alias ls='ls -GFh'
alias ll='ls -GFhl'
alias v="vim"
alias tmux="tmux -2"
alias pipupdate="su -c \"pip freeze --local | grep -v '^\-e' | cut -d = -f 1	| xargs -n1 pip install -U \" "
alias gc="git checkout"
alias gcam="git commit --amend --no-edit"
alias grb="git rebase -i --autosquash"
alias repo="gh repo view --web"
alias prs="gh pr list --web"
alias cpr="createpr"

# Tailscale exit node quick toggles (--accept-routes required to preserve non-default setting)
alias vpn-on='tailscale up --exit-node=rpi5 --accept-routes && echo "✅ Exit node enabled (via RPi5)"'
alias vpn-off='tailscale up --exit-node= --accept-routes && echo "❌ Exit node disabled (direct internet)"'
alias vpn-status='tailscale status | grep -E "(rpi5|exit node)" || echo "Exit node: disabled"'

# Claude Code: AI identity (nSimonFR-ai), clear personal GITHUB_TOKEN
# Uses functions + `env` so env var assignments work correctly in zsh
# (zsh does not treat dynamically-expanded array words as env var prefixes)
_claude_with_env() {
  env \
    GIT_SSH_COMMAND="ssh -i ~/.ssh/ai_id_ed25519 -o IdentityAgent=none" \
    GH_TOKEN="$(gh auth token --user nSimonFR-ai)" \
    GITHUB_TOKEN="" \
    PATH="$HOME/.claude/bin:$PATH" \
    command claude "$@"
}
claude() { _claude_with_env --dangerously-skip-permissions --remote-control "$@"; }
cc()     { _claude_with_env --continue "$@"; }
cr()     { _claude_with_env --resume "$@"; }
