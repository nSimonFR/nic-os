---
name: scheduled-digest-automation
description: "Use when maintaining scheduled notification digests."
metadata:
  created_by: agent
---

# Scheduled Digest Automation

Use when implementing, repairing, testing, or deploying scripts that collect notifications and deliver scheduled digests.

## GitHub notification links

1. Keep the raw notification payload and test with a fixture before changing read-state or sending messages.
2. GitHub Release notification subjects can use API URLs ending in a numeric release ID, e.g. `https://api.github.com/repos/OWNER/REPO/releases/123`.
3. **Never** convert that number mechanically to `/releases/tag/123`: it is not a tag and creates a broken public link.
4. For a `Release` subject, query its API URL with `gh api <subject-url> --jq .html_url` and use that verified canonical public URL.
5. Preserve ordinary conversions for issue and pull-request API URLs.
6. If resolving a Release URL fails, retain the original URL rather than inventing a tag URL; record the failure in the script's error path if the digest format permits.

## Verification before deployment

- Run shell syntax validation: `bash -n SCRIPT`.
- Run a deterministic fixture test containing both a Release API URL and a non-Release URL; assert the emitted Release URL has the expected tag, the normal URL remains correct, and no numeric `/releases/tag/<id>` URL appears.
- Resolve at least one current Release notification through `gh api` and compare the emitted URL to `.html_url`.
- Use dry-run/no-mark-read mode during testing. Do not send a Telegram message or mark notifications read while validating.

## Deployment and PRs

- Edit the declarative source in `nic-os`, not only the runtime workspace copy.
- Use a clean worktree from current `origin/main`; do not include unrelated local changes.
- Commit only the digest files, push a dedicated `fix/` branch, and open a PR with validation details.

## Delivery format

When the user requests raw cron output, configure the job/script so delivery contains only the digest body: no Hermes wrapper, job name/ID, header/footer, preamble, or receipt text.

- Inspect the existing job before updating it. Preserve its schedule, prompt, skills, script, destination/topic, and other settings unless the requested change requires otherwise. Omit unrelated update fields instead of supplying empty/default values.
- Prompt instructions such as “no header/footer” do not demonstrate that scheduler-added framing is disabled. Verify the actual delivery mechanism and rendered output; do not claim success from a prompt update alone.
- A script that sends its own Telegram message needs a non-delivering scheduler destination, or an explicitly verified stdout-suppression mechanism, to avoid duplicate receipts.

## Eligibility filters

For Nico's job alerts, include roles requiring at least eight years of experience OR genuine management roles. Staff/Principal seniority alone is insufficient, and “Lead” alone does not prove people management. Match requirements in the job description, not arbitrary numbers such as company age or product history. A range starting below eight (e.g. 5–10 years) does not require eight years. Missing requirement evidence must not silently qualify a non-management job.

See [regression checklist](references/digest-regressions.md) for link, eligibility, and delivery tests.
