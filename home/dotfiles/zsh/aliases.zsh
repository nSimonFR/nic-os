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

# Claude Code: routed through `claude-gated` (home/claude-aperture-shim.nix) so
# interactive sessions get Aperture capture AND working Remote Control — the two
# used to be mutually exclusive, since Remote Control refuses any base URL other
# than api.anthropic.com. The shim keeps that URL and re-targets inference at
# Aperture underneath. If the shim is down, claude-gated degrades to Aperture
# direct (no Remote Control) rather than hanging.
#
# Everything else still gets the gate from the Nix wrapper's ANTHROPIC_BASE_URL
# default (claude.nix) — headless rpi5 services, the desktop app, cron — so they
# take on no dependency on the proxy. `command claude` bypasses this function for
# the same reason. The ANTHROPIC_* prefixes on the aliases below win over that
# default (--set-default yields to an explicitly set value).
#
# A function, not an alias, so it can inject flags; a same-named alias would
# shadow it.
#
# --remote-control lives HERE, not on the wrappers below, because it is only
# valid on the shim branch (Remote Control refuses any base URL but
# api.anthropic.com, so the degraded branch must NOT pass it). It used to sit on
# `claude()` alone, which silently left every `cc`/`cr` session with no control
# channel: the phone still listed them — the claude-rc host publishes every
# `~/.claude/sessions/<pid>.json` it can see and they inherit the *host's*
# connected status — so sends were accepted and then landed nowhere.
# Port and CA path mirror home/claude-aperture-shim.nix — change both together.
_claude_shim() {
  local ca="$HOME/.claude-aperture-shim/mitmproxy-ca-cert.pem"
  # Probe the port: HTTPS_PROXY pointing at a closed one makes Claude Code HANG
  # rather than fail fast, so degrade to plain Aperture instead of wedging.
  if [[ -f $ca ]] && zmodload zsh/net/tcp 2>/dev/null && ztcp 127.0.0.1 18888 2>/dev/null; then
    ztcp -c $REPLY 2>/dev/null
    ANTHROPIC_BASE_URL=https://api.anthropic.com \
    HTTPS_PROXY=http://127.0.0.1:18888 \
    NODE_EXTRA_CA_CERTS=$ca \
      command claude --remote-control "$@"
  else
    print -u2 "claude: Aperture shim unavailable — continuing WITHOUT Remote Control."
    print -u2 "  restart it: launchctl kickstart -k gui/\$(id -u)/org.nix-community.home.claude-aperture-shim"
    command claude "$@"
  fi
}

# `claude()` used to pass --dangerously-skip-permissions, putting every session
# in bypassPermissions mode. Dropped — but NOT to hide the mode banner under the
# input box, which was the original theory and is wrong. That row is
# unconditional in a local interactive session: it renders on
# `etl = !!dne && qMS`, where dne is toolPermissionContext.mode and qMS is only
# "can this session change modes", and EVERY mode in the indicator table has a
# label, `default` included ("manual mode", colour inactive). So the mode cannot
# be un-shown, only re-labelled and re-coloured: bypassPermissions is red
# "bypass permissions", auto is yellow "auto mode", default is dim "manual mode".
# Nor does the row free a line — it is the shared footer that also carries the PR
# indicator and "? for shortcuts".
#
# What dropping the flag DOES buy is not running every session with permissions
# switched off wholesale. It is close to a no-op on prompting, because
# claude-settings.json already allows the whole tool surface
# (Bash/Read/Write/Edit/Glob/Grep/WebFetch/Task…), and the two gaps that would
# have started prompting were closed in the same commit: postgres_prod_ro +
# trusk-apis went into permissions.allow, and additionalDirectories/Read() gained
# their /Users/nsimon spellings so the transcript dirs resolve on darwin too.
#
# `cc`/`cr` never passed the flag, so they were already running this way.
# shift+tab still reaches bypass by hand when a session genuinely needs it.
claude() { _claude_shim "$@"; }
cc()     { _claude_shim --continue "$@"; }
cr()     { _claude_shim --resume "$@"; }

