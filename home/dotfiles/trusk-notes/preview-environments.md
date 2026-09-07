# Preview environments (`appset-preview`)

Per-PR environments driven by ArgoCD **ApplicationSets with a `pullRequest` generator**
(GitHub, label `preview`, `requeueAfterSeconds: 60`). One pair per service:
`preview-<service>` + `preview-<service>-overrides`, ~50 pairs, defined in
`trusk-k8s/main/staging/argocd/applications/staging-preview-github/appset-<service>.yaml`.

Everything lands in **one namespace, `appset-preview`** (a few older ones sit in their own
`pr-<slug>` ns). URL `https://pr-<number>-bo.trusk.com`.

## The fact that surprises people: previews have no backend of their own

A preview pod talks to the **staging fleet**, over FQDN:

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

## Feature flags: a store of their own

Previews read `flagd-preview/*` (CRDs `iam-flags`, `backoffice-flags`, kept live by the
`flagd-preview-store` app), **not** the staging `flagd` namespace — so a flag flipped in
staging does not reach previews, and vice versa. Wiring is two pod annotations:

```yaml
openfeature.dev/enabled: "true"
openfeature.dev/featureflagsource: "flagd-preview/iam-flags-source,flagd-preview/backoffice-flags-source"
```

`openfeature.dev/enabled` is what activates the operator's mutating webhook; without it the
`featureflagsource` annotation is silently ignored and no sidecar is injected.

## `env.values[0..3]` — do not reorder

The ApplicationSet injects the per-PR URLs **by index** (`--set
backoffice.pod.env.values[0].name` … `[3]`, pattern DO-1780). Helm `--set list[i]` overwrites
whatever sits at that index, so the first four entries of `pod.env.values` in
`appset-preview.yaml` MUST stay the four URL placeholders. Inserting anything ahead of them
silently drops it — this already ate `FF_PROVIDER` and `FLAGD_HOST` once, leaving the OFREP
proxy at 503 and every flag defaulting off.

Also note `configMaps: []` in that file: ns `appset-preview` has none of the shared ConfigMaps
(`infra-env`, `backoffice-env`, `trusk-dynamic-config`); all env comes from Infisical secrets.
