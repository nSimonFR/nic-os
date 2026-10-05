---
name: courses
description: Read and update the shared shopping list ("Liste de courses" / "Courses"), a markdown checklist in the notes. Use when the user wants to see, add, check off (mark as bought), un-check, or remove shopping-list items.
homepage: https://rpi5.gate-mintaka.ts.net:3980/#/2%20%F0%9F%8F%A0%20Perso/BurgieLand/Courses
metadata: {"openclaw":{"emoji":"🛒"}}
---

# Liste de courses (Burgie Land)

The household shopping list, shared with Alfie, is a plain markdown checklist:

`/mnt/data/cloud/NOTES/2 🏠 Perso/BurgieLand/Courses.md`

Read and edit that file directly; the notes web editor shows changes live.

- one item per line: `- [ ] item` to buy, `- [x] item` bought;
- keep the YAML frontmatter at the top untouched;
- match items loosely (case-insensitive substring: "oignon" → "Oignons frits");
- "clear the bought items" = delete every `- [x]` line.

Reply with the list split into **À acheter** and **Déjà pris**, e.g.:

```
🛒 Liste de courses

À acheter :
• Peanut butter

Déjà pris :
• Oignons frits
```

If the file is missing it was moved in the editor: `find /mnt/data/cloud/NOTES -name 'Courses.md'`.
Web: <https://rpi5.gate-mintaka.ts.net:3980/#/2%20%F0%9F%8F%A0%20Perso/BurgieLand/Courses>
