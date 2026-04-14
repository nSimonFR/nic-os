export TERM=xterm-256color
export EDITOR='vim'

export GPG_TTY=$(tty)
export LC_COLLATE=C
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

export PAGER='less'
export LESS='--ignore-case --raw-control-chars'

export HUSKY=0
export HUSKY_SKIP_HOOKS=1

export CLICOLOR=1
export LSCOLORS=Gxfxcxdxbxegedabagacad
export GREP_OPTIONS='--color=auto'
export GREP_COLOR='3;33'

export ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=50
export ZSH_AUTOSUGGEST_MANUAL_REBIND=1

export AUTO_NOTIFY_THRESHOLD=60
export AUTO_NOTIFY_EXPIRE_TIME=5000

export USE_GKE_GCLOUD_AUTH_PLUGIN=True

# home-manager packages (needed when integrated with nix-darwin)
export PATH="$HOME/.local/state/nix/profiles/home-manager/home-path/bin:$PATH"

# Mac-OS specific so path will be ignored on other systems
export PATH=/opt/homebrew/bin:$PATH

# LLM traffic interceptor (mitmproxy on rpi5, port 9092)
# Captures Claude Code + other LLM calls to web UI at https://rpi5.gate-mintaka.ts.net:8001
export HTTPS_PROXY="http://rpi5:9092"
export NODE_EXTRA_CA_CERTS="$HOME/.local/share/llm-interceptor/mitmproxy-ca-cert.pem"
