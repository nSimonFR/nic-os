# Trusk — global notes (Trusk-scoped: loaded only under ~/MyDocuments/TRUSK/)

Facts spanning all Trusk repos (trusk-k8s, trusk-applications, trusk-lib, services…). Per-project memory under `~/.claude/projects/<workdir>/memory/` adds local detail. **Source of truth:** `~/nic-os/home/dotfiles/trusk-CLAUDE.md` (home-manager symlinks it to this path) — edit there.

> **Keep fresh.** When you learn something future sessions need (a kubectl pattern, operator quirk, permission grant, release gotcha), propose adding/updating an entry before the conversation ends — show the diff, get the OK, write to the nic-os source. Flag stale/wrong entries for removal too.

## Repos on disk — siblings under `/Users/nsimon/MyDocuments/TRUSK/`

| Repo                                                                    | Purpose                                                                                                                                                                                                                            |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `trusk-k8s`                                                             | Cluster infra (cert-manager, datadog-operator, argocd projects/applications, `docs/flagd/*`).                                                                                                                                      |
| `trusk-applications`                                                    | ArgoCD applications + manifests per env (`applications/<env>.yaml`, `manifests/<env>/<service>/`). Umbrella renders services via the `trusk-argo-project` chart.                                                                   |
| `trusk-lib`                                                             | npm-workspaces monorepo. NestJS 11 pkgs in `nestjs-libraries/<name>/` = `@trusk-official/nestjs-*` (core, amqp, authentication, sql, health, url-shortener, business-policies, feature-flags). Legacy `nest-commons/` = NestJS 10. |
| `trusk-chart-museum`                                                    | Helm charts in `charts/<name>/` (notably `trusk-argo-project`). Pushed to GCS bucket `trusk-helm-chart` by `release.sh` on every master merge (`helm-cd.yaml`).                                                                    |
| `github-actions`                                                        | Shared reusable GH workflows (e.g. `release.yaml`, used by every service's `cd.yaml`).                                                                                                                                             |
| `<service>` (rating, identity-access-management, mobile-app-gateway, …) | Layout: `src/`, `deployment/charts/<env>.yaml`, `deployment/configurations/<env>/{configmaps,secrets}/`, sometimes `deployment/flagd/<env>/`.                                                                                      |
| `trusk-infra/<service>`                                                 | Older services pre-migration.                                                                                                                                                                                                      |
| `backoffice`                                                            | **The** live backoffice (Next.js) — use this for any BO work.                                                                                                                                                                      |

**`trusk-backoffice` and `trusk-infra/backoffice` are LEGACY — ignore entirely** (no grep, no cite, no edits). Only `backoffice` is live. Clone missing repos: `unset GH_TOKEN && gh repo clone trusk-official/<name> ~/MyDocuments/TRUSK/<name>`.

## GitHub auth — always `unset GH_TOKEN`

The active `GH_TOKEN` is the personal account `nSimonFR-ai`, which **can't see the `trusk-official` org** → bogus 404s on private repos. Prefix every git/gh command with `unset GH_TOKEN &&` to fall back to the keyring credential (`nSimonFR` work account).

```bash
unset GH_TOKEN && gh pr create ...
```

## Linear — use the `linear` skill (not the MCP)

`~/.claude/skills/linear/SKILL.md` hits the GraphQL API with a personal key. Default for any Trusk ticket op. Keys: `$LINEAR_KEY` = personal (team NSI); `$LINEAR_KEY_TRUSK` = work (use for all IN-/EXTERN-/DO- tickets). Most-used team `INTERNAL` (`key: IN`, `id: 835374eb-2c41-427f-9779-772d1b95aa0a`). For a subissue, set `parentId` to the parent's **UUID** (`issue(id:"IN-545"){ id }`), and reuse the parent's `team{id} project{id} cycle{id}` so it lands in the same context (avoids the "ended up in personal/no-project" footgun).

## ArgoCD — read via MCP, write via UI/kubectl

Staging cluster `trusk-staging-ts`, UI <https://staging-argocd.trusk.com>. **Read** via `mcp__trusk-argocd__*` (`get_application`, `list_applications`, `get_application_resource_tree`, `get_application_workload_logs`, …). MCP RBAC is per-project: restrictive projects (`staging`) may return `permission denied`; app-of-apps (`staging-gitops`) and permissive ones (`flagd`) read fine. **Write (sync/patch/restart) is NOT in the MCP** → use the UI, or kubectl directly. `nicolas.simon@trusk.com` is `trusk-admin` (cluster-admin) on **both** staging and prod (`gke_trusk-production-kkypwi_europe-west1_trusk-production-gke`). Read pattern: `get_application("staging-gitops")` → `.status.resources` lists child apps with sync + health.

## Monitor / long-job waits

For "wait then notify" (CI, ArgoCD syncs, rollouts): **Bash `run_in_background`** for one-shot exits, or **Monitor** for event streams — each stdout line = a notification, exit ends it. Don't foreground-poll; read the result with `TaskOutput`. Example:

```
Monitor: until [ "$(gh run view <ID> --json status --jq .status)" = completed ]; do sleep 15; done && echo RUN_DONE && gh run view <ID> --json conclusion --jq .conclusion
```

For "wait N minutes": `Bash(run_in_background:true)` with `sleep N && …`.

## Staging deploy flow — merge → pod live

1. **`cd.yaml`** runs at merge; its `Trusk CD` job calls a reusable `github-actions` workflow — `gh run view <id> --json jobs` shows only wrapper steps (Install/Release/Linear); the docker build/push lives inside the reusable wf (`gh api repos/<owner>/<repo>/actions/runs/<id>/jobs` for the full list).
2. **semantic-release** cuts the tag + pushes a `Chore(Version): <ver>` commit → a 2nd cd.yaml run where Trusk CD is correctly `skipped`.
3. **Image** → `europe-west1-docker.pkg.dev/trusk-tools-tpfqef/trusk-registry/<service>:<version>`. Propagation 1–2 min; expect one `ErrImagePull`→`ImagePullBackOff`→pull cycle (~30s). Only dig into wf logs if it persists past ~5 min.
4. **trusk-applications bump** is manual — see below.
5. **ArgoCD** reconciles `<env>-<service>` next sweep; old pod serves until the new one is `1/1 Running`.

## Service pod shape (staging) — two containers

- init `<service>-pgm` — runs `migration:run`, must exit 0 first (migration failures here).
- main `<service>` — `start:prod` (config / DB-connect / code crashes here).

On CrashLoopBackOff check both:

```bash
kubectl --context trusk-staging-ts -n staging logs <pod> -c <service>-pgm
kubectl --context trusk-staging-ts -n staging logs <pod> --previous
```

## Staging mutualised PG — direct access

`10.106.0.3` (corp VPN). One DB+role per service; creds in `deployment/configurations/staging/secrets/` (sops). `PGPASSWORD='<secret>' psql -h 10.106.0.3 -U <service> -d <service_db>`.

## Conventional commits → semantic-release

`@trusk-official/config-release` releaseRules come from the `type-enum` in config-commitlint. Valid PascalCase scopes: **`Feature, Fix, Docs, Style, Refactor, Test, Chore`** — `Feature`/`Refactor` → minor, rest → patch. The Angular preset also adds lowercase `feat`→minor, `fix`→patch, `BREAKING CHANGE`→major.

- **`Perf:` cuts NO release** (not in the list, not in the Angular preset) — same for any type outside the seven. Use `Fix:`/`Feature:`/lowercase `fix:` to force a bump. (Verified on fleet 2026-06-04.)
- **No Linear prefix** on commit messages _or PR titles_ unless asked — plain `Type(Scope): desc`. Repos squash-merge, so a PR title like `IN-625 Perf(…)` becomes the master commit and semantic-release can't parse it → no release, no deploy. Strip `IN-`/`EXTERN-`/`DO-` from PR titles before merge.

## Generating a service's `-client` / `-query` lib (consume a new route)

Each service publishes `@trusk-official/api-<service>-client` (raw fns, backend↔backend) and `@trusk-official/api-<service>-query` (TanStack-Query hooks, used by the backoffice) from its OpenAPI spec, via `orval-client-generator` + the reusable `generate-apiclient.yaml`. Two service workflows:

- `generate-apiclient.yaml` (`on: push: tags`) → real versioned client+query on every release tag.
- `generate-PR-apiclient.yaml` (`on: pull_request`, gated by the **`need client API`** label) → prerelease `<ver>-pr.<PR#>.<run>.<attempt>`.

Use a not-yet-merged route in the backoffice: (1) `gh pr edit <PR#> --add-label "need client API"` on the service repo; (2) wait for "Generate PR client", read the version via `npm view @trusk-official/api-<service>-query versions --json | tail`; (3) bump the dep to that `-pr.*` version + `npm install`; (4) import the orval hook (`use<Tag><Method>`, e.g. `Mission`/`resync` → `useMissionResync`). After merge, bump to the clean released version.

## Code style — brace every `if`

Always brace `if` bodies, even one-liners. No `if (cond) doThing();`. All Trusk TS repos.

## trusk-applications bumps — commit straight to master, no PR

`targetRevision` doesn't auto-bump after a release. **Push directly to `master`** (Nicolas 2026-06-03: PRs are needless churn + branch protection blocks non-admin merges anyway). Message: `Chore(Staging): bump <service> to <version>` / `Chore(Production): …`; diff is one line in `applications/<env>.yaml`. If a PR was already opened: `gh pr merge <n> --rebase --delete-branch --admin` (squash disabled here).

## kubectl contexts

- **Staging** — `trusk-staging-ts` (Tailscale operator), works directly.
- **Production** — no Tailscale; run the `proxy-prod` alias once/session (opens an IAP tunnel + SOCKS/HTTP proxy on `localhost:8888`), then `export http_proxy=localhost:8888 https_proxy=localhost:8888` and use ctx `gke_trusk-production-kkypwi_europe-west1_trusk-production-gke`. Socket `/tmp/trusk-production-gke-bastion.socket` = readiness signal (direct GKE ctx times out on TLS — private control plane).

`proxy-prod` is an interactive-shell alias and long-running. Run it autonomously via **`zsh -ic 'proxy-prod'`** in `Bash(run_in_background:true)` (don't block on it; may prompt for gcloud auth if tokens are stale), then poll for the socket:

```bash
for i in $(seq 1 60); do [ -S /tmp/trusk-production-gke-bastion.socket ] && { echo up; break; }; sleep 2; done
```

The socket is system-wide → any later Bash call uses the proxy by exporting the http(s)\_proxy vars.

### Prod mutualised PG (via pod env)

Prod PG = **`10.206.0.21`** (since 2026-06-10; old `10.206.0.11` is DEAD). **Always use DNS `postgres-trusk-production`** (ExternalName Svc in `production`, follows IP moves), not the raw IP. Charts hardcoding the old IP fail — when rolling back to such a tag, append `POSTGRES_URL=postgres-trusk-production` on both the main container and initContainer (duplicate env names OK — last wins):

```bash
kubectl --context "$CTX" -n production patch deployment <svc> --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"POSTGRES_URL","value":"postgres-trusk-production"}},
  {"op":"add","path":"/spec/template/spec/initContainers/0/env/-","value":{"name":"POSTGRES_URL","value":"postgres-trusk-production"}}]'
```

`psql` isn't in the Node alpine images — run ad-hoc SQL via the in-image `pg` driver:

```bash
kubectl --context "$CTX" -n production exec <pod> -c <main> -- node -e '
const {Client}=require("pg");
const c=new Client({host:process.env.POSTGRES_URL,user:process.env.POSTGRES_USER,password:process.env.POSTGRES_PASSWORD,database:process.env.POSTGRES_DB});
(async()=>{await c.connect(); /* ... */ await c.end();})().catch(e=>{console.error(e.message);process.exit(1)});'
```

For out-of-band schema mutations, also insert the `<schema>._migrations` row (`{id,timestamp,name}`) so the next deploy's init container skips re-running it.

## Datadog FM + dd-trace flaggingProvider — required env vars

`tracer.init({ experimental:{ flaggingProvider:{ enabled:true }}})` is necessary but **not sufficient** — FM allocation matching uses Unified Service Tagging, so the pod env MUST set:

```yaml
- { name: DD_SERVICE, value: <service-name> } # match package.json + DD catalog
- { name: DD_ENV, value: <env> } # production / staging
- { name: DD_VERSION, value: "<x.y.z>" } # hardcoded today
```

Without them, FM returns `client_configs: []` and `@datadog/openfeature-node-server` times out after 30s (`Initialization timeout after 30000ms`) → crashloop. `DD_REMOTE_CONFIGURATION_ENABLED` defaults true in dd-trace 5.x; the agent key needs `remote_config_read`. No other prod service sets these yet (none use `flaggingProvider`); ref `identity-access-management/deployment/charts/production.yaml`. Flag eval also needs a configured FM **allocation rule** per flag — see project memory `reference_datadog_feature_management.md`.

## nestjs-sql LockService = TypeORM pool deadlock under concurrency (TEC-105)

Related (same day): the Nest11 `nestjs-core` logger reads `LOGGER_LEVEL` (default `error`) and ignores the legacy `LOG_LEVEL` still in the infra-env configmap → migrated services log error-only (Datadog still works). Fix = add `LOGGER_LEVEL` to infra-env configmaps (TEC-104).

## flagd kill-switch

OpenFeature Operator on `trusk-staging-ts`; FeatureFlag CRDs in ns `flagd`, one per service (`<service>/deployment/flagd/<env>/featureflag.yaml`), with a companion ArgoCD app when the umbrella entry has `flagd: { enabled: true }`. Flip via `defaultVariant` (patches stick — the companion app has `ignoreDifferences` on `.spec.flagSpec.flags[].state` / `.defaultVariant`):

```bash
kubectl --context trusk-staging-ts -n flagd patch featureflag <name> --type=merge \
  -p '{"spec":{"flagSpec":{"flags":{"<flag>":{"defaultVariant":"off","state":"ENABLED","variants":{"on":true,"off":false}}}}}}'
# verify on any annotated pod's sidecar (~<1s):
kubectl --context trusk-staging-ts -n <ns> exec <pod> -c <main> -- \
  sh -c "wget -qO- --post-data='{}' --header='Content-Type: application/json' http://localhost:8016/ofrep/v1/evaluate/flags/<flag>"
```

## flagd kill-switch

OpenFeature Operator on `trusk-staging-ts`; FeatureFlag CRDs in ns `flagd`, one per service (`<service>/deployment/flagd/<env>/featureflag.yaml`), with a companion ArgoCD app when the umbrella entry has `flagd: { enabled: true }`. Flip via `defaultVariant` (patches stick — the companion app has `ignoreDifferences` on `.spec.flagSpec.flags[].state` / `.defaultVariant`):

```bash
kubectl --context trusk-staging-ts -n flagd patch featureflag <name> --type=merge \
  -p '{"spec":{"flagSpec":{"flags":{"<flag>":{"defaultVariant":"off","state":"ENABLED","variants":{"on":true,"off":false}}}}}}'
# verify on any annotated pod's sidecar (~<1s):
kubectl --context trusk-staging-ts -n <ns> exec <pod> -c <main> -- \
  sh -c "wget -qO- --post-data='{}' --header='Content-Type: application/json' http://localhost:8016/ofrep/v1/evaluate/flags/<flag>"
```

Gotcha: `@RequireFlagsEnabled({flags:[{flagKey,defaultValue:true}]})` 403s **only when flagd serves `false`**; `state: DISABLED` or a missing flag falls back to `defaultValue` → request passes. Always flip `defaultVariant`, not `state`.

## ArgoCD selfHeal + operator-managed RBAC = drift trap

When an operator appends ServiceAccount subjects to a ClusterRoleBinding at runtime (OpenFeature Operator does this for `open-feature-operator-flagd-kubernetes-sync`; also cert-manager, Velero), `selfHeal: true` reverts the additions as drift → consumers 403 on first fetch. Fix = `ignoreDifferences` on `/subjects` for that binding (pattern in trusk-k8s#1191). Apply preemptively for any new RBAC-self-managing operator.

## Quick verifications

```bash
# chart published to GCS
curl -sf https://storage.googleapis.com/trusk-helm-chart/index.yaml | grep -A1 '<chart>' | head
# current staging targetRevision
grep -A3 'name: <service>' ~/MyDocuments/TRUSK/trusk-applications/applications/staging.yaml
# configmap contents
kubectl --context trusk-staging-ts -n staging get cm <name> -o jsonpath='{.data}' | python3 -m json.tool
```
