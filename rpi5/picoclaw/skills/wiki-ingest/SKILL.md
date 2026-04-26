---
name: wiki-ingest
description: Drop a URL or pasted note into the LLM Wiki Inbox in AFFiNE
metadata: {"openclaw":{"emoji":"📥"}}
---

# wiki-ingest

Capture raw content into the **LLM Wiki Inbox** so it can be processed later. This skill does **not** decide where the knowledge belongs — that's `wiki-process`'s job.

## Wiki location

- AFFiNE workspace: `35d244cd-e6d5-4b3d-b1c2-fa50cab50621`
- Top-level page: `Wiki`
- Children: `Wiki/Schema` (rules), `Wiki/Inbox` (drop zone), `Wiki/Pages` (curated entries)
- MCP server: `affine` (write-capable; if you only see `read_document`/`semantic_search`/`keyword_search`, you're hitting the wrong endpoint)

## What to do

1. **Read** `Wiki/Schema` first via the `affine` MCP — it tells you the inbox-page conventions (frontmatter fields, naming, expected sources). Honour them.

2. **Resolve the input**:
   - A URL → fetch the page, extract title + main text + author/date if present.
   - Free-form pasted text → take it as-is; the user is the source.

3. **Create one new child page under `Wiki/Inbox`** via the affine MCP's create-doc tool. Title: `<YYYY-MM-DD> — <short topic>`. Body must include:
   - Frontmatter as defined in `Wiki/Schema` (at minimum: `created`, `sources`, `status: inbox`).
   - Either the raw fetched markdown (URL case) or the verbatim paste (text case).
   - **Do NOT** integrate, summarise, or wikilink yet — that's the next step.

4. **Reply** with the new page's title and AFFiNE URL so the user can open it.

## Notes

- If `Wiki/Schema` is unreachable, stop and ask the user; do not invent conventions.
- One ingest = one new page. Don't bundle multiple URLs into a single page.
- Network fetch failures: leave a stub page noting the URL + the error so the inbox-processor can retry later.
