# Preview environments

Triggers are in the index row. **There are two kinds, and almost everything below differs
between them.** Establish which one you are looking at before reading further.

| | `appset-preview` | named `pr-<slug>` |
| --- | --- | --- |
| driven by | ArgoCD ApplicationSets, `pullRequest` generator (GitHub label `preview`), pairs `preview-<service>` + `-overrides` in `trusk-k8s/main/staging/argocd/applications/staging-preview-github/` | the **`trusk-preview-env`** repo, `applications/previews/helm/pr-<slug>/preview.yaml` |
| namespace | one shared, `appset-preview` | its own, `pr-<slug>` |
| chart values | `deployment/charts/appset-preview.yaml` | `deployment/charts/preview.yaml` |
| URL | `https://pr-<number>-bo.trusk.com` | `https://pr-<slug>-bo.trusk.com` |
| backend | **none of its own — calls the staging fleet** | **a full fleet of its own** |

## `appset-preview`: no backend of its own

A pod there talks to the **staging fleet**, over FQDN:

```
IDENTITY_ACCESS_MANAGEMENT_URL=http://identity-access-management.staging.svc.cluster.local
```

FQDN and not the short name because ns `appset-preview` cannot resolve short staging
hostnames; the override lives in the shared Infisical secret
`infra-env-infisical-appset-shared` (managed in trusk-k8s), listed in
`deployment/charts/appset-preview.yaml` under `pod.envFrom.secrets`.

**Consequence: any authorization you switch on in staging applies to every open preview.**
Confirmed 2026-08-31 — during the IN-888 rollout, 100 % of the tokenless requests reaching
staging IAM came from previews, not from the staging back-office.

## `pr-<slug>`: a full fleet, and that changes what it is good for

Measured on `pr-tec296`, 2026-09-22: **64 deployments against staging's 67**, its own RabbitMQ,
its own Postgres schemas, and the **same six cronjobs**. The only three staging carries and it
does not are `com-fr`, `scalar`, `scalar-mcp`.

So it is a real environment, not a shell — you can migrate a schema, flip a gate and break
things in it without touching staging.

**But it has no ambient traffic.** Tested the same day, IAM with enforcement on: the six
cronjobs triggered by hand, the back-office exercised, and IAM logged **zero lines** over the
window. The crons do not call it. Its only caller is the back-office resolving a signed-in
user, which needs a **browser session** — an unauthenticated `curl` gets a 307 to the login and
never reaches the service.

The distinction worth keeping:

- a preview **validates** that the rules you wrote are right for the paths you deliberately
  exercise;
- it **discovers** nothing. Finding the caller you forgot to declare needs traffic you did not
  write, which means staging with the gate still off, reading `auth.enforcement.bypassed`.

Do not read "no refusals in the preview" as "the rules are complete". Check there was traffic at
all first — `kubectl logs <pod> --since=…​ | wc -l`.

### Service label ≠ deployment name

Comparing a service list against a preview by name gives false "missing" answers. Real cases:

| what it is called elsewhere | deployments that actually run it |
| --- | --- |
| `communications` | `communication`, `communication-cron`, `communication-engine` |
| `invoice` | `service-invoices-archiver`, `trusk-cresus*`, `trusk-mail-*invoice*`, `billing` |
| `trusk-templates-engine` | `trusk-templates-service-{notifications,pickup,statuses}` (repo `trusk-templates-service`, **not archived**) |

Diff the sets instead of grepping for a name:

```bash
CTX=trusk-staging-ts
kubectl --context $CTX -n staging   get deploy --no-headers -o custom-columns=N:.metadata.name | sort > /tmp/stg
kubectl --context $CTX -n pr-<slug> get deploy --no-headers -o custom-columns=N:.metadata.name | sort > /tmp/prv
comm -23 /tmp/stg /tmp/prv    # in staging, not in the preview
```

## `trusk-auth` (IN-888 / TEC-262): two separate traps

1. **Different key.** `appset-preview` has its own `trusk-auth` sealed secret with a key of
   its own (`37ed740aa9` on 2026-08-31) while staging holds `2b62f4d8eb`. Since previews call
   **staging** services, a preview-signed token is verified against the wrong secret and
   fails. A preview needs the *staging* key, or no token at all.
