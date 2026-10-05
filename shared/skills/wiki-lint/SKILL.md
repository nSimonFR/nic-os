---
name: wiki-lint
description: Audit the LLM Wiki for orphans, broken links, duplicates, and stale facts; write a report page
metadata: {"openclaw":{"emoji":"🧹"}}
---

# wiki-lint

Audit the wiki for the kinds of rot that accumulate when an agent grows it unsupervised. Output is a single report page; never silently mutates content.

## Wiki location

- Notes folder `8 🧠 Wiki/` (plain markdown, served by OpenKnowledge on rpi5):
  `Schema` (rules), `Inbox/` (captures), `Pages/` (curated), `Reports/` (lint).
- MCP server: `notes`. Paths are relative to the notes root, without `.md`
  (e.g. `8 🧠 Wiki/Schema`). Read with `exec` (`cat`, `ls`, `grep`, `find`) or `search`;
  write with `write` / `edit`; rename with `move` (rewrites inbound links); `delete`.
- Browser URL of a page: `https://rpi5.gate-mintaka.ts.net:3980/#/<url-encoded path>`.

## What to look for

1. **Schema violations** — pages missing required frontmatter; names that don't follow the convention.
2. **Broken `[[wikilinks]]`** and **orphan pages** — use the `links` tool (dead links, orphans) and `audit`; orphans with `top-level: true` are fine.
3. **Markdown problems** — the `lint` tool.
4. **Duplicates / near-duplicates** — pages whose content overlaps ≥70% (`search` each page's key terms).
5. **Stale low-confidence pages** — `confidence: low` or `updated` older than 90 days.
6. **Inbox items aged >30 days** — `wiki-process` is falling behind.

Scope: `8 🧠 Wiki/Pages/` excluding `Claude Memory/` (mirrored from Claude's memory files).

## What to do

1. Read `8 🧠 Wiki/Schema`.
2. Run the checks above.
3. `write` one report page `8 🧠 Wiki/Reports/lint-<YYYY-MM-DD>`:
   - Group by issue type, not by page.
   - For each issue: cite the page(s), the rule violated, and a one-line suggested fix.
4. **Do not auto-fix.** The only write is the report page.
5. **Reply** with the report URL and a top-3 of the most actionable issues.

## Notes

- If the schema itself is what's wrong (e.g. a rule no page satisfies), call that out at the top of the report — it's a schema bug, not a corpus bug.
- Cap the report at ~50 issues. Beyond that, the wiki needs structural attention, not lint passes.
