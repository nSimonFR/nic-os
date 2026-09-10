# Digest regression checklist

## Release destinations
- Fixtures: numeric Release API ID with nonnumeric tag; canonical URL already present; normal Issue; excluded PullRequest; resolution failure.
- Compare emitted href with API `.html_url`, not only a pattern assertion. Numeric tag names can be valid; their appearance alone is not evidence of a broken link.
- On resolution failure preserve the original API URL or deliberately omit the link with an explicit failure indication. Do not pass a failed Release lookup through generic API-to-public substitution: `/releases/<id>` is not a verified fallback either.
- Test the real formatter. If wrapping `gh` for fixture notifications, discover the real executable and delegate release requests to it. Ensure test doubles cannot send or mark read.
- HTML-escape dynamic titles, labels, and href attributes independently; do not restore markup by globally undoing escaping.

## Job-alert eligibility
Positive cases: explicit minimum 8 years; 10+ years of relevant experience; a confirmed people-management role regardless of stated years.
Negative cases: 5–10 years; senior/staff/principal alone; technical lead without management evidence; “our company has existed for 15 years”; experience managing tools rather than staff.
Cover each source adapter's description extraction, not only the final predicate. Preserve other location/domain filters.

## Delivery and activation
- Snapshot the job before a targeted update; verify unrelated configuration is unchanged afterward.
- Distinguish body text from scheduler-generated framing. Check a controlled delivery when authorized; don't infer rendering from prompt text.
- Build success is not activation success. After deployment, verify the active system and installed script/config before claiming the fix is live.
- Dry-run/no-mark-read tests and a normal rerun have different side effects. State precisely which was executed and whether a message was actually delivered.
