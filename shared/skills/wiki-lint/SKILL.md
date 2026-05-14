---
name: wiki-lint
description: Audit the LLM Wiki for orphans, broken links, duplicates, and stale facts; write a report page
metadata: {"openclaw":{"emoji":"🧹"}}
---

# wiki-lint

Audit the wiki for the kinds of rot that accumulate when an agent grows it unsupervised. Output is a single report page; never silently mutates content.

## Wiki location

- AFFiNE workspace: `35d244cd-e6d5-4b3d-b1c2-fa50cab50621`
- `Wiki/Schema` — the rules being audited against.
- `Wiki/Pages/*` — the corpus to scan.
- MCP server: `affine` (write-capable).

## What to look for

1. **Schema violations** — pages missing required frontmatter; titles that don't follow the naming convention.
2. **Broken `[[wikilinks]]`** — links pointing at nonexistent pages.
3. **Orphan pages** — pages with zero inbound links *and* no `top-level: true` marker.
4. **Duplicates / near-duplicates** — pages whose semantic content overlaps ≥70% (use `semantic_search` against each page's body to find candidates).
5. **Stale low-confidence pages** — `confidence: low` or `updated` older than 90 days, not yet revisited.
6. **Inbox items aged >30 days** — `wiki-process` is falling behind.

## What to do

1. Read `Wiki/Schema`.
2. Walk `Wiki/Pages/*` (paginated if needed).
3. Collect issues into one report page: `Wiki/Reports/lint-<YYYY-MM-DD>`.
   - Group by issue type, not by page.
   - For each issue: cite the page(s), the rule violated, and a one-line suggested fix.
4. **Do not auto-fix.** This skill is read-mostly. The only writes it performs are creating the report page and tagging audited pages with the lint date in frontmatter.
5. **Reply** with the report URL and a top-3 of the most actionable issues.

## Notes

- If the schema itself is what's wrong (e.g. a rule no page satisfies), call that out at the top of the report — it's a schema bug, not a corpus bug.
- Cap the report at ~50 issues. Beyond that, the wiki needs structural attention, not lint passes.