2. **Not mounted yet.** A preview renders `[default.yaml, appset-preview.yaml]` from the PR's
   own `head_sha`, so it only gets `pod.mounts.secrets` once its branch contains the commit
   that added the mount (`415b385b`, released in backoffice 1.384.4). Every preview open on
   2026-08-31 had `volumes=[]`.

Check both in one go:

```bash
kubectl --context trusk-staging-ts -n appset-preview get deploy -o \
  jsonpath="{range .items[*]}{.metadata.name}{'  volumes='}{.spec.template.spec.volumes[*].name}{'\n'}{end}"
kubectl --context trusk-staging-ts -n appset-preview get secret trusk-auth \
  -o jsonpath='{.data.TRUSK_AUTH_SECRET}' | base64 -d | shasum -a 256 | cut -c1-10
```

## Feature flags: a store of their own — that almost nobody reads

There IS a `flagd-preview` namespace with its own CRDs (`iam-flags`, `backoffice-flags`, kept
live by the `flagd-preview-store` app). **Most preview pods do not point at it.** Wiring is two
pod annotations, set per service in `deployment/charts/{preview,appset-preview}.yaml`:

```yaml
openfeature.dev/enabled: "true"
openfeature.dev/featureflagsource: "flagd-preview/iam-flags-source"
```

`openfeature.dev/enabled` activates the operator's mutating webhook; without it the
`featureflagsource` annotation is silently ignored and no sidecar is injected.

Measured 2026-09-22 — which chart names which namespace:

| service | `appset-preview.yaml` | `preview.yaml` |
| --- | --- | --- |
| backoffice | `flagd-preview/*` | **`flagd/*`** |
| identity-access-management | **`flagd/*`** | **`flagd/*`** |
| fleet | **`flagd/*`** | **`flagd/*`** |
| state-status | **`flagd/*`** | **`flagd/*`** |

So the isolation is real for exactly one combination — backoffice under `appset-preview`.
Everywhere else a preview evaluates flags against **staging's** store, which means:

- a flag flipped in staging changes every open preview at once, and
- you cannot try a gate in a preview *before* staging, which is the whole reason to have one.

### The symptom, when the gate is an authorization one

