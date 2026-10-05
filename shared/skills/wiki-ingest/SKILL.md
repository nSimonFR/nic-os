---
name: wiki-ingest
description: Drop a URL or pasted note into the LLM Wiki Inbox (markdown notes, via the notes MCP)
metadata: {"openclaw":{"emoji":"📥"}}
---

# wiki-ingest

Capture raw content into the **LLM Wiki Inbox** so it can be processed later. This skill does **not** decide where the knowledge belongs — that's `wiki-process`'s job.

## Wiki location

- Notes folder `8 🧠 Wiki/` (plain markdown, served by OpenKnowledge on rpi5):
  `Schema` (rules), `Inbox/` (captures), `Pages/` (curated), `Reports/` (lint).
- MCP server: `notes`. Paths are relative to the notes root, without `.md`
  (e.g. `8 🧠 Wiki/Schema`). Read with `exec` (`cat`, `ls`, `grep`, `find`) or `search`;
  write with `write` / `edit`; rename with `move` (rewrites inbound links); `delete`.
- Browser URL of a page: `https://rpi5.gate-mintaka.ts.net:3980/#/<url-encoded path>`.

## What to do

1. **Read** `8 🧠 Wiki/Schema` first — it gives the inbox naming and frontmatter. Honour it.

2. **Resolve the input**:
   - A URL → fetch the page, extract title + main text + author/date if present.
   - Free-form pasted text → take it as-is; the user is the source.

3. **Write one new page** `8 🧠 Wiki/Inbox/<YYYY-MM-DD> — <short topic>` with the `write` tool. Body:
   - Frontmatter per the schema (at minimum `created`, `sources`, `status: inbox`).
   - Either the raw fetched markdown (URL case) or the verbatim paste (text case).
   - **Do NOT** integrate, summarise, or wikilink yet — that's the next step.

4. **Reply** with the new page's path and browser URL.

## Notes

- If the schema is unreachable, stop and ask the user; do not invent conventions.
- One ingest = one new page. Don't bundle multiple URLs into a single page.
- Network fetch failures: leave a stub page noting the URL + the error so the inbox-processor can retry later.
