---
name: notification-digests
description: "Use when building digests. Verify links before delivery."
---

# Notification Digests

Use for scheduled or on-demand digests that gather notifications from APIs/RSS and deliver them to a messaging channel.

## Workflow

1. Collect items without mutating their read state.
2. Normalize each item to a presentation record: source, title, type, canonical public URL, timestamp, and source-specific ID.
3. Escape user/API-provided text for the destination format, while preserving only links that the formatter generated.
4. Deliver the digest and validate the delivery response.
5. Only after confirmed delivery, mark exactly the included source IDs as read.

If a collection or delivery stage fails, surface a concise error and leave notification state unchanged.

## GitHub Notification Links

GitHub notification `subject.url` is an API resource URL, not always a directly usable public URL.

- Issues and pull requests: convert the API resource URL to the public GitHub issue/PR URL.
- Releases: the notification URL usually ends in a **numeric release ID**. Do **not** construct `/releases/tag/<numeric-id>` and do not assume the notification title is a valid tag.
- Resolve every release notification through `gh api <subject.url> --jq .html_url` (or the equivalent API call) and render the returned `html_url`.
- If resolution fails, omit the link or use a verified repository releases index with an explicit fallback label. Do not convert `/releases/<numeric-id>` into a public URL either: removing `/tag/` does not prove the resulting destination exists.
- Validate canonical destinations, not just the absence of a numeric tag in output. A formatter can stop emitting the old broken pattern yet still emit broken links.

## Verification

Before deploying a formatter change:

1. Run the script syntax check.
2. Feed representative notification fixtures, including a GitHub Release notification, through the formatter in dry-run mode.
3. Confirm the generated release URL equals the API response's `html_url`.
4. Confirm dry-run does not send or mark anything read.

## Pitfalls

- Do not mark all unread source items as read if a maximum display limit excluded some of them.
- Do not interpolate API titles directly into HTML without escaping.
- A successful collection is not a successful delivery; validate the messaging API's explicit success field before acknowledging or marking items read.
