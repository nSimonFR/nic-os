---
name: telegram-rich-messages
description: "Use for structured Telegram replies. Send Rich Messages."
---

# Telegram Rich Messages

## Trigger
Use for any substantial Telegram response with sections, a deck review, a comparison, a report, or an importable artifact where structure matters.

## Required delivery mode
- Send a native Rich Message through the platform's `sendRichMessage` / `InputRichMessage` path when available; do **not** substitute a normal `sendMessage` merely because its Markdown renders similarly.
- This is distinct from `InlineQueryResultArticle`; do not call the Rich Message feature an "article".
- Use the documented rich-message modes: `markdown`, `html`, or explicit `blocks`. Prefer `blocks` when exact section/table/collapsible behavior matters; otherwise use rich Markdown.

## Composition rules
1. Open with the result or recommendation, not a preamble.
2. Use short headings for major sections.
3. Use tables only for true comparisons; use lists for actions and decklists.
4. Put caveats, optional alternatives, and long supporting detail in a collapsible details block when supported.
5. For an importable card list, use a preformatted code block with one `quantity card name` entry per line. Do not place import data in a table.
6. Keep rich content concise: hierarchy should improve scanability, not add decoration.

## Verification before sending
- Check that the actual outbound path is Rich Message, not basic Markdown fallback.
- Ensure tables have headers and sensible column widths.
- Ensure code blocks remain plain, copyable text.
- Do not claim a Rich Message was sent if only plain Markdown was delivered.

## References
- `references/telegram-rich-message-api.md` — concise Bot API distinction and rich Markdown block syntax.
