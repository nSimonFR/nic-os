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

# Claude Code: env vars are set by the Nix wrapper (claude.nix)
alias claude='command claude --dangerously-skip-permissions --remote-control'
cc()     { command claude --continue "$@"; }
cr()     { command claude --resume "$@"; }

# claude-local: Claude Code → local gemma4:26b (M3 Pro) via litellm proxy (port 4000)
# claude-local: gemma4-a4b (26.5B MoE, 4B active — quality, 3 tok/s, 80% mem)
alias claude-local='ANTHROPIC_BASE_URL=http://localhost:4000 ANTHROPIC_API_KEY=litellm-local ANTHROPIC_MODEL=gemma4-a4b command claude --dangerously-skip-permissions --remote-control'
# claude-local-fast: gemma4-e4b (8B dense — speed, 10 tok/s, 25% mem)
alias claude-local-fast='ANTHROPIC_BASE_URL=http://localhost:4000 ANTHROPIC_API_KEY=litellm-local ANTHROPIC_MODEL=gemma4-e4b command claude --dangerously-skip-permissions --remote-control'

# claude-beast: Claude Code → Beast gemma4:e4b (RTX 3080 Ti) via litellm proxy (port 4001)
alias claude-beast='ANTHROPIC_BASE_URL=http://localhost:4001 ANTHROPIC_API_KEY=litellm-local ANTHROPIC_MODEL=openai/gemma4:e4b command claude --dangerously-skip-permissions --remote-control'

# pi: pi-coding-agent via Aperture → tiny-llm-gate → codex-proxy / beast Ollama.
# All routes go through https://ai.gate-mintaka.ts.net for observability.
# Defaults to gpt-5.5 (Codex subscription); pass any tlg model id as $1, e.g.
#   pi                  → gpt-5.5
#   pi gemma4:e4b       → beast Ollama
#   pi auto             → beast-first with codex fallback
pi() { command pi --provider aperture --model "${1:-gpt-5.5}" "${@:2}"; }