`@trusk-official/nestjs-authentication` gates enforcement on a per-service flag
(`<service>_backend_authz`, see the service's `authentication/authentication.options.ts`). With
the flag off, the guard **computes the right decision and does not apply it**: the refusal is
logged and the call succeeds.

```
{"event":"auth.enforcement.bypassed","route":"PUT /users/:id/rights",
 "missingPermissions":["internal_users_write"],"status":403, ...}   ← 200 on the wire
```

So a token with no rights at all writes another user's rights, and nothing on the client says
so. **A 200 in a preview proves nothing about authorization until you have checked the flag.**
On 2026-09-22 `flagd/iam_backend_authz` was `off` while `flagd-preview/iam_backend_authz` was
`on`, and pr-tec296 was following the first.

### Eject a flag onto one preview

Point that preview's service at the preview store, in **the service repo**, on the branch the
preview tracks:

```yaml
# <service>/deployment/charts/preview.yaml   (or appset-preview.yaml)
podAnnotations:
  openfeature.dev/featureflagsource: "flagd-preview/<service>-flags-source"
```

The chart is read by ArgoCD from the branch, not baked into the image, so a hard refresh applies
it — no need to wait for CI or a new tag:

```bash
CTX=trusk-staging-ts
kubectl --context $CTX -n argocd annotate application <service>-pr-<slug> \
  argocd.argoproj.io/refresh=hard --overwrite
# the annotation follows onto the new pod:
kubectl --context $CTX -n pr-<slug> get pod -l app.kubernetes.io/name=<service> \
  -o jsonpath='{.items[-1:].metadata.annotations.openfeature\.dev/featureflagsource}'
```

Then set the value in the preview store, which is shared by **all** previews (there is no
per-preview store):

```bash
kubectl --context $CTX -n flagd-preview get featureflag <service>-flags -o json \
  | python3 -c "import json,sys; f=json.load(sys.stdin)['spec']['flagSpec']['flags']; \
                print({k: v['defaultVariant'] for k, v in f.items()})"
```

Check what a pod actually follows before believing anything:

```bash
kubectl --context $CTX -n <ns> get pod <pod> \
  -o jsonpath='{.metadata.annotations.openfeature\.dev/featureflagsource}{"\n"}'
```

## `env.values[0..3]` — do not reorder

The ApplicationSet injects the per-PR URLs **by index** (`--set
backoffice.pod.env.values[0].name` … `[3]`, pattern DO-1780). Helm `--set list[i]` overwrites
whatever sits at that index, so the first four entries of `pod.env.values` in
`appset-preview.yaml` MUST stay the four URL placeholders. Inserting anything ahead of them
silently drops it — this already ate `FF_PROVIDER` and `FLAGD_HOST` once, leaving the OFREP
proxy at 503 and every flag defaulting off.

Also note `configMaps: []` in that file: ns `appset-preview` has none of the shared ConfigMaps
(`infra-env`, `backoffice-env`, `trusk-dynamic-config`); all env comes from Infisical secrets.

## Asleep by default — wake it with the workflow, not with `kubectl scale`

`pr-*` namespaces are shut down every night and all weekend. **Two independent mechanisms**, and
knowing which one you are fighting decides what works:

| | what it scales | schedule |
| --- | --- | --- |
| kube-green `SleepInfo/working-hours`, one per `pr-*` ns | Deployments | `sleepAt 20:00`, `wakeUpAt 07:00`, `weekdays 1-5`, Europe/Paris |
| CronWorkflow `pr-namespace-shutdown` (ns `awf-devops`) | Deployments **and** StatefulSets (PG, RabbitMQ, Redis, MariaDB) since DO-2091 | deadline per namespace in ConfigMap `pr-namespace-shutdown-schedule` |

The supported way back up is the **`wake-up-namespace` WorkflowTemplate** (ns `awf-dev`, source
`trusk-official/trusk-argo-workflows`). It scales in **two waves** — datastores first, then
applications, because one pass starts services before their databases and cascades into
CrashLoopBackOff — writes the next shutdown deadline into the ConfigMap above, hard-refreshes every
ArgoCD Application of the namespace, then calls `cwt-check-ns-argocd-app` to wait for
`Synced/Healthy`.

Launch it from Backstage ("Wake-up namespace" on the PR env card), the Argo Workflows UI, or the
CLI. Parameters: `namespace` and `duration` ∈ `morning` (13:00) · `endofday` (19:00) ·
`endofnight` (midnight) · `endofweek` (Friday 19:00).

```bash
argo submit --from workflowtemplate/wake-up-namespace -n awf-dev \
  -p namespace=pr-<slug> -p duration=endofday
```

No `argo` CLI on the Mac. Submit through kubectl instead — `workflowTemplateRef` plus the service
account, both required:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: { generateName: wake-pr-<slug>-, namespace: awf-dev }
spec:
  serviceAccountName: argo-workflow-additional-sa
  workflowTemplateRef: { name: wake-up-namespace }
  arguments:
    parameters:
      - { name: namespace, value: pr-<slug> }
      - { name: duration, value: endofnight }
```

### At night it only works as a MANUAL sync — and the workflow does not send one

AppProject `staging-preview` (and `staging`) carries three sync windows (Europe/Paris):

```
deny   0 20 * * 1-5   11h    manualSync: true
allow  0 7  * * 1-5   13h    manualSync: true
deny   0 7  * * 6     48h    manualSync: true
```

`manualSync: true` exempts **manual** syncs from the deny window. ArgoCD decides manual vs
automated from `operation.initiatedBy.automated`, and the wake-up workflow patches
`{"operation":{"sync":{…}}}` **without `initiatedBy`** — so every one of its syncs is classed
automated and refused: `Sync operation blocked by sync window`, `initiatedBy.automated: true`.
The `wake-up` step reports success, `check-argocd` loops on `OutOfSync`, nothing starts.
Measured 2026-09-22 at 20:40 on `pr-tec296`: 56/56 operations stuck `Running` since the patch.

The fix is to send the sync as a manual one. Two traps on the way:

- a refused operation **stays** `Running`, and a new `operation` patched on top is ignored while
  it is there — so clear it first, including `status.operationState` (patching its phase to
  `Terminating` is not enough: it sat there for minutes);
- the preview has **two** levels of app-of-apps: `staging-preview-gitops` renders
  `pr-<slug>-gitops`, which renders the per-service apps. A new branch pin lands only after both
  are synced, in that order.

```bash
# manual sync, the only kind the night window lets through
a=<app>   # staging-preview-gitops, then pr-<slug>-gitops, then <svc>-pr-<slug>
kubectl -n argocd patch application $a --type json -p '[{"op":"remove","path":"/operation"}]'
kubectl -n argocd patch application $a --type json -p '[{"op":"remove","path":"/status/operationState"}]'
kubectl -n argocd patch application $a --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}},
  "operation":{"initiatedBy":{"username":"<you>","automated":false},"sync":{"syncStrategy":{"apply":{"force":false}}}}}'
