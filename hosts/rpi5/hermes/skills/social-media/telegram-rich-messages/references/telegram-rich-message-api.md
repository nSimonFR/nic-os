# Telegram Bot API: Rich Messages

Authoritative source: https://core.telegram.org/bots/api#rich-message-formatting-options

## Key distinction
- `sendRichMessage` delivers an `InputRichMessage` directly to a chat.
- `InlineQueryResultArticle` is an inline-mode result and is unrelated to native Rich Messages.
- Plain `sendMessage` with `parse_mode` is basic message formatting, not a Rich Message.

## Input forms
An `InputRichMessage` can use rich `markdown`, `html`, or structured `blocks`. Use structured blocks when preserving exact semantics matters.

## Useful content patterns
- Headings: for scannable report hierarchy.
- Tables: comparison data only; keep cards/list data out of tables.
- Task lists: explicit actions/cuts/adds.
- Blockquotes: a compact key recommendation or caveat.
- Details / collapsible blocks: optional variants, caveats, or long evidence.
- Preformatted/code block: copy-paste artifacts such as Moxfield imports.

## Delivery checklist
1. Use `sendRichMessage` rather than a Markdown-only fallback.
2. Keep imports in plain preformatted text: `1 Card Name` per line.
3. Avoid decorative dividers or excessive headings.
4. Confirm the outcome accurately; do not say Rich Message if the outbound route did not support it.
