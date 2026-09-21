# `atuin init zsh` emits the `?` AI binding itself (zle self-atuin-ai-question-mark
# -> `atuin ai inline --hook`), opt out with `--disable-ai`. The separate
# `atuin ai init zsh` this used to chain (aecf476, when the feature was new) is
# gone from the CLI — `atuin ai` only has `inline` — so it printed
# "error: unrecognized subcommand 'init'" on every new interactive shell.
(( $+commands[atuin] )) && eval "$(atuin init zsh)"
# Initialize zoxide but only alias cd in truly interactive shells
# This prevents errors in Claude Code and other non-interactive contexts
if (( $+commands[zoxide] )); then
  eval "$(zoxide init zsh)"
  # Only alias cd to z in interactive shells with a tty
  [[ -o interactive ]] && [[ -t 0 ]] && alias cd="z"
fi
