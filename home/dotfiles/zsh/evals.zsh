eval $(thefuck --alias)

eval "$(atuin init zsh)"
atuin login 1> /dev/null

eval "$(zoxide init zsh)"
alias cd="z"
