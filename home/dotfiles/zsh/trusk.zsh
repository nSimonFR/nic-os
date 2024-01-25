# TODO Switch with yours
SED=sed

function gmaster() {
  BRANCH="master"
  git checkout $BRANCH && git fetch && git rebase origin/$BRANCH
}

function gmain() {
  BRANCH="master"
  git checkout $BRANCH && git fetch && git rebase origin/$BRANCH
}

function gdevelop() {
  BRANCH="master"
  git checkout $BRANCH && git fetch && git rebase origin/$BRANCH
}

function get-version() {
  if [ $# -eq 0 ]
    then base=.
    else base=$2
  fi
  cat ./$base/package.json | jq -r '.version'
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
