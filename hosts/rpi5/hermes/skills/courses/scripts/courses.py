#!/usr/bin/env python3
"""Read and update the shared "Liste de courses" (shopping list).

The list is a markdown checklist in the notes folder served by OpenKnowledge
(hosts/rpi5/notes.nix): `2 🏠 Perso/BurgieLand/Courses.md`. The script edits the
file directly; the editor picks the change up live.

Subcommands:
    show                 Print the list (default if no args).
    add <item ...>       Add an item (unchecked). Joins all following words.
    done <text ...>      Tick the first un-ticked item matching <text>.
    undone <text ...>    Un-tick the first ticked item matching <text>.
    remove <text ...>    Delete the first item matching <text>.
    clear-done           Delete every ticked (bought) item.

Matching is case-insensitive substring. Output is plain text on stdout for
Hermes to relay; the script never messages Telegram itself.

Env override:
    COURSES_FILE   default /mnt/data/notes/2 🏠 Perso/BurgieLand/Courses.md
"""
import os
import sys

COURSES_FILE = os.environ.get("COURSES_FILE", "/mnt/data/notes/2 🏠 Perso/BurgieLand/Courses.md")


class Doc:
    """The list file: YAML frontmatter kept verbatim, checklist body rewritten."""

    def __init__(self, path=COURSES_FILE):
        self.path = path

    def read(self):
        text = open(self.path, encoding="utf-8").read()
        if text.startswith("---\n") and "\n---\n" in text[4:]:
            end = text.index("\n---\n", 4) + 5
            return text[:end], text[end:]
        return "", text

    def write(self, body):
        front, _ = self.read()
        tmp = f"{self.path}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(front + "\n" + body.strip() + "\n")
        os.replace(tmp, self.path)


def load(doc):
    """Return the list as [{checked: bool|None, text: str}] in document order.

    checked is None for any non-todo line (preserved verbatim on save).
    """
    items = []
    for raw in doc.read()[1].splitlines():
        stripped = raw.strip()
        low = stripped.lower()
        if low.startswith("- [x]"):
            items.append({"checked": True, "text": stripped[5:].strip()})
        elif low.startswith("- [ ]"):
            items.append({"checked": False, "text": stripped[5:].strip()})
        elif stripped:
            items.append({"checked": None, "text": raw})
    return items


def render(items):
    lines = []
    for it in items:
        if it["checked"] is None:
            lines.append(it["text"])
        else:
            box = "x" if it["checked"] else " "
            lines.append(f"- [{box}] {it['text']}")
    return "\n".join(lines)


def save(doc, items):
    # Keep one blank todo so an emptied list stays an editable checklist.
    doc.write(render(items).strip() or "- [ ] ")


def show(items):
    todo = [it for it in items if it["checked"] is False and it["text"]]
    done = [it for it in items if it["checked"] is True and it["text"]]
    out = ["🛒 Liste de courses (Burgie Land)", ""]
    out.append("À acheter :")
    if todo:
        out += [f"• {it['text']}" for it in todo]
    else:
        out.append("• (rien — liste à jour ✅)")
    if done:
        out += ["", "Déjà pris :"]
        out += [f"• {it['text']}" for it in done]
    print("\n".join(out))


def _find(items, needle, want_checked):
    needle = needle.lower()
    for it in items:
        if it["checked"] is want_checked and needle in it["text"].lower():
            return it
    return None


def main(argv):
    cmd = argv[0] if argv else "show"
    rest = " ".join(argv[1:]).strip()
    doc = Doc()

    if cmd == "show":
        show(load(doc))
        return 0

    if cmd == "add":
        if not rest:
            print("usage: add <item>")
            return 2
        items = load(doc)
        items.append({"checked": False, "text": rest})
        save(doc, items)
        print(f"✅ Ajouté : {rest}")
        show(load(doc))
        return 0

    if cmd in ("done", "undone", "remove"):
        if not rest:
            print(f"usage: {cmd} <text>")
            return 2
        items = load(doc)
        if cmd == "remove":
            hit = _find(items, rest, False) or _find(items, rest, True)
            if not hit:
                print(f"❓ Introuvable : {rest}")
                return 1
            items.remove(hit)
            save(doc, items)
            print(f"🗑️ Retiré : {hit['text']}")
        elif cmd == "done":
            hit = _find(items, rest, False)
            if not hit:
                print(f"❓ Aucun article à acheter ne correspond à : {rest}")
                return 1
            hit["checked"] = True
            save(doc, items)
            print(f"✅ Pris : {hit['text']}")
        else:  # undone
            hit = _find(items, rest, True)
            if not hit:
                print(f"❓ Aucun article déjà pris ne correspond à : {rest}")
                return 1
            hit["checked"] = False
            save(doc, items)
            print(f"↩️ Remis à acheter : {hit['text']}")
        show(load(doc))
        return 0

    if cmd == "clear-done":
        items = load(doc)
        kept = [it for it in items if it["checked"] is not True]
        removed = len(items) - len(kept)
        save(doc, kept)
        print(f"🧹 {removed} article(s) déjà pris supprimé(s).")
        show(load(doc))
        return 0

    print(f"unknown command: {cmd}", file=sys.stderr)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
