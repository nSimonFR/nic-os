
export HOST=fr
export ENV=development
export TRUSK_NPM_TOKEN=""

alias dc-mongo='dc exec mongo-db mongo trusk'
alias dc-redis='dc exec redis-server redis-cli'
alias dc-pgres='dc exec postgres-db psql -U postgres'

alias proxy-up="export http_proxy=localhost:8888 https_proxy=localhost:8888"

alias proxy-prod="gcloud container clusters get-credentials trusk-production-gke --region europe-west1 --project trusk-production-kkypwi &&gcloud beta compute ssh trusk-production-gke-bastion --tunnel-through-iap --project trusk-production-kkypwi --zone europe-west1-c -- -fNT -M -S /tmp/trusk-production-gke-bastion.socket -L8888:127.0.0.1:8888 && proxy-up"
alias proxy-prod-postgres-api='gcloud beta compute ssh trusk-production-gke-bastion --tunnel-through-iap --project trusk-production-kkypwi --zone europe-west1-c -- -fNT -M -S /tmp/trusk-production-gke-bastion.socket -L5432:$TRUSK_POSTGRES_API_IP:5432 && proxy-up'
alias proxy-prod-postgres-common='gcloud beta compute ssh trusk-production-gke-bastion --tunnel-through-iap --project trusk-production-kkypwi --zone europe-west1-c -- -fNT -M -S /tmp/trusk-production-gke-bastion.socket -L5432:$TRUSK_POSTGRES_COMMON_IP:5432 && proxy-up'
alias proxy-prod-postgres-cresus='gcloud beta compute ssh trusk-production-gke-bastion --tunnel-through-iap --project trusk-production-kkypwi --zone europe-west1-c -- -fNT -M -S /tmp/trusk-production-gke-bastion.socket -L5432:$TRUSK_POSTGRES_CRESUS_IP:5432 && proxy-up'
alias proxy-prod-down="unset http_proxy https_proxy && ssh -S /tmp/trusk-production-gke-bastion.socket -O exit trusk-production-gke-bastion -q"

alias proxy-staging="gcloud container clusters get-credentials trusk-staging-gke --region europe-west1 --project trusk-staging-3rpyod && gcloud beta compute ssh trusk-staging-gke-bastion --tunnel-through-iap --project trusk-staging-3rpyod --zone europe-west1-c -- -fNT -M -S /tmp/trusk-staging-gke-bastion.socket -L8888:127.0.0.1:8888 -o ServerAliveInterval=60 && proxy-up"
alias proxy-staging-down="unset http_proxy https_proxy && ssh -S /tmp/trusk-staging-gke-bastion.socket -O exit trusk-staging-gke-bastion -q"

alias trusk-staging-rabbit="gcloud beta compute ssh bastion-lzrn --project trusk-playground --zone europe-west1-b -- -fNT -M -S /tmp/bastion-lzrn.socket -L15672:rabbitmq-cluster-staging-node-0:15672 && proxy-up"
alias trusk-staging-postgres="gcloud beta compute ssh bastion-lzrn --project trusk-playground --zone europe-west1-b -- -fNT -M -S /tmp/bastion-lzrn.socket -L5432:10.104.48.13:5432 && proxy-up"
alias proxy-tools-down="unset http_proxy https_proxy && ssh -S /tmp/bastion-lzrn.socket -O exit bastion-lzrn -q"

function decrypt() {
  # Decrypt a file from a path, using kubeseal.
  # Takes an env to use a proxy and a relative filepath to decrypt.
  # 
  # Usage: 
  #   decrypt [prod/staging] path/to/file.yaml # For "preview", you can use "staging"
  # 
  # Example:
  #   decrypt staging deployment/configurations/production/secrets/sealed.yaml

  eval "proxy-$1"
  PATH_TO_KEY=~/MyDocuments/TRUSK/backup-sealed-secrets-$1.key
  FILEPATH=`dirname $2`/DECRYPTED-`basename $2`
  kubectl config set-context trusk-$1 >/dev/null
  kubeseal --recovery-unseal -o yaml --recovery-private-key $PATH_TO_KEY < $2 > $FILEPATH
  eval "proxy-$1-down"
}

function encrypt() {
  # Encrypt a file from a path, using kubeseal.
  # Takes an env to use a proxy and a relative filepath to encrypt.
  # NO NEED TO PREFIX DECRYPTED-filename !
  # 
  # Usage: 
  #   decrypt [prod/staging] path/to/file.yaml # For "preview", you can use "staging"
  # 
  # Example:
  #   decrypt staging deployment/configurations/production/secrets/sealed.yaml

  eval "proxy-$1"
  FILEPATH=`dirname $2`/DECRYPTED-`basename $2`
  kubectl config set-context trusk-$1 >/dev/null
  kubeseal -o yaml --controller-namespace sealed-secrets-system --controller-name sealed-secrets-sealed-secrets-operator < $FILEPATH > $2
  rm $FILEPATH
  eval "proxy-$1-down"
}
