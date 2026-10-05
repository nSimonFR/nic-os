---
name: courses
description: Read and update the shared shopping list ("Liste de courses" / "Courses"), a markdown checklist in the notes (Burgie Land folder). Use when the user wants to see, add, check off (mark as bought), un-check, or remove shopping-list items.
homepage: https://rpi5.gate-mintaka.ts.net:3980/#/2%20%F0%9F%8F%A0%20Perso/BurgieLand/Courses
metadata: {"openclaw":{"emoji":"🛒","requires":{"bins":["python3"]}}}
---

# Liste de courses (Burgie Land)

Read and edit the household shopping list: the markdown checklist
`/mnt/data/notes/2 🏠 Perso/BurgieLand/Courses.md` in the notes folder (served by
OpenKnowledge, shared with Alfie). The script edits the file directly; the web
editor shows the change live. No token or server needed.

Hermes reads the script's stdout and relays it to the user; the script never
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

- **File**: `/mnt/data/notes/2 🏠 Perso/BurgieLand/Courses.md` — override with
  `COURSES_FILE`. Its YAML frontmatter is preserved; only the checklist body is
  rewritten.
- Open the list in a browser:
  <https://rpi5.gate-mintaka.ts.net:3980/#/2%20%F0%9F%8F%A0%20Perso/BurgieLand/Courses>

## Troubleshooting

- `FileNotFoundError` — the list was moved or renamed in the editor; find it with
  `find /mnt/data/notes -name 'Courses.md'` and set `COURSES_FILE`.
- `PermissionError` — the notes folder is `nsimon:users 0750`; Hermes must run as nsimon.
