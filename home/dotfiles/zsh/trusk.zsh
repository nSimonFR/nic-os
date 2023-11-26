# TODO Switch with yours
SED=gsed

function greset() {
  if [ `git branch --list main` ]; then
    BRANCH="main"
  elif [ `git branch --list develop` ]; then
    BRANCH="develop"
  else
    BRANCH="master"
  fi

  git checkout $BRANCH && git fetch && git rebase origin/$BRANCH
}

function get-version() {
  if [ $# -eq 0 ]
    then base=.
    else base=$1
  fi
  cat ./$base/package.json | jq -r '.version'
}

function submodule_states() {
  git submodule foreach -q 'echo $(basename $(pwd))@$(git rev-parse --abbrev-ref HEAD)'
}

function reset_branches() {
  git fetch -q
  git checkout -q master && git rebase -q origin/master
  git checkout -q develop && git rebase -q origin/develop
}

function _package_submodule() {
  # Automatic repo release and tag, respecting gitflow + trusk patterns.

  # Requires:
  # - cg (https://www.npmjs.com/package/corgit)
  # - gh (https://github.com/cli/cli)

  # TODO Ask if rebase or drop branch
  if [ ! `git branch --list release/$VER` ]; then
    git checkout -q -b release/$VER develop && \
    git stash pop -q && \
    git add package* CHANGELOG.md deployment && \
    git commit -q -m "Feature(Version): bump to $VER" --no-verify >/dev/null
  else
    git stash drop -q && \
    git checkout release/$VER >/dev/null && \
    git rebase -q origin/develop >/dev/null 2>/dev/null
  fi
  git push --force --no-progress -q -u origin >/dev/null 2>/dev/null
  gh pr create -a @me -B master -t $(git rev-parse --abbrev-ref HEAD) -b '' --draft 2>/dev/null
  IMAGE=`basename \`pwd\``
  VERSION=`git rev-parse --abbrev-ref HEAD | $SED "s/[^a-z0-9_]/-/ig"`
  (
    cd .. && \
    $SED -i -E "s/$IMAGE(.*):develop/$IMAGE\1:$VERSION/g" docker-compose.fr.staging.yml && \
    git add $IMAGE docker-compose.*
  )
  gh pr list --state merged --json url -q '.[].url' | xargs linear_move "Acceptance Test" "Release Candidate"
}

function _prepare_package() {
  VER=`get-version`
  $SED -i "s/tag: [0-9.]*/tag: $VER/" deployment/charts/production.yaml
  $SED -i "s/tag: [0-9.]*/tag: $VER/" deployment/charts/default.yaml
  git add package* CHANGELOG.md deployment
  git stash save -q "psub $VER"
}

function package_submodule() {
  reset_branches
  touch CHANGELOG.md
  cg bump >/dev/null
  _prepare_package
  _package_submodule
}

function release_candidate() {
  # Automatic release_candidate creation
  # Only-run while being in a monorepo (not a submodule)

  # Optional command (Will prevent husky warnings):
  # git submodule -q foreach 'npm install --silent && git restore -q package-lock.json'
  setopt LOCAL_OPTIONS NO_NOTIFY

  if [[ $(git rev-parse --abbrev-ref HEAD) != *"release"* ]]; then
    reset_branches
    CURRENT_VER=$(git describe --tags --abbrev=0)
    read "VER?New version for $(basename $(pwd)) (current: $CURRENT_VER) ? "
    git checkout -b release/$VER
    npm version -no-git-tag-version $VER >/dev/null
    git add package*
    git commit -m "Feature(Version): bump version to $VER" --no-verify
  else
    VER=$(git rev-parse --abbrev-ref HEAD | cut -d '/' -f2)
  fi

  LINEAR_ISSUES=$(mktemp)
  echo "Linear moved issue:" > $LINEAR_ISSUES

  for DIR in $(git submodule -q foreach -q sh -c pwd); do
  (
    cd $DIR
    git checkout -q develop 2>/dev/null
    git fetch -q
    if ! git rebase -q origin/develop 2>/dev/null; then
      echo "$(basename $DIR) - ERROR: no action done (Local changes ?)"
    elif ! git show -q --summary HEAD | grep -q ^Merge; then
      touch CHANGELOG.md
      if ! cg bump >/dev/null 2>/dev/null; then
        echo "$(basename $DIR) - CG BUMP ERROR: no action done (Local changes ?)"
      else
        VER=`get-version`
        _prepare_package

        echo "`basename $DIR`:"
        gh pr list --state merged --json url -q '.[].url' | xargs linear_list "Acceptance Test" "Release Candidate"

        read -q "REPLY?Bump to $VER? (y/N) "
        echo ""

        if [[ "$REPLY" = "Y" ]] || [[ "$REPLY" = "y" ]]; then
          _package_submodule >> $LINEAR_ISSUES
          exit
        else
          git restore .
        fi
      fi
    fi
    # Else, apply production version
    IMAGE=`echo $DIR | rev | cut -d "/" -f 1 | rev`
    VERSION=`cat ../docker-compose.fr.production.yml | grep "/.*$IMAGE.*:" | cut -d: -f3 | head -n 1`
    echo $IMAGE:$VERSION
    $SED -i -E "s/$IMAGE(.*):develop/$IMAGE\1:$VERSION/g" ../docker-compose.fr.staging.yml
  )
  done

  git add docker-compose.*
  git commit -m "Feature(Submodule): make_release script" --no-verify

  #git push --no-progress -q -u origin >/dev/null 2>/dev/null
  #gh pr create -a @me -B master -t $(git rev-parse --abbrev-ref HEAD) -b '' --draft 2>/dev/null

  #submodule_states
  cat $LINEAR_ISSUES
  rm $LINEAR_ISSUES
}

function validate_release() {
  setopt LOCAL_OPTIONS NO_NOTIFY

  VER=$(git rev-parse --abbrev-ref HEAD | cut -d '/' -f2)
  if [[ -z "$VER" ]]; then
    echo "No pending release"
    return 1
  fi

  if [[ $(git tag | grep $VER) ]]; then
    echo "Tag $VER already exists"
    return 1
  fi

  if [[ -f "docker-compose.fr.staging.yml" ]]; then
    IMAGES=$(cat docker-compose.fr.staging.yml | grep release | $SED 's/^.*\/\(.*\):.*$/\1/g')
    echo $IMAGES | while read IMAGE; do
    (
      cd $IMAGE && \
      git fetch && \
      gb release >/dev/null && \
      validate_release && \
      reset_branches && \
      VER=`get-version` && \
      git checkout -q master && \
      $SED -i -E "s/$IMAGE(.*):[0-9]+(\.[0-9]+){2}/$IMAGE\1:$VER/g" ../docker-compose.fr.production.yml && \
      (cd .. && git add $IMAGE) || exit 1
    )
    done
    $SED -i -E "s/trusk-production\/(.*):..*/trusk-production\/\1:develop/g" docker-compose.fr.staging.yml && \
    git add $IMAGE docker-compose.* && \
    git commit -m "Feature(Submodule): validate_release script" --no-verify
  fi

  echo "Bumping $(basename $(pwd)) to $VER"
  #return 1 # uncomment for dry-run

  git checkout -q master && git rebase -q && \
  git merge -q --no-ff release/$VER -m "Feature(Version): merge branch 'release/$VER' into master" --no-verify && \
  git tag $VER && \
  git checkout -q develop && \
  git merge -q --no-ff $VER -m "Feature(Version): merge tag '$VER' into develop" --no-verify && \
  git branch -q -D release/$VER && \
  git push -q origin develop master --tags >/dev/null && \
  gh release create $VER --generate-notes #&& \
  #gh pr list --state merged --json url -q '.[].url' | xargs linear_move "Release Candidate" "In production"
}

export HOST=fr
export ENV=development
export TRUSK_NPM_TOKEN=""

alias dc-mongo='dc exec mongo-db mongo trusk'
alias dc-redis='dc exec redis-server redis-cli'
alias dc-pgres='dc exec postgres-db psql -U postgres'

alias k-seal="kubeseal -o yaml --controller-namespace sealed-secrets-system --controller-name sealed-secrets-sealed-secrets-operator"

alias proxy-up="export http_proxy=localhost:8888 https_proxy=localhost:8888"
alias proxy-prod="gcloud beta compute ssh trusk-production-gke-bastion --tunnel-through-iap --project trusk-production-kkypwi --zone europe-west1-c -- -L8888:127.0.0.1:8888"
alias proxy-staging="gcloud beta compute ssh trusk-staging-gke-bastion --tunnel-through-iap --project trusk-staging-3rpyod --zone europe-west1-c -- -L8888:127.0.0.1:8888 -o ServerAliveInterval=60"
alias proxy-db="gcloud beta compute ssh trusk-production-gke-bastion --tunnel-through-iap --project trusk-production-kkypwi --zone europe-west1-c"

alias trusk-staging-rabbit="gcloud beta compute ssh bastion-lzrn --project trusk-playground --zone europe-west1-b -- -L15672:rabbitmq-cluster-staging-node-0:15672"
alias trusk-staging-postgres="gcloud beta compute ssh bastion-lzrn --project trusk-playground --zone europe-west1-b -- -L5432:10.104.48.13:5432"
