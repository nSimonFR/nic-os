---
name: ship
description: Ship a merged-to-staging Trusk change end to end — admin-merge the PR once CI is green, wait for the release image, bump trusk-applications staging, verify the feature on the staging cluster, then evaluate the prod delta and stop for a human go/no-go. Use when asked to "ship", "merge and deploy", "release this PR", "mettre en staging", or to take a Trusk PR from green CI to a prod decision. Trusk repos only.
---

# /ship — Trusk PR → staging → prod decision

Takes a Trusk service PR from green CI to a staging deploy that has been tested, then
**stops** and hands the prod call to the human. Steps 1-4 are autonomous; step 5 never
writes.

Context lives in `~/MyDocuments/TRUSK/CLAUDE.md` (staging deploy flow, registry, contexts)
and `notes/merge-and-ci-traps.md` + `notes/prod-vs-staging-prerequisites.md`. Read those
rather than re-deriving; this file is only the sequence.

**Prefix every git/gh with `unset GH_TOKEN &&`.** Wait with `Monitor` or
`Bash(run_in_background)`, never a foreground poll loop.

Args: a PR number, a PR URL, or nothing (infer from the cwd repo + current branch).
State the repo, PR and service you resolved before touching anything.

## 1. Merge once CI is green

```bash
gh pr checks <n> --repo trusk-official/<svc>
gh api repos/trusk-official/<svc> --jq '{squash:.allow_squash_merge,merge:.allow_merge_commit,rebase:.allow_rebase_merge}'
gh pr merge <n> --repo trusk-official/<svc> --rebase --delete-branch --admin
```

- Never call it green from a local build — only the run counts. A failing run: report the
  failure and stop, unless it is a known flake (`notes/merge-and-ci-traps.md`), in which
  case `gh run rerun --failed` once and say so.
- Merge method is per repo; backoffice is rebase-only. `--admin` bypasses protection.
- `Type(Scope): desc` commits only — a Linear-prefixed commit cuts no release, so check
  the commits that are about to land before merging.

## 2. Wait for the release image — assert the tag, don't infer it

semantic-release cuts the tag + a `Chore(Version): <ver>` commit; the image is built by
`ci.yaml` on that commit's master push. ≈30 min merge → pod live.

```bash
unset http_proxy https_proxy
gcloud artifacts docker tags list \
  europe-west1-docker.pkg.dev/trusk-tools-tpfqef/trusk-registry/<svc> \
  --format="value(tag)" --filter="tag~<version>"
```

- `--filter="tag~"`, never `tag=` — exact match prints a WARNING and returns nothing.
- **A green release does not mean the image exists.** Two pushes in one concurrency group
  cancel the version-commit run, leaving only a `master` tag. A *cancelled* run reruns
  fine (`gh run rerun <id>`); a *skipped* one re-skips — check the conclusion first.
- The tag-push run coming out `skipped` is normal. Don't wait on it.

## 3. Bump staging

One line in `applications/staging.yaml`, **pushed straight to master**, no PR:

```bash
cd ~/MyDocuments/TRUSK/trusk-applications && git pull
# edit targetRevision for <svc> → <version>
git commit -am "Chore(Staging): bump <svc> to <version>" && git push
git fetch && git log origin/master -1     # the push prints a protection error yet lands
```

Then let ArgoCD reconcile and confirm the pod actually runs the new image:

```bash
kubectl --context trusk-staging-ts -n staging get deploy <svc> \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
kubectl --context trusk-staging-ts -n staging get pods -l app=<svc>
```

`ImagePullBackOff` here means step 2 lied — go back, don't retry the bump. Sync windows
deny weeknights 20:00-07:00 and weekends; off-hours, say so and wait.

## 4. Test the feature on staging

Exercise the actual change, not the pod's readiness — a `1/1 Running` proves nothing about
the diff. Derive the check from the PR: an endpoint via the `trusk-apis` MCP, a BO deeplink
(`notes/backoffice-deeplinks.md`), a queue/consumer (`notes/amqp-publish-traps.md`), or a
read through `postgres_staging_rw`. Also check both containers' logs for a regression:

```bash
kubectl --context trusk-staging-ts -n staging logs <pod> -c <svc>-pgm   # migrations
kubectl --context trusk-staging-ts -n staging logs <pod> --since=15m
```

Report the check you ran and its result verbatim. If you cannot devise one, say that
plainly instead of declaring success.

## 5. Evaluate prod — then stop

Read-only. Produce the delta and the prerequisite verdict, then **ask for a go/no-go and
wait.** Never edit `applications/production.yaml` without an explicit yes.

```bash
SVC=<svc>
awk '/- name: '"$SVC"'$/{f=1} f&&/targetRevision/{print;exit}' \
  ~/MyDocuments/TRUSK/trusk-applications/applications/production.yaml
git -C ~/MyDocuments/TRUSK/$SVC log --oneline <verprod>..<version> | grep -v 'Chore(Version)'
git -C ~/MyDocuments/TRUSK/$SVC diff --name-status <verprod>..<version> -- deployment/ src/schema/
```

Then run the checklist in `notes/prod-vs-staging-prerequisites.md` — `trusk-auth` mount,
`shared-flags`, **flags added *and removed*** (TEC-275 fails the whole apply either way),
migrations. Hand back:

- prod `<verprod>` → `<version>`, and every intermediate release riding along;
- migrations / flag / deployment changes in that range;
- prerequisites met or missing, each with the command that proved it;
- a recommendation: isolated bump, or a global staging→prod MEP when prod is several
  releases behind (the MEP carries backoffice, so prerequisites resolve by GitOps).

Several releases behind with unmet prerequisites ⇒ recommend the MEP, not the bump.
