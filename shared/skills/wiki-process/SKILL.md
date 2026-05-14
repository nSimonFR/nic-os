---
name: wiki-process
description: Promote items from Wiki/Inbox into curated Wiki/Pages, merging or creating as Wiki/Schema dictates
metadata: {"openclaw":{"emoji":"🧠"}}
---

# wiki-process

Walk the **Wiki/Inbox** and promote each item into the curated `Wiki/Pages/` tree. This is the step where knowledge actually compounds.

## Wiki location

- AFFiNE workspace: `35d244cd-e6d5-4b3d-b1c2-fa50cab50621`
- `Wiki/Schema` — the rules. Read it first, every run.
- `Wiki/Inbox` — items waiting to be processed.
- `Wiki/Pages/*` — the curated wiki.
- MCP server: `affine` (write-capable).

## What to do

1. **Read `Wiki/Schema`**. Internalise the merge rule, naming convention, frontmatter spec, and confidence levels. If you can't read it, stop.

2. **List children of `Wiki/Inbox`**. Process them oldest-first. For each inbox item:

   a. **Read its body and source(s)**.

   b. **Search the wiki** with `keyword_search` and `semantic_search` for related pages — concept-level, not just title-level.

   c. **Decide one action**:
      - **Merge**: an existing `Wiki/Pages/<topic>` already covers ≥70% of this content (per schema). Update it: append new facts under a dated note, refresh `updated` frontmatter, add the new source.
      - **New page**: no sufficiently-overlapping page exists. Create `Wiki/Pages/<kebab-case-topic>` with the schema's frontmatter, body distilled from the inbox item, and at least one `[[wikilink]]` to a related page (or to a parent topic).
      - **Discard**: content is duplicate, low-signal, or already obsolete. Note the reason in your reply.

   d. **Update wikilinks both ways**: any page you mention with `[[Foo]]` should also mention this page back if relevant. Don't leave dangling links.

   e. **Move the inbox item to a "processed" tag, or delete it** — whichever the schema specifies.

3. **Report**: a tight summary of what got merged, created, or discarded, and any concept gaps you noticed (cluster of inbox items pointing at the same missing topic).

## Notes

- Never invent facts. If two sources conflict, note both in the page with `confidence: low` and the conflicting sources cited.
- Honour the schema — if you'd be the second person to break a rule there, fix the schema first instead.
- Long inbox: process up to 10 items per run, leave a note about what's left.
