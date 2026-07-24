---
name: courses
description: Read and update the shared shopping list ("Liste de courses" / "Courses") in AFFiNE's Burgie Land workspace. Use when the user wants to see, add, check off (mark as bought), un-check, or remove shopping-list items.
homepage: https://rpi5.gate-mintaka.ts.net/workspace/0b8e6d06-c5e9-475f-a772-7c467e0c247e/_ssS4PUSXQoAU8P8xL32q
metadata: {"openclaw":{"emoji":"🛒","requires":{"bins":["python3"]}}}
---

# Liste de courses (Burgie Land)

Read and edit the household shopping list stored in **AFFiNE**. The list is the
doc titled **"Courses"** inside the **Burgie Land** workspace (shared space).
The script talks to the local `affine-mcp` server (already running on
`127.0.0.1:7021` and wired into picoclaw), so there is no token to set up — it
reads the world-readable MCP bearer from `/run/agenix/affine-mcp-http-token`
itself.

Picoclaw reads the script's stdout and relays it to the user; the script never
sends Telegram messages on its own.

## When to use

- "qu'est-ce qu'il y a sur la liste de courses ?" / "what's on the shopping list?"
- "ajoute du lait à la liste" / "add milk to the list"
- "j'ai pris les oignons" / "mark onions as bought" / "check off X"
- "enlève X de la liste" / "remove X"
- "nettoie les trucs déjà pris" / "clear the bought items"

## Invocation

```bash
python3 {baseDir}/scripts/courses.py show
```

Sample stdout:

```
🛒 Liste de courses (Burgie Land)

À acheter :
• truc qui va dans la cuvette des toilettes

Déjà pris :
• Sac poubelles
• Oignons frits
```

## Subcommands

| Command | Effect |
| --- | --- |
| `show` (default) | Print the list, split into **À acheter** (to buy) and **Déjà pris** (bought). |
| `add <item>` | Add an unchecked item. All words after `add` become the item text. |
| `done <text>` | Tick the first un-ticked item matching `<text>` (marks it bought). |
| `undone <text>` | Un-tick the first ticked item matching `<text>`. |
| `remove <text>` | Delete the first item matching `<text>`. |
| `clear-done` | Delete every ticked (bought) item. |

`<text>` matching is case-insensitive substring, so `done oignon` ticks
"Oignons frits". Each mutating command prints a one-line confirmation followed
by the refreshed list.

Examples:

```bash
python3 {baseDir}/scripts/courses.py add "lait demi-écrémé"
python3 {baseDir}/scripts/courses.py done oignons
python3 {baseDir}/scripts/courses.py remove "cuvette"
python3 {baseDir}/scripts/courses.py clear-done
```

## Notes

- **Workspace / doc**: Burgie Land = `0b8e6d06-c5e9-475f-a772-7c467e0c247e`,
  Courses doc = `_ssS4PUSXQoAU8P8xL32q`. These are the script defaults; override
  with `COURSES_WORKSPACE_ID` / `COURSES_DOC_ID` for a different list. If the doc
  is ever recreated, re-find its id with the affine-mcp `get_doc_by_title` tool
  (query "Courses" in that workspace) and update `COURSES_DOC_ID`.
- Only this Burgie Land list is canonical. There is an older "COURSES" copy in
  the personal workspace — ignore it; do **not** use it.
- Mutations use `read_doc` + `replace_doc_with_markdown`; `add` uses
  `append_markdown` (purely additive, safe against concurrent edits).
- Open the list in a browser:
  <https://rpi5.gate-mintaka.ts.net/workspace/0b8e6d06-c5e9-475f-a772-7c467e0c247e/_ssS4PUSXQoAU8P8xL32q>

## Troubleshooting

- `urllib ... 401/403` — the MCP bearer changed; `/run/agenix/affine-mcp-http-token`
  is regenerated on rebuild/secret rotation. Restart `affine-mcp.service` if stale.
- `Connection refused` — `affine-mcp.service` is down (`systemctl status affine-mcp`),
  or AFFiNE itself (`affine.service`) is not up yet.
- Empty / unexpected list — confirm `COURSES_DOC_ID` still resolves via the
  affine-mcp `read_doc` tool.
