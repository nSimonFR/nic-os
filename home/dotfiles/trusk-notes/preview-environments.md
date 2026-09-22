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
