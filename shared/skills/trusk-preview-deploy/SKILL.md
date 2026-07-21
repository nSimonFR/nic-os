---
name: trusk-preview-deploy
description: Deploy (or tear down) a Trusk preview environment on the staging cluster from the trusk-preview-env repo — spin up a full isolated env with specific micro-services pinned to feature-branch images built by PR CI. Use when asked to "deploy a preview env", "spin up a preview", "test branch X in a preview environment", or to point one/several services at un-merged branches for QA.
---

# Trusk preview environment deploy

A preview env is a **full, isolated copy of the staging stack** (~30 services + rabbitmq/redis/postgres) in its own namespace `pr-<name>`, deployed by ArgoCD from the `trusk-preview-env` repo. You override the few services you want onto their **feature-branch images**; everything else runs `master`.

Repo: `~/MyDocuments/TRUSK/trusk-preview-env`. Cluster: `trusk-staging-ts` (kubectl works directly; you're `trusk-admin`). ArgoCD UI: <https://staging-argocd.trusk.com>.

> Always prefix git/gh with `unset GH_TOKEN &&` (the active token can't see `trusk-official`).

## 0. Prerequisite — a branch image must exist in GAR

PR CI's reusable workflow (`github-actions/.github/workflows/trusk.yaml`) **pushes one image per branch** on a green run — step `Push Image`, `tag: ${{ github.head_ref || github.ref_name }}`, condition `!renovate || label:push-image`. It runs **after** checks pass, so **the PR must be green** (a red run short-circuits the push → no image).

- Registry: `europe-west1-docker.pkg.dev/trusk-tools-tpfqef/trusk-registry/<service>`
- **Tag = branch name sanitized** by `sed "s/[^a-z0-9_.]/_/ig"` → every char outside `[A-Za-z0-9_.]` becomes `_`. So `feat/coa-postpone-cancel-source` → `feat_coa_postpone_cancel_source` (both `/` and `-` become `_`).

Verify (run direct, no proxy):
```bash
unset http_proxy https_proxy
gcloud artifacts docker tags list \
  europe-west1-docker.pkg.dev/trusk-tools-tpfqef/trusk-registry/<service> \
  --format="value(tag)" | grep -x '<sanitized_tag>'
```
Renovate branches don't push by default — add the `push-image` label to force it.

## 1. Generate the env scaffold

```bash
cd ~/MyDocuments/TRUSK/trusk-preview-env
./preview-env.sh install <name> --team-owner internal   # teams: internal|external|interop|qa|devops
```
Env name becomes namespace `pr-<name>`. It writes:
- `applications/previews/helm/pr-<name>/preview.yaml`  ← the values file listing **all** services (this is what you edit)
- `applications/previews/helm/pr-<name>/Chart.yaml`
- `applications/previews/manifests/pr-<name>/{argo-application.yaml,namespace.yaml}`

Every service defaults to `targetRevision: master`.

## 2. Pin your service(s) to their branch + image

In `applications/previews/helm/pr-<name>/preview.yaml`, find each service block (`- name: <svc>` … `repoURL: …/<svc>` … `targetRevision: master`) and:

1. Set `targetRevision:` to the **git branch** (keep the slashes — this is a git ref, not the image tag).
2. Add a `parameters` entry `<svc>.image.tag` = the **sanitized** tag.
3. If the service has a pgm/migration init container (backends do; check its `deployment/charts/preview.yaml` for `truskInitContainers`), also override `<svc>.truskInitContainers[0].image` — else the init still runs the `master` image (fine only if your branch adds no migration).

```yaml
      - name: order-mission
        type: trusk
        sources:
          - repoURL: https://github.com/trusk-official/order-mission
            targetRevision: feat/my-branch            # git ref (slashes OK)
            releaseName: order-mission
            parameters:
              - name: order-mission.image.tag
                value: "feat_my_branch"               # sanitized tag
              - name: order-mission.truskInitContainers[0].image
                value: "europe-west1-docker.pkg.dev/trusk-tools-tpfqef/trusk-registry/order-mission:feat_my_branch"
              # …keep the generated healthCheck params…
```
The param key prefix is the service's top-level values key (same as the pre-existing `<svc>.healthCheck.*` params — usually the service name). Validate the file: `ruby -ryaml -e "YAML.load_stream(File.read('applications/previews/helm/pr-<name>/preview.yaml'))"`.

> A service is preview-deployable only if it has `deployment/charts/preview.yaml` in its repo. Frontends (backoffice, tracking, business) qualify too. Don't add a service to the **shared** `applications/preview.yaml` template just to preview a branch — edit only the generated `previews/…/pr-<name>/` files.

## 3. Commit, PR, merge (rebase only)

```bash
unset GH_TOKEN
git checkout -b preview/<name>
git add applications/previews/helm/pr-<name> applications/previews/manifests/pr-<name>
git commit -m "Chore(Preview): add <name> env"   # + Co-Authored-By footer
git push -u origin preview/<name>
gh pr create --repo trusk-official/trusk-preview-env --title "Chore(Preview): <name> env" --body "…"
gh pr merge <n> --repo trusk-official/trusk-preview-env --rebase --admin
```
**This repo only allows `--rebase`** (merge commits and squash are both blocked). `--admin` to bypass branch protection.

## 4. Deploy + watch

Merging feeds `staging-preview-gitops`, which renders the per-service ArgoCD Applications. Force a refresh instead of waiting for the scan:
```bash
CTX=trusk-staging-ts
kubectl --context $CTX -n argocd annotate application staging-preview-gitops argocd.argoproj.io/refresh=hard --overwrite
```
Deploy runs in **sync-waves**: infra (config/secrets/rabbitmq/redis/postgres, priority 0-1) → `certificates` (cert-manager, ~min) → services (priority 3). Watch:
```bash
NS=pr-<name>
kubectl --context $CTX -n argocd get applications | grep <name>     # sync/health per app
kubectl --context $CTX -n $NS get pods                              # readiness
# confirm YOUR service runs the branch image:
kubectl --context $CTX -n $NS get deploy <svc> -o jsonpath='{.spec.template.spec.containers[0].image}'
```
Backend pods = 2 containers (`<svc>-pgm` init runs migrations then `<svc>`). Full env settles in ~5-15 min.

## 5. URLs

Ingress hosts follow `pr-<name>-<slug>.trusk.com`:
- `-bo` → backoffice, `-pro` → trusk-business (Plateforme Pro), `-track` → front-tracking-page, `-rabbitmq` → RabbitMQ UI.
- Backend APIs (order-mission, COA, …) have **no public ingress** — reach them in-cluster.
```bash
kubectl --context $CTX -n $NS get ingress -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.rules[0].host}{"\n"}{end}'
```

## 6. Teardown

```bash
cd ~/MyDocuments/TRUSK/trusk-preview-env
./preview-env.sh delete <name>
git add -A && git commit -m "Chore(Preview): remove <name> env"
gh pr create … && gh pr merge <n> --rebase --admin      # or push a branch + rebase-merge
```
ArgoCD prunes the namespace on the next sync (finalizer set).

## Gotchas

- **Green CI is mandatory** before generating — no green run, no branch image, → `ImagePullBackOff`.
- **Rebase-only** merges on trusk-preview-env.
- **Sync windows**: staging AppProjects deny weeknights 20:00-07:00 + all weekend (Europe/Paris). Off-hours the merge changes nothing until the window opens (apps sit blocked); force via ArgoCD UI/`argocd app sync` or just wait. Staging is also downscaled to 0 off-hours.
- **`backoffice` may CrashLoopBackOff** in preview with `Error: Invalid environment variables` — its Next.js env schema wants vars the preview namespace doesn't supply. Generic to preview, not your change; needs extra env overrides to boot.
- Init-container image defaults to `master` unless you override `truskInitContainers[0].image` — matters if your branch has a new migration.
- `gcloud`/registry checks: `unset http_proxy https_proxy` first (the prod proxy breaks token refresh).
