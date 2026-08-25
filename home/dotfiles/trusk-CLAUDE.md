# Trusk — global notes (Trusk-scoped: loaded only under ~/MyDocuments/TRUSK/)

Facts spanning all Trusk repos (trusk-k8s, trusk-applications, trusk-lib, services…). Per-project memory under `~/.claude/projects/<workdir>/memory/` adds local detail. **Source of truth:** `~/nic-os/home/dotfiles/trusk-CLAUDE.md` (home-manager symlinks it to this path) — edit there.

**Deep notes** — situational detail, kept out of this file because it loads into *every*
Trusk session. Source: `~/nic-os/home/dotfiles/trusk-notes/`, symlinked to `/Users/nsimon/MyDocuments/TRUSK/notes/`.

| note | read it when |
| --- | --- |
| [advisory-locks](/Users/nsimon/MyDocuments/TRUSK/notes/advisory-locks.md) | anything touches `lockBuilder`, or a service wedges under concurrency |
| [metastable-staging](/Users/nsimon/MyDocuments/TRUSK/notes/metastable-staging.md) | **before** trusting any staging perf measurement |
| [roundtrip-tour-size](/Users/nsimon/MyDocuments/TRUSK/notes/roundtrip-tour-size.md) | tour creation times out — the worked IN-871 example |
| [merge-and-ci-traps](/Users/nsimon/MyDocuments/TRUSK/notes/merge-and-ci-traps.md) | `gh pr merge` refuses, or local tests disagree with CI |
| [schema-migrations](/Users/nsimon/MyDocuments/TRUSK/notes/schema-migrations.md) | you are about to touch `schema/migrations` |
| [state-status-mirrors](/Users/nsimon/MyDocuments/TRUSK/notes/state-status-mirrors.md) | a `state_label` / `state_detail` is wrong, or you wire a new consumer |
| [client-libs-and-renovate](/Users/nsimon/MyDocuments/TRUSK/notes/client-libs-and-renovate.md) | consuming a not-yet-merged route, or a coordinated multi-service release |
| [data-and-analytics-mcp](/Users/nsimon/MyDocuments/TRUSK/notes/data-and-analytics-mcp.md) | GCP inventory as SQL (Steampipe), or a warehouse query (Metabase) |
| [argocd-operator-rbac](/Users/nsimon/MyDocuments/TRUSK/notes/argocd-operator-rbac.md) | an operator-managed ClusterRoleBinding keeps reverting → 403 |
| [legacy-trusk-api](/Users/nsimon/MyDocuments/TRUSK/notes/legacy-trusk-api.md) | making a legacy user see a given order set |

A finding earns a note when it is longer than a paragraph, still true in six months, and
not derivable from code or git history. Otherwise it belongs here as a line, or nowhere.

> **Keep fresh.** When you learn something future sessions need (a kubectl pattern, operator quirk, permission grant, release gotcha), propose adding/updating an entry before the conversation ends — show the diff, get the OK, write to the nic-os source. Flag stale/wrong entries for removal too.

## Repos on disk — siblings under `/Users/nsimon/MyDocuments/TRUSK/`

