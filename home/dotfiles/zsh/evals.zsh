(( $+commands[atuin] )) && eval "$(atuin init zsh)" && eval "$(atuin ai init zsh)"
# Initialize zoxide but only alias cd in truly interactive shells
# This prevents errors in Claude Code and other non-interactive contexts
if (( $+commands[zoxide] )); then
  eval "$(zoxide init zsh)"
  # Only alias cd to z in interactive shells with a tty
  [[ -o interactive ]] && [[ -t 0 ]] && alias cd="z"
fi