# The menu a pane opened by prefix+" / % / shift+c / shift+s lands on
# (home/scripts/herdr-claude-open.sh sends it, with the calling pane id and its
# session). A zsh function, not another nix script, so claude resolves to the
# shim above — a bash script would have to re-enter an interactive zsh to get it.
#
# --fork-session copies the caller's history into a NEW session id, so the two
# panes diverge instead of writing over each other.
claude-pane-menu() {
  local key
  print -P "\n  %B${PWD:t}%b · forked from $1\n"
  print "    [enter]  fork that session"
  print "    [n]      new session"
  print "    [r]      resume a session…\n"
  read -s -k 1 "key?  ctrl-c for a plain shell › "
  print
  case $key in
    n | N) claude ;;
    r | R) claude --resume ;;
    *) claude --resume "$2" --fork-session ;;
  esac
}

# claude-local: Claude Code → oMLX on localhost:8000 (M3 Pro, MLX backend, Anthropic-native)
# Qwen3.6-27B-4bit (~15 GB resident, reasoning model — replies via reasoning_content).
# oMLX has its own admin auth; localhost verification is disabled (skip_api_key_verification=true),
# so ANTHROPIC_API_KEY is a placeholder.
alias claude-local='ANTHROPIC_BASE_URL=http://localhost:8000 ANTHROPIC_API_KEY=omlx-local ANTHROPIC_MODEL=Qwen3.6-27B-4bit command claude --dangerously-skip-permissions --remote-control'

# claude-beast: Claude Code → Beast gemma4:e4b (RTX 3080 Ti) via litellm proxy (port 4001)
alias claude-beast='ANTHROPIC_BASE_URL=http://localhost:4001 ANTHROPIC_API_KEY=litellm-local ANTHROPIC_MODEL=openai/gemma4:e4b command claude --dangerously-skip-permissions --remote-control'

# claude-direct: CC → api.anthropic.com (no Aperture), which is also the ONLY way
# Remote Control runs — it refuses any custom endpoint. A plain env prefix is
# enough now that the gate is a wrapper default (home/claude.nix) instead of a
# claude-settings.json env entry; the old --settings form could not win over that
# entry, so this alias silently stayed on the gate and never got Remote Control.
alias claude-direct='ANTHROPIC_BASE_URL=https://api.anthropic.com command claude --dangerously-skip-permissions --remote-control'

# pi: pi-coding-agent via Aperture → tiny-llm-gate → codex-proxy / beast Ollama.
# All routes go through https://ai.gate-mintaka.ts.net for observability.
# Pass any tlg model id as $1 to override the default, e.g.
#   pi                  → default (Qwen3.6-27B-4bit on Mac, gpt-5.5 elsewhere)
#   pi gemma4:e4b       → beast Ollama
#   pi gpt-5.5          → Codex subscription
# Defaults to local MLX on Mac, codex elsewhere. Override with --model:
#   pi "prompt"               → default model
#   pi --model gemma4:e4b "prompt"  → override model
#   pi --help / --resume      → flags just work
if [[ "$OSTYPE" == darwin* ]]; then
  pi() { command pi --provider aperture --model Qwen3.6-27B-4bit "$@"; }
else
  pi() { command pi --provider aperture --model gpt-5.5 "$@"; }
fi

# dsh: DeepSeek Harness, same Aperture route as pi (the provider lives in
# ~/.dsh/cordis.patch.yml, so there is no --provider flag to pass here).
# dsh has no TUI — the interactive surface is the Web UI, served on the tailnet
# by hosts/rpi5/dsh.nix. What is useful from a shell is the one-shot runner:
#   dsh-run "run the tests"   → one fresh persisted session, prints the answer
# It exits 0 on completion and 1 otherwise, so it composes in scripts.
dsh-run() { command dsh --profile headless "$@"; }
