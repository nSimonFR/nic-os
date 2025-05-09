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
