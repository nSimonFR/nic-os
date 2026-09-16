# Staging — reaching the cluster, and writing to the mutualised PG

Triggers: `i/o timeout` on `tailscale-operator-staging` · `proxy-staging` · both tunnels on
`8888` · `x509: certificate signed by unknown authority` · about to write to staging and unsure
which cluster you are on · `permission denied for table <x>` · multi-schema data fix ·
`postgres_staging_rw` down.

## Two ways in, and they fight over a port

| Path | Context | Notes |
| --- | --- | --- |
| Tailscale operator | `trusk-staging-ts` | Needs the **work** tailscaled (see `kubectl contexts` in the main file — two daemons run side by side on the Mac). |
| IAP tunnel | `gke_trusk-staging-3rpyod_europe-west1_trusk-staging-gke` | `proxy-staging`. Works with no tailnet at all. |

`proxy-staging` and `proxy-prod` **both** bind `-L$TRUSK_PROXY_PORT`, which is `8888`
(`home/dotfiles/zsh/trusk.zsh`). With a prod tunnel already up, the staging one **fails to bind,
exits 0, and still creates its socket** — and everything on `localhost:8888` then reaches
**production's** control plane.

On 2026-09-16 the only thing that surfaced it was `x509: certificate signed by unknown authority`
(staging's CA presented against prod's cert). Had the CAs matched, a `kubectl patch` aimed at
staging would have hit prod. **The socket file proves nothing.** `lsof -nP -iTCP:8888 -sTCP:LISTEN`
plus socket mtimes tell you which tunnel owns the port.

The simplest fix is to not overlap: `proxy-prod-down` first, then `proxy-staging`, and the
standard `8888` vars apply. If you genuinely need both at once, put staging on its own port —
and **export the proxy vars for that port yourself**, because `proxy-up` hardcodes
`TRUSK_PROXY_PORT=8888` and would keep pointing you at prod:

```bash
PORT=8899
gcloud beta compute ssh trusk-staging-gke-bastion --tunnel-through-iap \
  --project trusk-staging-3rpyod --zone europe-west1-c \
  -- -fNT -M -S /tmp/trusk-staging-$PORT.socket -L$PORT:127.0.0.1:8888 -o ServerAliveInterval=60
# proxy-up would re-export 8888 → do it by hand, all four casings (Go reads the uppercase first)
export http_proxy=http://localhost:$PORT https_proxy=http://localhost:$PORT \
       HTTP_PROXY=http://localhost:$PORT HTTPS_PROXY=http://localhost:$PORT
```

## Assert the cluster before any write — and fail closed

`production` exists only on prod; staging has `staging` + `pr-*`. The naive one-liner
(`kubectl get ns production && exit`) **fails open**: a dead tunnel, expired creds, DNS or TLS
error also returns non-zero, the guard is skipped, and the script proceeds exactly as if staging
had been verified. Distinguish "namespace absent" from "could not ask":

```bash
assert_staging() {
  local out rc
  out=$(kubectl --context "$CTX" get ns production 2>&1); rc=$?
  if   [ $rc -eq 0 ];                             then echo "C'EST LA PROD — STOP"; return 3
  elif printf '%s' "$out" | grep -q 'NotFound';   then :   # vraiment staging
  else echo "cluster indeterminable: $out";            return 4   # tunnel/creds/TLS
  fi
  kubectl --context "$CTX" get ns staging >/dev/null 2>&1 || { echo "pas de ns staging"; return 5; }
}
assert_staging || exit $?
```

Only the `NotFound` **plus** a present `staging` namespace counts as a pass.

## Writing to the mutualised PG

Staging monodb is `10.106.0.3`, database `trusk_staging`, one schema + one app role per service;
per-service creds in `deployment/configurations/staging/secrets/` (sops).

**Default path — the maintenance role, and it is atomic.** `postgres_staging_rw`
(`home/mcp.nix`) connects as `mcp_readwrite`, which holds `pg_write_all_data` on
`trusk_staging` in unrestricted mode. It writes **every** schema, so a multi-schema data fix runs
as **one transaction**. Use it whenever it is up — it is strictly better than the fallback below.
It needs the corp VPN (the wrapper unsets the proxy vars on purpose) and is `ask`-gated per call.

**Fallback — per-service pods, and it is NOT atomic.** When 10.106.0.3 is unreachable (no VPN)
*and* the MCP is down, `kubectl exec` + the in-image `pg` driver is the way in. NestJS services
ship `pg` via TypeORM, so it is in every service image. But then you inherit the app roles'
scope: **each one only WRITES its own schema.**

Cross-schema `SELECT` *is* granted — `service-onfleet` reads `journey_trusk_order.mission` fine,
in staging **and** prod, which is what makes a cross-service backfill migration viable. `UPDATE`
is not: `permission denied for table <x>`. So the fix has to be split per owning pod —
`roundtrip.*` from `roundtrip`, `journey_trusk_order.*` from `order-mission`, `fleet.*` from
`fleet`, `onfleet.*` from `service-onfleet` — with **no cross-schema transaction**, so a 4-pod
sequence can half-apply. On 2026-09-16 that is why the IN-698 test dataset was narrowed to what a
single pod could write, instead of shifting dates across four schemas.

Probe before writing rather than discover it mid-script:

```bash
kubectl --context "$CTX" -n staging exec <pod> -c <svc> -- node -e '
const {Client}=require("pg");const c=new Client({host:process.env.POSTGRES_URL,user:process.env.POSTGRES_USER,
password:process.env.POSTGRES_PASSWORD,database:process.env.POSTGRES_DB});
(async()=>{await c.connect();console.log((await c.query(
 "SELECT current_user, has_table_privilege($1,\x27UPDATE\x27) AS can_write",["roundtrip.point"])).rows[0]);
await c.end()})()'
```
