#region git aliases
g() {
  if [ $# -eq 0 ];then
    git status
  else
    git $*
  fi
}
compdef g='git'

gb() {
  BRANCH=$(git branch -r --sort=-committerdate | sed 's/.*origin\///' | grep $1 | head -1)
  git checkout ${BRANCH}
}
#endregion

#region gh tools
pr() {
  gh pr checkout $1
  gh pr view --web
}

issue() {
  IFS="#" read BRANCH ISSUE <<< $(git rev-parse --abbrev-ref HEAD)
  gh issue view --web $ISSUE
}

createpr() {
  IFS="#" read BRANCH ISSUE <<< $(git rev-parse --abbrev-ref HEAD)
  if [ ! -z "$1" ]; then
    BODY="Closes $1"
  elif [ ! -z "$ISSUE" ]; then
    BODY="Closes #$ISSUE"
  else
    BODY=" "
  fi
  URL=$(gh pr create -t $BRANCH -a "@me" --draft -b $BODY)
  echo Opening $URL
  open $URL
}
#endregion

#region JWT
decode_base64_url() {
  local len=$((${#1} % 4))
  local result="$1"
  if [ $len -eq 2 ]; then result="$1"'=='
  elif [ $len -eq 3 ]; then result="$1"'='
  fi
  echo "$result" | tr '_-' '/+' | openssl enc -d -base64
}

decode_jwt(){
   decode_base64_url $(echo -n $2 | cut -d "." -f $1) | jq .
}
alias jwth="decode_jwt 1" # Decode JWT header
alias jwtp="decode_jwt 2" # Decode JWT Payload
#endregion

function stash() {
  git stash save
  sh $@
  git stash pop
}

#region file management
function extract {
  echo Extracting $1 ...
  if [ -f $1 ] ; then
    case $1 in
      *.tar.bz2)   tar xjf $1  ;;
      *.tar.gz)    tar xzf $1  ;;
      *.bz2)       bunzip2 $1  ;;
      *.rar)       unrar x $1    ;;
      *.gz)        gunzip $1   ;;
      *.tar)       tar xf $1   ;;
      *.tbz2)      tar xjf $1  ;;
      *.tgz)       tar xzf $1  ;;
      *.zip)       unzip $1   ;;
      *.Z)         uncompress $1  ;;
      *.7z)        7z x $1  ;;
      *)        echo "'$1' cannot be extracted via extract()" ;;
    esac
  else
    echo "'$1' is not a valid file"
  fi
}

function trash () {
  local path
  for path in "$@"; do
    # ignore any arguments
    if [[ "$path" = -* ]]; then :
    else
      local dst=${path##*/}
      # append the time if necessary
      while [ -e ~/.Trash/"$dst" ]; do
        dst="$dst "$(date +%H-%M-%S)
      done
      /bin/mv "$path" ~/.Trash/"$dst"
    fi
  done
}

function strip_diff_leading_symbols {
  local color_code_regex="(\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K])"

  # simplify the unified patch diff header
  sed -r "s/^($color_code_regex)diff --git .*$//g" | \
    sed -r "s/^($color_code_regex)index .*$/\n\1$(rule)/g" | \
    sed -r "s/^($color_code_regex)\+\+\+(.*)$/\1+++\5\n\1$(rule)\x1B\[m/g" |\

  # actually strips the leading symbols
  sed -r "s/^($color_code_regex)[\+\-]/\1 /g"
}

random_file() {
  find ${*:-.} -type f | shuf | head -n 1
}
#endregion

#region other tools
rule () {
  printf "%$(tput cols)s\n"|tr " " "─"
}

sup() {
  su -c "$*"
}

zcode() {
  (z $* && code .)
}

clip() {
  pbcopy
}
#endregion