```

Result on 2026-09-22 at 21:45, inside the deny window: 55/56 `successfully synced`, namespace at
64/64 deployments, and nine new branch images rolled out the same night. `argocd-sync-namespace`
(ns `argocd`) has the same flaw as the wake-up — it too omits `initiatedBy`.

`kubectl scale` also works at any hour (ArgoCD carries `ignoreDifferences` on replicas), but it
only restores what already runs; a new image needs a real sync. kube-green's
`sleepinfo-working-hours` secret remembers only the deployments that were up at 20:00, not the
whole namespace — it is not a reliable list of what to scale back.

### A pod that restarts is a pod that re-resolves `envFrom`

The sleep/wake cycle is where latent chart mistakes surface. `envFrom` resolves at **container
creation**, so a secret that stopped existing only kills the pod at its next restart — a service
can run for months on a spec that can no longer start.

Found this way on 2026-09-22: `identity-access-management`, `fleet`, `communications` and
`centiro-orders-api` all list `staging-env` in their preview chart's `pod.envFrom.secrets`. That
secret exists in the `staging` namespace and in **no preview namespace**, so every one of them died on
`CreateContainerConfigError` the moment it was scaled back up. Drop it from the preview chart only —
the staging chart needs it. (An earlier check claimed it was missing from `staging` too: it was a
`jsonpath` → `json.load` probe that failed and printed "absent". Probe existence by exit code.) `pr-surge-ve` still showed IAM at
`1/1` purely because that pod had never restarted since the reference landed. Fixed on the first
three; centiro still carries it.

Probe before blaming the wake-up:

```bash
kubectl -n pr-<slug> get deploy | awk '$2=="0/0"{print $1}'        # still asleep
kubectl -n pr-<slug> describe pod <x> | grep -iE "Error:|Warning"  # why it will not start
```

### Populating it: `data-bo`, not SQL

A woken preview has schemas and no rows. The seeder is the **`workflow-template-data-bo`**
WorkflowTemplate (ns `awf-qa`), which runs `trusk-automation:master` driving Playwright against the
target's BO UI — so what it creates is what the application can actually create:

```bash
argo submit --from workflowtemplate/workflow-template-data-bo -n awf-qa -p STAGING_NAME=pr-<slug>
```

Then `workflow-gen-data` for volume and `smoketest-backoffice-template` to validate. For a
**partial** preview (some services in `pr-N`, the rest on staging), override URLs per run rather
than editing the shared `trusk-automation-env` configmap: an Infisical folder `/qa-overrides/<group>`
holding `QA_OVERRIDE_TRUSK_{BO,BACKOFFICE,API,TRACKING_PAGE}_BASE_URL`, an `InfisicalSecret` in
`awf-qa`, then `-p URL_OVERRIDES_SECRET=qa-overrides-<group>`.

Hand-writing SQL fixtures is the wrong reflex and costs hours: on 2026-09-22 seeding one usable
availability meant reverse-engineering `fleet.carrier_companies` → `truskers` → `trusker_contracts`
→ `trucks` → `availabilities` → `availability_shipment_sites` → `interop_configuration.shipment_site`
from `information_schema`, one NOT NULL at a time, across two DB roles — and the result was still a
row no BO screen would ever produce. Drop to SQL only to nudge a column on an entity that already
exists.
