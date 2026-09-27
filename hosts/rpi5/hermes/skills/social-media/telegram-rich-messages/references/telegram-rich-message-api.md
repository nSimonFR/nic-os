# Telegram Bot API: Rich Messages

Authoritative source: https://core.telegram.org/bots/api#rich-message-formatting-options

## Key distinction
- `sendRichMessage` delivers an `InputRichMessage` directly to a chat.
- `InlineQueryResultArticle` is an inline-mode result and is unrelated to native Rich Messages.
- Plain `sendMessage` with `parse_mode` is basic message formatting, not a Rich Message.

## Input forms
An `InputRichMessage` can use rich `markdown`, `html`, or structured `blocks`. Use structured blocks when preserving exact semantics matters.

## Wire format

The parameter is `rich_message`, a JSON object — not a top-level `markdown=`:

```
POST /bot<token>/sendRichMessage
  chat_id=<id>
  rich_message={"markdown": "# Title\n\n- [ ] task"}
```

`telegram-send -m rich` wraps this.

## Markdown → block mapping

Verified against the API, which echoes the parsed `rich_message.blocks` back in
its response — use that echo to confirm a send did not silently degrade.

| Markdown | Block |
|---|---|
| `#` / `##` | `heading` with `size` |
| `- item` | `list`, items labelled `•` |
| `1. item` | `list`, `type: "1"`, `value` |
| `- [ ]` / `- [x]` | `list` item with `has_checkbox` / `is_checked` |
| `[t](u)` | inline `{"type":"url"}` run |
| `> quote` | `blockquote` |
| `` ``` `` | `pre` |
| `\|a\|b\|` | `table` with `cells[][]`, `is_header`, `align` |
| `---` | `divider` |
| `<details><summary>s</summary>…` | `details` with `summary` |

Paragraph `text` is a string when unstyled, an array of runs when it contains
styled spans.

## Does not work

- `>!` is not an expandable blockquote — the `!` lands in the text.
- `is_expandable` on a `blockquote` block is silently dropped.

Use `<details>` for anything collapsible.

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
