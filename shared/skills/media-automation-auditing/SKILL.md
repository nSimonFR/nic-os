---
name: media-automation-auditing
description: Use when auditing automated media workflows safely.
version: 1.0.0
metadata:
  hermes:
    category: media
---

# Media Automation Auditing

Use for recurring audits of automated media-library workflows, especially rules that mutate archive/visibility state based on filenames or other weak signals.

## Principles

1. **Read-only by default.** Report findings; mutate only under an explicit, pre-approved incident path.
2. **Test the catastrophic failure mode first.** Validate execution order from the storage/runtime source of truth, not UI order or a logical sequence field unless it is proven authoritative.
3. **Classify before counting.** Raw matches are leads, not false positives. Separate expected bulk-import artefacts and source-signature files from user-visible loss risks.
4. **Be silent when healthy.** Direct-alert only for incidents, actionable false positives, or statistically meaningful volume anomalies.
5. **Do not wake an idle service merely to audit it.** Prefer direct database reads where sufficient; only use the API for an approved remediation or presentation-layer verification.

## Audit procedure

### 1. Establish invariant and incident response

- Identify the critical ordered steps and verify their *physical/runtime* order.
- Confirm workflow existence, enabled state, step enabled state, and exact configuration.
- Define the emergency action before running the audit. If the invariant is broken, take that action immediately only when the user has explicitly authorized it; then enumerate the affected time window.

### 2. Gather candidates

Scope by a fixed reporting window and retrieve only assets mutated by the workflow. Join enough provenance context to classify candidates:

- filename and creation/upload time
- original/capture timestamp and EXIF make/model
- source/expected album membership where available
- all album memberships, separating curated vs automatic albums
- batch volume by upload day

### 3. Classify candidates

- Exclude expected ingestion bursts when they coincide with a high volume of confirmed source assets.
- Treat a known source signature (for example, no-EXIF UUID-named media captured long before upload) as non-reportable unless other evidence conflicts.
- Report assets in curated albums, or with camera provenance incompatible with the expected source.
- Put ambiguous but noteworthy provenance in a separately labelled category; do not claim it is a false positive.

### 4. Volume sanity check

Compare the current reporting bucket with a trailing baseline of completed equal-size buckets. Use a robust statistic such as the median, plus an absolute floor so a near-zero baseline does not over-alert. Include both values in a spike alert.

### 5. Deliver and verify

- Build Telegram HTML using only supported tags; HTML-escape dynamic text and query-string ampersands.
- Send directly if the job must be silent in healthy cases.
- Verify the Telegram API response before declaring delivery successful.

## Scheduled jobs

Use a deterministic, no-agent script when the audit logic is fully specified. Keep its stdout empty for normal healthy runs; emit or send only actionable findings. Set cron delivery to `local` when the script itself owns Telegram delivery.

## References

- `references/immich-whatsapp-uuid-archive.md` — concrete Immich PostgreSQL and workflow-audit pattern, including the guarded incident path.
