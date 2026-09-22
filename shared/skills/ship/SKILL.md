---
name: ship
description: Ship a Trusk change end to end — admin-merge the PR once CI is green, wait for the release image, bump trusk-applications staging, verify the feature on the staging cluster, then evaluate the prod delta and stop for a human go/no-go. Use when asked to "ship", "merge and deploy", "release this PR", "mettre en staging", or to take a Trusk PR from green CI to a prod decision. Trusk repos only.
---

# /ship — Trusk PR → staging → prod decision

Steps 1-4 are autonomous; step 5 is read-only and blocks on a human.

Facts live in `~/MyDocuments/TRUSK/CLAUDE.md` (deploy flow, registry, contexts) and
`notes/merge-and-ci-traps.md` + `notes/prod-vs-staging-prerequisites.md` — read those, this
is only the sequence. **Prefix every git/gh with `unset GH_TOKEN &&`.** Wait with `Monitor`
or `Bash(run_in_background)`, never a foreground poll.

Args: a PR number/URL, or nothing (infer from cwd + branch). State what you resolved first.

## 1. Merge

```bash
gh pr checks <n> --repo trusk-official/<svc>
gh pr merge <n> --repo trusk-official/<svc> --rebase --delete-branch --admin
```

Only the run counts, never a local build. Merge method is per repo (`gh api
repos/trusk-official/<svc> --jq '{squash:.allow_squash_merge,rebase:.allow_rebase_merge}'`);
backoffice is rebase-only. Check the commits about to land — a Linear-prefixed or `Perf:`
commit cuts no release. Red run: report and stop, unless it's a known flake, then one rerun.

## 2. Wait for the image — assert the tag

```bash
unset http_proxy https_proxy
gcloud artifacts docker tags list \
  europe-west1-docker.pkg.dev/trusk-tools-tpfqef/trusk-registry/<svc> \
  --format="value(tag)" --filter="tag~<version>"
```

`tag~`, never `tag=`. **A green release does not mean the image exists** — a cancelled
version-commit run leaves only a `master` tag. Cancelled reruns fine, skipped re-skips, so
read the conclusion first. ≈30 min merge → pod live.

## 3. Bump staging

One line in `applications/staging.yaml`, straight to master, no PR:

```bash
cd ~/MyDocuments/TRUSK/trusk-applications && git pull   # edit targetRevision
git commit -am "Chore(Staging): bump <svc> to <version>" && git push
git fetch && git log origin/master -1     # the push prints a protection error yet lands
kubectl --context trusk-staging-ts -n staging get deploy <svc> \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

`ImagePullBackOff` means step 2 lied — go back, don't retry. Sync windows deny weeknights
20:00-07:00 and weekends; off-hours, say so and wait.

## 4. Test the feature

Exercise the diff, not readiness — `1/1 Running` proves nothing. Derive the check from the
PR: `trusk-apis` MCP, a BO deeplink, a consumer, `postgres_staging_rw`. Read both containers'
logs (`-c <svc>-pgm` for migrations, `--since=15m` for the main one). Report the check and
its result verbatim; if you can't devise one, say so instead of claiming success.

## 5. Evaluate prod — then stop

Read-only. Never touch `production.yaml` without an explicit yes.

```bash
awk '/- name: <svc>$/{f=1} f&&/targetRevision/{print;exit}' \
  ~/MyDocuments/TRUSK/trusk-applications/applications/production.yaml
git -C ~/MyDocuments/TRUSK/<svc> log --oneline <verprod>..<version> | grep -v 'Chore(Version)'
git -C ~/MyDocuments/TRUSK/<svc> diff --name-status <verprod>..<version> -- deployment/
```

Then the checklist in `notes/prod-vs-staging-prerequisites.md` — `trusk-auth`,
`shared-flags`, flags added **and removed** (TEC-275 fails the whole apply either way),
migrations. Hand back the version delta with every intermediate release, what's risky in it,
each prerequisite with the command that proved it, and a recommendation — several releases
behind with unmet prerequisites ⇒ a global staging→prod MEP, not an isolated bump. Then ask.
