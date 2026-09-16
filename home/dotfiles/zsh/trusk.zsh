export ENV=development

alias dc-mongo='dc exec mongo-db mongo trusk'
alias dc-redis='dc exec redis-server redis-cli'
alias dc-pgres='dc exec postgres-db psql -U postgres'

# Local bind ports for the bastion tunnels. DISTINCT per environment on purpose.
#
# They used to share 8888. Whichever tunnel came second lost the bind — but ssh
# carried on, exited 0 and left its control socket behind, so `localhost:8888`
# silently kept pointing at the OTHER cluster. On 2026-09-16 the only thing that
# surfaced it was an x509 error (staging's CA against prod's cert); with matching
# CAs a kubectl aimed at staging would have hit production. Distinct ports make
# that impossible: 8888 is only ever prod, 8889 only ever staging.
#
# The REMOTE side is always the bastion's own proxy on 127.0.0.1:8888 — only the
# local bind differs. Details: notes/staging-access-and-writes.md.
#
# The Claude Aperture shim used to squat 8888; it now lives on 18888
# (home/claude-aperture-shim.nix) precisely so these stay free.
export TRUSK_PROXY_PORT_PROD=8888
export TRUSK_PROXY_PORT_STAGING=8889
# Back-compat: anything still reading the old single-port variable gets prod.
export TRUSK_PROXY_PORT=$TRUSK_PROXY_PORT_PROD

# Exports BOTH cases on purpose. A Claude Code session inherits an uppercase
# HTTPS_PROXY pointing at the shim, and Go tools (kubectl, gcloud's helpers)
# prefer the uppercase form — so setting only the lowercase vars leaves kubectl
# talking to the shim, which allow-lists api.anthropic.com and answers every
# other host with a TLS handshake timeout.
proxy-up() {
  local port=${1:-$TRUSK_PROXY_PORT}
  export http_proxy=http://localhost:$port https_proxy=http://localhost:$port \
         HTTP_PROXY=http://localhost:$port HTTPS_PROXY=http://localhost:$port
  print -r -- "proxy → localhost:$port"
}
alias proxy-down='unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY'

# Does something already answer as a working forward proxy on this port?
# The socket file proves nothing (it outlives a failed bind) — ask the proxy.
_trusk_proxy_alive() {
  [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' -x "http://localhost:$1" \
        https://www.googleapis.com/generate_204 2>/dev/null)" = "204" ]
}

# ExitOnForwardFailure=yes is the load-bearing flag: without it ssh keeps going
# when the local bind fails, exits 0, and you proxy to whoever owned the port.
_trusk_tunnel() { # <host> <project> <zone> <socket> <localport> [remote]
  local host=$1 project=$2 zone=$3 socket=$4 port=$5 remote=${6:-127.0.0.1:8888}
  # Only the cluster tunnels forward the bastion's HTTP proxy, so only those can
  # be probed this way. A Postgres or RabbitMQ forward would never answer 204.
  if [ "$remote" = "127.0.0.1:8888" ] && _trusk_proxy_alive "$port"; then
    print -r -- "tunnel déjà actif sur $port, réutilisé"
    return 0
  fi
  gcloud beta compute ssh "$host" --tunnel-through-iap --project "$project" --zone "$zone" \
    -- -fNT -M -S "$socket" -L"$port:$remote" \
       -o ExitOnForwardFailure=yes -o ServerAliveInterval=60
}

proxy-prod() {
  gcloud container clusters get-credentials trusk-production-gke --region europe-west1 --project trusk-production-kkypwi &&
  _trusk_tunnel trusk-production-gke-bastion trusk-production-kkypwi europe-west1-c \
    /tmp/trusk-production-gke-bastion.socket "$TRUSK_PROXY_PORT_PROD" &&
  proxy-up "$TRUSK_PROXY_PORT_PROD"
}
alias proxy-prod-down="unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY && ssh -S /tmp/trusk-production-gke-bastion.socket -O exit trusk-production-gke-bastion -q"

proxy-staging() {
  gcloud container clusters get-credentials trusk-staging-gke --region europe-west1 --project trusk-staging-3rpyod &&
  _trusk_tunnel trusk-staging-gke-bastion trusk-staging-3rpyod europe-west1-c \
    /tmp/trusk-staging-gke-bastion.socket "$TRUSK_PROXY_PORT_STAGING" &&
  proxy-up "$TRUSK_PROXY_PORT_STAGING"
}
alias proxy-staging-down="unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY && ssh -S /tmp/trusk-staging-gke-bastion.socket -O exit trusk-staging-gke-bastion -q"

# Postgres tunnels. Each gets its OWN control socket — they used to reuse the
# prod bastion's, so opening one while the main prod tunnel was up died on
# "ControlSocket already exists", and they collided with each other on 5432 too.
# They still share 5432 by design (one at a time); ExitOnForwardFailure now says
# so out loud instead of leaving you pointed at the previous database.
_trusk_pg_tunnel() { # <socket-name> <ip>
  _trusk_tunnel trusk-production-gke-bastion trusk-production-kkypwi europe-west1-c \
    "/tmp/trusk-prod-pg-$1.socket" 5432 "$2:5432"
}
alias proxy-prod-postgres-api='_trusk_pg_tunnel api "$TRUSK_POSTGRES_API_IP" && proxy-up "$TRUSK_PROXY_PORT_PROD"'
alias proxy-prod-postgres-common='_trusk_pg_tunnel common "$TRUSK_POSTGRES_COMMON_IP" && proxy-up "$TRUSK_PROXY_PORT_PROD"'
alias proxy-prod-postgres-cresus='_trusk_pg_tunnel cresus "$TRUSK_POSTGRES_CRESUS_IP" && proxy-up "$TRUSK_PROXY_PORT_PROD"'
alias proxy-prod-postgres-down="for s in api common cresus; do ssh -S /tmp/trusk-prod-pg-\$s.socket -O exit trusk-production-gke-bastion -q 2>/dev/null; done"

alias trusk-staging-rabbit="_trusk_tunnel bastion-lzrn trusk-playground europe-west1-b /tmp/bastion-lzrn-rabbit.socket 15672 rabbitmq-cluster-staging-node-0:15672 && proxy-up \$TRUSK_PROXY_PORT_STAGING"
alias trusk-staging-postgres="_trusk_tunnel bastion-lzrn trusk-playground europe-west1-b /tmp/bastion-lzrn-pg.socket 5432 10.104.48.13:5432 && proxy-up \$TRUSK_PROXY_PORT_STAGING"
alias proxy-tools-down="unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY && for s in rabbit pg; do ssh -S /tmp/bastion-lzrn-\$s.socket -O exit bastion-lzrn -q 2>/dev/null; done"

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
