# ArgoCD — an app-of-apps that stops applying new commits

Triggers: bump pushed to `applications/<env>.yaml` (and `git log origin/master` shows it) but the child
app keeps the old `targetRevision` · the deployment never rolls · `production-gitops` /
`staging-gitops` `OutOfSync` while nothing syncs · `status.operationState.finishedAt: null` · you
want to sync one child app only.

## Recognise it

The child app (`<svc>-<env>`) is `Synced/Healthy` **on the old version**: it did what its parent last
rendered. Look at the parent:

```bash
kubectl --context $CTX -n argocd get application production-gitops -o json | jq -c '{
  synced: .status.sync.revision, auto: .spec.syncPolicy.automated,
  op: (.status.operationState | {phase, startedAt, finishedAt, rev: .operation.sync.revision}),
  outOfSync: [.status.resources[] | select(.status=="OutOfSync") | .name]}'
```

Seen in prod on 2026-09-30: an automated operation started 13:31 for an earlier bump (backoffice
1.417.0, applied fine) showed `phase: Succeeded` with `finishedAt: null`. For 30 min afterwards the
parent reconciled every few minutes, listed `gateway-production` as `OutOfSync`, and never started a
new sync. `automated: {enabled: true, selfHeal: true}` and no sync window: the policy was not the
cause. `flagd-production` (an ApplicationSet) was also `OutOfSync`. That one was unrelated drift, and
the reason not to sync the whole parent blindly.

## Unblock: sync only the child you own

Same as ticking one resource in the UI's Sync dialog. It applies git `master` for that child alone,
not for the other `OutOfSync` resources:

```bash
kubectl --context $CTX -n argocd patch application production-gitops --type merge -p \
  '{"operation":{"sync":{"revision":"master","resources":[{"group":"argoproj.io","kind":"Application","name":"<svc>-production"}]}}}'
```

The child's `targetRevision` flipped within seconds. The rollout followed (RollingUpdate, no
downtime), and the parent's operation then closed properly (`finishedAt` set).

That was **prod, in daytime**: production AppProjects carry no sync window, and the old operation
was `Succeeded`, not `Running`. On **staging/preprod** (deny weeknights 20:00–07:00 and weekends,
`client-libs-and-renovate.md`) the raw patch is not enough when the old operation is still
`Running`. The patch merges onto it and inherits `initiatedBy.automated: true`, so the window blocks
it (`preview-environments.md`, "stuck `Running`"). There, either use the UI / `argocd app sync
<parent> --resource argoproj.io:Application:<child>`, or first remove `/operation` and
`/status/operationState`, then patch as above. Never add `initiatedBy` yourself.
