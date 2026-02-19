alias ai="cursor-agent --force"
alias e="cursor" # My current main editor
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

# Rebuild the current machine's NixOS/nix-darwin configuration
rebuild-os() {
  local repo=~/nic-os
  case "$(hostname)" in
    BeAsT)     (cd "$repo" && sudo nixos-rebuild switch --flake path:.#BeAsT) ;;
    rpi5)      (cd "$repo" && sudo nixos-rebuild switch --flake path:.#rpi5) ;;
    nBookPro)  (cd "$repo" && sudo darwin-rebuild switch --flake path:.#nBookPro && sudo yabai --load-sa) ;;
    *)         echo "Unknown machine: $(hostname)" ;;
  esac
}

# Cross-platform clipboard aliases
if [[ "$OSTYPE" == darwin* ]]; then
  alias copy="pbcopy"
  alias paste="pbpaste"
elif [[ -n "$WAYLAND_DISPLAY" ]]; then
  alias copy="wl-copy"
  alias paste="wl-paste"
elif [[ -n "$DISPLAY" ]]; then
  alias copy="xclip -selection clipboard"
  alias paste="xclip -selection clipboard -o"
fi
