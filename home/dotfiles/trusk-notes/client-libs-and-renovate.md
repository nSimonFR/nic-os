# Generated client libs, and the Renovate release batches

Triggers: consuming a route not yet merged · `need client API` label · `renovate/release-to-*` · coordinated multi-service release · `use<Tag><Method>` orval hook

## Generating a service's `-client` / `-query` lib (consume a new route)

Each service publishes `@trusk-official/api-<service>-client` (raw fns, backend↔backend) and `@trusk-official/api-<service>-query` (TanStack-Query hooks, used by the backoffice) from its OpenAPI spec, via `orval-client-generator` + the reusable `generate-apiclient.yaml`. Two service workflows:

- `generate-apiclient.yaml` (`on: push: tags`) → real versioned client+query on every release tag.
- `generate-PR-apiclient.yaml` (`on: pull_request`, gated by the **`need client API`** label) → prerelease `<ver>-pr.<PR#>.<run>.<attempt>`.

Use a not-yet-merged route in the backoffice: (1) `gh pr edit <PR#> --add-label "need client API"` on the service repo. **Gotcha:** the workflow triggers on `pull_request` **push** events, NOT `labeled` — labelling alone leaves the job `skipped`; after labelling, **push a commit** (`git commit --allow-empty && git push`) or reopen the PR to fire a run. Label case doesn't matter (`contains()` is case-insensitive). (2) wait for "Generate PR client", read the version via `npm view @trusk-official/api-<service>-query versions --json | tail`; (3) bump the dep to that `-pr.*` version + `npm install`; (4) import the orval hook (`use<Tag><Method>`, e.g. `Mission`/`resync` → `useMissionResync`). After merge, bump to the clean released version.

## release-to-\<env\> — Renovate batch PRs (for a coordinated multi-service release)

For a whole batch (not a one-off bump), Renovate keeps three long-lived **grouped** PRs, one per env, that bump every service's `targetRevision` to its newest **git tag**: branches `renovate/release-to-staging` (`applications/staging.yaml`), `renovate/release-to-preprod`, `renovate/release-to-production`. Author is the hosted **`app/renovate`** GitHub App — **there is NO in-repo renovate workflow** to dispatch. Config = `renovate.json` (customManagers regex on `repoURL`+`targetRevision`; staging/preprod use datasource `git-tags`, production uses `custom.localstaging` so prod can only go to the rev already on staging). Reviewers: staging/preprod = `chapter_qa`+`team_product`, prod = `managers`+`team_product`. So: service releases → new tag → next Renovate scan folds it into that env's PR. PR number isn't stable (Renovate can recreate) — find it by branch, e.g. `gh pr list --repo trusk-official/trusk-applications --head renovate/release-to-staging`.

**Refresh now (don't wait for Renovate's schedule)** = tick the rebase checkbox in the PR body (`- [ ] <!-- rebase-check -->` → `- [x]`); Renovate rebases onto master + refreshes the diff within ~1-3 min (its own commit):

```bash
unset GH_TOKEN && cd ~/MyDocuments/TRUSK/trusk-applications
PR=$(gh pr list --repo trusk-official/trusk-applications --head renovate/release-to-staging --json number --jq '.[0].number')
gh pr view "$PR" --repo trusk-official/trusk-applications --json body --jq .body \
 | sed 's/- \[ \] <!-- rebase-check -->/- [x] <!-- rebase-check -->/' \
 | gh pr edit "$PR" --repo trusk-official/trusk-applications --body-file -
# then poll until app/renovate pushes a fresh commit, re-read `gh pr diff "$PR"`
```

Only refresh **after** the services you want have actually released (their tags exist) — a service whose tag isn't cut yet simply won't appear in the diff. Then admin-merge (`gh pr merge "$PR" --repo … --rebase --admin` — squash disabled here). Merging = ArgoCD reconciles those services to the new revs on the next sweep.

**Sync windows gate the actual rollout — staging/preprod only.** The staging/preprod AppProjects carry ArgoCD **sync windows** (deny weekdays 20:00–07:00 + **all weekend** Sat 07:00→Mon 07:00 Europe/Paris; allow weekdays 07:00–20:00). **Prod has NO deny window** (AppProject window = `allow */* * * *`, `automated{selfHeal:true}` on `production-gitops` + child apps) → a `production.yaml` bump auto-deploys immediately, no manual sync / window wait (verified 2026-07). Outside the allow window, merging the renovate PR changes nothing until it opens — `staging-gitops` sits `OutOfSync` with `operationState.message = "Sync operation blocked by sync window"`, and the child `<svc>-staging` apps keep the old `targetRevision`. `manualSync:true` permits manual overrides, but a raw `kubectl patch application … -p '{"operation":{"sync":{…}}}'` is **not** treated as manual and stays blocked — force it via the ArgoCD **UI** (`staging-argocd.trusk.com`) or `argocd app sync`, else just wait for the window. Independently, staging is **downscaled to 0 replicas off-hours** (a `downscaling-staging` app), so off-hours a service is both un-synced and scaled to 0. `state-status-staging` is an app-of-apps child rendered by `staging-gitops` (targetRevision comes from staging.yaml as a param), so the **parent** must sync first to propagate a bump.
