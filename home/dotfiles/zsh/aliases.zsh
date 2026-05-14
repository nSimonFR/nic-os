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
alias j="jj"
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

# claude-local: Claude Code → oMLX on localhost:8000 (M3 Pro, MLX backend, Anthropic-native)
# Qwen3.6-27B-4bit (~15 GB resident, reasoning model — replies via reasoning_content).
# oMLX has its own admin auth; localhost verification is disabled (skip_api_key_verification=true),
# so ANTHROPIC_API_KEY is a placeholder.
alias claude-local='ANTHROPIC_BASE_URL=http://localhost:8000 ANTHROPIC_API_KEY=omlx-local ANTHROPIC_MODEL=Qwen3.6-27B-4bit command claude --dangerously-skip-permissions --remote-control'

# claude-beast: Claude Code → Beast gemma4:e4b (RTX 3080 Ti) via litellm proxy (port 4001)
alias claude-beast='ANTHROPIC_BASE_URL=http://localhost:4001 ANTHROPIC_API_KEY=litellm-local ANTHROPIC_MODEL=openai/gemma4:e4b command claude --dangerously-skip-permissions --remote-control'

# pi: pi-coding-agent via Aperture → tiny-llm-gate → codex-proxy / beast Ollama.
# All routes go through https://ai.gate-mintaka.ts.net for observability.
# Pass any tlg model id as $1 to override the default, e.g.
#   pi                  → default (Qwen3.6-27B-4bit on Mac, gpt-5.5 elsewhere)
#   pi gemma4:e4b       → beast Ollama
#   pi gpt-5.5          → Codex subscription
#   pi auto             → beast-first with codex fallback
#
# On Mac the default is Qwen3.6-27B-4bit — local MLX inference on this host,
# reached through Aperture (registered in rpi5/tiny-llm-gate.nix as
# provider=omlx). Requires `tailscale serve --bg --https=8443
# http://127.0.0.1:8000` to be set up once on this Mac so the RPi5 can reach
# oMLX. The serve config persists across reboots; check with
# `tailscale serve status`.
if [[ "$OSTYPE" == darwin* ]]; then
  pi() { command pi --provider aperture --model "${1:-Qwen3.6-27B-4bit}" "${@:2}"; }
else
  pi() { command pi --provider aperture --model "${1:-gpt-5.5}" "${@:2}"; }
fi
