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

# home-manager packages: deliberately NOT set here. `home.sessionPath` in
# home/default.nix already puts both HM profiles on PATH via hm-session-vars.sh,
# which .zshenv sources before this file runs — and it puts the *authoritative*
# one (`home.profileDirectory`) first. Re-prepending the standalone profile here
# undid that ordering, so under the NixOS module every binary the two profiles
# share resolved to whatever the last `home-manager switch` left behind.

# Mac-OS specific so path will be ignored on other systems
export PATH=/opt/homebrew/bin:$PATH
