(( $+commands[atuin] )) && eval "$(atuin init zsh)" && atuin login 1> /dev/null
(( $+commands[zoxide] )) && eval "$(zoxide init zsh)" && alias cd="z"
