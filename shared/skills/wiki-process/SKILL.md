---
name: wiki-process
description: Promote items from the Wiki Inbox into curated Wiki Pages, merging or creating as the Wiki Schema dictates
metadata: {"openclaw":{"emoji":"🧠"}}
---

# wiki-process

Walk the **Wiki Inbox** and promote each item into the curated `Pages/` tree. This is the step where knowledge actually compounds.

## Wiki location

- Notes folder `8 🧠 Wiki/` (plain markdown, served by OpenKnowledge on rpi5):
  `Schema` (rules), `Inbox/` (captures), `Pages/` (curated), `Reports/` (lint).
- MCP server: `notes`. Paths are relative to the notes root, without `.md`
  (e.g. `8 🧠 Wiki/Schema`). Read with `exec` (`cat`, `ls`, `grep`, `find`) or `search`;
  write with `write` / `edit`; rename with `move` (rewrites inbound links); `delete`.
- Browser URL of a page: `https://rpi5.gate-mintaka.ts.net:3980/#/<url-encoded path>`.

## What to do

1. **Read `8 🧠 Wiki/Schema`**. Internalise the merge rule, naming convention, frontmatter spec, and confidence levels. If you can't read it, stop.

2. **List `8 🧠 Wiki/Inbox/`** (`exec` → `ls`). Process items oldest-first, skipping `README`. For each:

   a. **Read its body and source(s)**.

   b. **Search the wiki** with `search` (and `exec` → `grep -ril`) for related pages under `8 🧠 Wiki/Pages` — concept-level, not just title-level. Ignore `Pages/Claude Memory/` (mirrored, read-only).

   c. **Decide one action**:
      - **Merge**: an existing page already covers ≥70% of this content. `edit` it: append new facts under a dated note, refresh `updated`, add the new source.
      - **New page**: `write` `8 🧠 Wiki/Pages/<kebab-case-topic>` with the schema's frontmatter, body distilled from the inbox item, and at least one `[[wikilink]]` to a related page.
      - **Discard**: duplicate, low-signal, or obsolete. Note the reason in your reply.

   d. **Update wikilinks both ways**: any page you mention with `[[Foo]]` should mention this page back if relevant. Check with `links`.

   e. **Delete the inbox item** (`delete`) once promoted or discarded, as the schema specifies.

3. **Report**: a tight summary of what got merged, created, or discarded, and any concept gaps you noticed (cluster of inbox items pointing at the same missing topic).

## Notes

- Never invent facts. If two sources conflict, note both in the page with `confidence: low` and the conflicting sources cited.
- Honour the schema — if you'd be the second person to break a rule there, fix the schema first instead.
- Long inbox: process up to 10 items per run, leave a note about what's left.