| Repo | Purpose |
| --- | --- |
| `trusk-k8s` | Cluster infra (cert-manager, datadog-operator, argocd projects/applications, `docs/flagd/*`). |
| `trusk-applications` | ArgoCD applications + manifests per env (`applications/<env>.yaml`, `manifests/<env>/<service>/`). Umbrella renders services via the `trusk-argo-project` chart. |
| `trusk-lib` | npm-workspaces monorepo. NestJS 11 pkgs in `nestjs-libraries/<name>/` = `@trusk-official/nestjs-*` (core, amqp, authentication, sql, health, url-shortener, business-policies, feature-flags). Legacy `nest-commons/` = NestJS 10. |
| `trusk-chart-museum` | Helm charts in `charts/<name>/` (notably `trusk-argo-project`). Pushed to GCS bucket `trusk-helm-chart` by `release.sh` on every master merge (`helm-cd.yaml`). |
| `github-actions` | Shared reusable GH workflows (e.g. `release.yaml`, used by every service's `cd.yaml`). |
| `<service>` (rating, identity-access-management, mobile-app-gateway, …) | Layout: `src/`, `deployment/charts/<env>.yaml`, `deployment/configurations/<env>/{configmaps,secrets}/`, sometimes `deployment/flagd/<env>/`. |
| `trusk-infra/<service>` | Older services pre-migration. |
| `backoffice` | **The** live backoffice (Next.js) — use this for any BO work. |

**`trusk-backoffice` and `trusk-infra/backoffice` are LEGACY — ignore entirely** (no grep, no cite, no edits). Only `backoffice` is live. Clone missing repos: `unset GH_TOKEN && gh repo clone trusk-official/<name> ~/MyDocuments/TRUSK/<name>`.

## GitHub auth — always `unset GH_TOKEN`

The active `GH_TOKEN` is the personal account `nSimonFR-ai`, which **can't see the `trusk-official` org** → bogus 404s on private repos. Prefix every git/gh command with `unset GH_TOKEN &&` (e.g. `unset GH_TOKEN && gh pr create …`) to fall back to the keyring credential (`nSimonFR` work account).

## Linear — use the `linear` skill (not the MCP)

`~/.claude/skills/linear/SKILL.md` hits the GraphQL API with a personal key. Default for any Trusk ticket op. Keys: `$LINEAR_KEY` = personal (team NSI); `$LINEAR_KEY_TRUSK` = work (use for all IN-/EXTERN-/DO- tickets). Most-used team `INTERNAL` (`key: IN`, `id: 835374eb-2c41-427f-9779-772d1b95aa0a`). For a subissue, set `parentId` to the parent's **UUID** (`issue(id:"IN-545"){ id }`), and reuse the parent's `team{id} project{id} cycle{id}` so it lands in the same context (avoids the "ended up in personal/no-project" footgun).

### Filing defaults on `IN` (INTERNAL)

| Field | Default | ids |
| --- | --- | --- |
| Swimlane | exactly one, from the `> SWIM LANES` group — the board keys on it | `BUG/RUN` `f3166fe6-b3c7-40c0-81f3-591b054f1566` · `TECH` `5274833e-40ae-43cc-83e7-0f1095a78ac6` · `GROOMED` `55c1f085-885d-44d7-b15d-bd16f130f390` |
| Priority | `2` for a prod defect, `1` only for a live incident | 0 none · 1 urgent · 2 high · 3 medium · 4 low |
| Estimate | `1` for a one-file fix | fibonacci, zero allowed, extended |
| Assignee | Nicolas | `803d1002-a245-4dc8-bcb0-a01d9b959c63` |
| State | `Sprint Backlog` if slotted into a cycle, else `Backlog` | `99b3b72b-c364-4c52-80b5-a27c916f6a15` / `c1d1b450-41cc-4ed8-94c3-f3ad43e3c1a9` |

Leave the `PRODUCT - *`, `QA - *` and `TECH - Chapters` labels alone — product and QA own them.

Two traps: a shipped ticket ends at **`In Production`** (`7dc6b655-09d0-41f9-9a25-9df31bd448cc`), not `To Release` — both are `completed`-typed. And `cycles(filter:{isFuture:{eq:true}})` returns cycles **descending**, so next cycle = lowest `number`, not `nodes[0]`.

## ToolHive (`toolhive-tech`) — the MCP proxy, and what it fronts

One MCP (`find_tool` to discover, `call_tool` to run) proxying several tool sets — **notably Datadog** alongside ArgoCD. Datadog tools: `tech-datadog_logs` (`search` / `aggregate`), `tech-datadog_security`, plus the logs indexes/pipelines/archives admin tools.

Datadog gotchas: **`env:production` and `namespace:production` are NOT searchable facets** — filter with `host:gke-trusk-production*`. Version in scope is `@version` (log attribute) or `image_tag:` (pod tag). Prefer `aggregate` + `groupBy` for anything you'll quote as a number; `sample:"spread"` samples and must never be counted, and the **current time bucket is incomplete** so never conclude "it dropped to zero" on it. `search` with `sample:"diverse"` is the right tool to enumerate distinct error patterns.

Before calling a new regression: `aggregate` the same query over 3-30d `groupBy ["@version"]` — it separates "introduced by the version we just shipped" from "pre-existing, only now reaching this env".

## ArgoCD — read via MCP, write via UI/kubectl

Staging cluster `trusk-staging-ts`, UI <https://staging-argocd.trusk.com>. **Read** via the same ToolHive proxy (`toolhive-tech` → `find_tool`/`call_tool`; the argocd tools it fronts are `get_application`, `list_applications`, `get_application_resource_tree`, `get_application_workload_logs`, …). MCP RBAC is per-project: restrictive projects (`staging`) may return `permission denied`; app-of-apps (`staging-gitops`) and permissive ones (`flagd`) read fine. **Write (sync/patch/restart) is NOT in the MCP** → use the UI, or kubectl directly. `nicolas.simon@trusk.com` is `trusk-admin` (cluster-admin) on **both** staging and prod (`gke_trusk-production-kkypwi_europe-west1_trusk-production-gke`). Read pattern: `get_application("staging-gitops")` → `.status.resources` lists child apps with sync + health.

## Monitor / long-job waits

For "wait then notify" (CI, ArgoCD syncs, rollouts): **Bash `run_in_background`** for one-shot exits (incl. "wait N min" via `sleep N && …`), or **Monitor** for event streams (each stdout line = a notification, exit ends it). Don't foreground-poll; read via `TaskOutput`. Example:

```
Monitor: until [ "$(gh run view <ID> --json status --jq .status)" = completed ]; do sleep 15; done && echo RUN_DONE && gh run view <ID> --json conclusion --jq .conclusion
```

## PR CI ≠ local build — verify the real run

Service `Trusk CI` runs eslint/prettier + full jest e2e (docker-compose PG) + Docker build, **not** just `nest build`/`tsc`. Local-green routinely hides prettier errors, e2e assertion drift (`toHaveBeenCalledWith` on stale payloads), and outdated `node_modules` masking a wrong dep version. Never call a PR green from a local build — check the run:

```bash
gh pr checks <n> --repo trusk-official/<repo>
gh run view <id> --repo trusk-official/<repo> --json conclusion --jq .conclusion
gh run view <id> --repo … --log-failed | sed 's/\x1b\[[0-9;]*m//g' | grep -aE "✕|● |Tests:|error TS|prettier|Expected|Received"
```

`strictNullChecks` is **off** in these repos, so `tsc --noEmit` passes on things that break
at runtime (e.g. a test stub `mockResolvedValue(null)` against a `Promise<T[]>`). Only CI
catches those — when you change a return type, grep the test stubs by hand. More, plus the
per-repo merge methods (backoffice is **rebase-only**):
[`notes/merge-and-ci-traps.md`](/Users/nsimon/MyDocuments/TRUSK/notes/merge-and-ci-traps.md).

Match the run by headSha (its name is often `CI Workflow`, not the PR title). Draft PRs still run CI on push; editing a PR body does not. Wait for a fix's run with the Monitor pattern above.

## Staging deploy flow — merge → pod live

1. **`cd.yaml`** runs at merge; its `Trusk CD` job calls a reusable `github-actions` workflow — `gh run view <id> --json jobs` shows only wrapper steps (Install/Release/Linear); the docker build/push lives inside the reusable wf (`gh api .../actions/runs/<id>/jobs` for the full list).
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
- **Link a PR to its Linear issue via the PR body, not the title/branch.** Put `Closes IN-XXX` (or `Fixes IN-XXX`) at the **top of the PR description** — the Linear↔GitHub integration auto-attaches the PR to the issue and advances its status on merge. Keeps the title clean (above rule) while still wiring the ticket. No need to touch Linear by hand.

## Code style — brace every `if`

Always brace `if` bodies, even one-liners. No `if (cond) doThing();`. All Trusk TS repos.

## trusk-applications bumps — commit straight to master, no PR

`targetRevision` doesn't auto-bump after a release. **Push directly to `master`** (Nicolas 2026-06-03: PRs are needless churn + branch protection blocks non-admin merges anyway). Message: `Chore(Staging): bump <service> to <version>` / `Chore(Production): …`; diff is one line in `applications/<env>.yaml`. If a PR was already opened: `gh pr merge <n> --rebase --delete-branch --admin` (squash disabled here).


## kubectl contexts

- **Staging** — `trusk-staging-ts` (Tailscale operator), works directly.
- **Production** — no Tailscale; run the `proxy-prod` alias once/session (opens an IAP tunnel + SOCKS/HTTP proxy on `localhost:8888`), then `export http_proxy=localhost:8888 https_proxy=localhost:8888` and use ctx `gke_trusk-production-kkypwi_europe-west1_trusk-production-gke`. Socket `/tmp/trusk-production-gke-bastion.socket` = readiness signal (direct GKE ctx times out on TLS — private control plane).

`proxy-prod` is an interactive-shell alias and long-running. Run it autonomously via **`zsh -ic 'proxy-prod'`** in `Bash(run_in_background:true)`, prefixed with the ADC token export below (without it, stale user creds make `get-credentials` die on `Reauthentication failed. cannot prompt during non-interactive execution`), then poll for the socket:

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

## nestjs-sql LockService = TypeORM pool deadlock under concurrency (TEC-105)

`lockBuilder` holds advisory locks on a **dedicated pg pool** (default max 5/pod, override
`POSTGRES_LOCK_POOL_MAX`; acquire timeout `POSTGRES_LOCK_ACQUIRE_TIMEOUT_MS`, and since
11.9.2 the wait on the lock itself is bounded too, surfacing as SQLSTATE `55P03`).

Two failure modes, **not** the same problem:

- **Same key nested** = real deadlock. The inner take runs on a second connection and waits
  on the lock the outer frame holds. **No pool size fixes it.** (IN-873.)
- **Different keys nested** = capacity. Sizing rule: **pool >= prefetchCount x nesting
  depth**. Below it, starvation triggers retries that re-trigger it — self-sustaining, and
  **a restart does not clear it**. (IN-871.)

Corollary: never hold a lock slot across a network call — 10 slots cluster-wide x a 10 s
call inside = 1 locked op/sec, whatever the pool size.

Full account, including the hoist-and-revalidate pattern and the sites still to audit:
[`notes/advisory-locks.md`](/Users/nsimon/MyDocuments/TRUSK/notes/advisory-locks.md).

Related (same day): the Nest11 `nestjs-core` logger reads `LOGGER_LEVEL` (default `error`) and ignores the legacy `LOG_LEVEL` still in the infra-env configmap → migrated services log error-only (Datadog still works). Fix = add `LOGGER_LEVEL` to infra-env configmaps (TEC-104).

## Quick verifications

```bash
# chart published to GCS
curl -sf https://storage.googleapis.com/trusk-helm-chart/index.yaml | grep -A1 '<chart>' | head
# current staging targetRevision
grep -A3 'name: <service>' ~/MyDocuments/TRUSK/trusk-applications/applications/staging.yaml
# configmap contents
kubectl --context trusk-staging-ts -n staging get cm <name> -o jsonpath='{.data}' | python3 -m json.tool
```

## Prod access + debug gotchas

- **Auth: use ADC, never ask for `gcloud auth login`.** The *user* credential (`gcloud auth print-access-token`) routinely needs interactive reauth and dies non-interactively (`Reauthentication failed. cannot prompt during non-interactive execution`) — that is NOT a blocker and never a reason to hand the user a login command. `gcloud auth application-default login` is set up and long-lived, and gcloud honours it when passed explicitly. Export it once per Bash call (mint it OUTSIDE the proxy, then set the proxy vars) and both `proxy-prod`/`get-credentials` and kubectl work:

  ```bash
  export CLOUDSDK_AUTH_ACCESS_TOKEN=$(unset http_proxy https_proxy; gcloud auth application-default print-access-token)
  export http_proxy=localhost:8888 https_proxy=localhost:8888
  kubectl --context gke_trusk-production-kkypwi_europe-west1_trusk-production-gke get ns
  ```

  Env doesn't persist across Bash calls → re-export in each. Token expires ~1h. Verified 2026-07-30 end-to-end (get-credentials → IAP tunnel → kubectl → `exec … node pg`) with the user cred fully expired.
- **gcloud token refresh fails under proxy** (`print credential failed … proxy URL malformed`, or kubectl `connection refused` to 10.0.0.2): mint any token DIRECT (`unset http_proxy https_proxy` in a subshell, as above), then set `http_proxy`/`https_proxy` for kubectl.
- **proxy-prod socket goes stale**: the socket file lingers but the tunnel dies (`connection refused`). Test with a real `kubectl get ns`, not socket existence; re-run `zsh -ic 'proxy-prod'` if refused.
- **`kubectl logs --since=60m` truncates** on verbose services (undercounts massively) → use short windows (`--since=15m`) or Datadog for reliable counts.
- **Temp per-service debug** (LOGGER_LEVEL & LOG_LEVEL live in the SHARED `infra-env` cm, both read; editing it floods every service): override on the deployment + stop selfHeal from reverting it — `kubectl -n argocd patch application <svc>-production --type merge -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'` → `kubectl -n production set env deploy/<svc> LOGGER_LEVEL=debug LOG_LEVEL=debug` → capture → revert (`set env … LOGGER_LEVEL- LOG_LEVEL-` + selfHeal:true).
