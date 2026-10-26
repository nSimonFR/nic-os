"""
Birthdays and family history for journal-daily.

Living people's birthdays come from Nextcloud's "Contact birthdays" calendar
and from the Gramps Web tree; the tree also gives the day's past births,
deaths and marriages, each with how its people relate to the home person.

The tree is read straight from Gramps' SQLite file (read-only). Only exact
dates count: a day, month and year, no "about"/"before", Gregorian.
"""

import re
import sqlite3
from collections import deque
from dataclasses import dataclass, field

MONTHS = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août",
          "septembre", "octobre", "novembre", "décembre"]
BIRTH, DEATH, BURIAL, MARRIAGE = 12, 13, 15, 1
PRIMARY = 1  # EventRoleType: the person's own event
MAX_AGE = 105  # born longer ago with no death recorded = not living
SHOW = 6


@dataclass
class Person:
    id: str
    name: str
    female: bool
    parents: list = field(default_factory=list)  # family handles
    families: list = field(default_factory=list)
    events: list = field(default_factory=list)  # event handles, own role


@dataclass(frozen=True)
class Event:
    id: str
    type: int
    date: tuple  # (y, m, d), or None when not exact
    place: str


def _name(js):
    n = js["primary_name"]
    given = n.get("call") or re.split(r"[ ,]+", n.get("first_name", "").strip())[0]
    surname = " ".join(s["surname"] for s in n.get("surname_list", []) if s.get("surname"))
    return " ".join(x for x in (given, surname) if x) or js["gramps_id"]


def _exact(d):
    day, month, year = d["dateval"][:3]
    ok = d.get("modifier") == 0 and d.get("quality") == 0 and d.get("calendar") == 0
    return (year, month, day) if ok and day and month and year else None


class Tree:
    """The Gramps tree, loaded once: people, families, events, place names."""

    def __init__(self, people, families, events, home):
        self.people, self.families, self.events, self.home = people, families, events, home
        self._up = {}

    @classmethod
    def load(cls, path, home_id, connect=sqlite3.connect):
        import json

        db = connect(f"file:{path}?mode=ro", uri=True)
        try:
            rows = lambda table: [json.loads(j) for (j,) in db.execute(f"SELECT json_data FROM {table}")]
            places = {p["handle"]: p["name"]["value"] for p in rows("place")}
            events = {e["handle"]: Event(e["gramps_id"], e["type"]["value"], _exact(e["date"]),
                                         places.get(e.get("place"), ""))
                      for e in rows("event")}
            people, home = {}, None
            for p in rows("person"):
                people[p["handle"]] = Person(
                    p["gramps_id"], _name(p), p["gender"] == 0, p["parent_family_list"], p["family_list"],
                    [r["ref"] for r in p["event_ref_list"] if r["role"]["value"] == PRIMARY])
                if p["gramps_id"] == home_id:
                    home = p["handle"]
            families = {f["handle"]: {"id": f["gramps_id"], "father": f.get("father_handle"),
                                      "mother": f.get("mother_handle"),
                                      "children": [c["ref"] for c in f["child_ref_list"]],
                                      "events": [r["ref"] for r in f["event_ref_list"]]}
                        for f in rows("family")}
        finally:
            db.close()
        if home is None:
            raise ValueError(f"home person {home_id} not in the tree")
        return cls(people, families, events, home)

    def parents(self, h):
        for fam in self.people[h].parents:
            f = self.families.get(fam, {})
            yield from (p for p in (f.get("father"), f.get("mother")) if p in self.people)

    def ancestors(self, h):
        """{handle: generations up}, `h` itself at 0."""
        if h not in self._up:
            seen, todo = {h: 0}, deque([h])
            while todo:
                x = todo.popleft()
                for p in self.parents(x):
                    if p not in seen:
                        seen[p] = seen[x] + 1
                        todo.append(p)
            self._up[h] = seen
        return self._up[h]

    def blood(self, h):
        """(a, b, common ancestor): generations from home and from `h` up to
        their nearest common ancestor, or None if not related by blood."""
        mine, theirs = self.ancestors(self.home), self.ancestors(h)
        common = [(mine[c] + theirs[c], mine[c], c) for c in mine.keys() & theirs.keys()]
        if not common:
            return None
        _, a, c = min(common)
        return a, theirs[c], c

    def spouses(self, h):
        for fam in self.people[h].families:
            f = self.families.get(fam, {})
            yield from (p for p in (f.get("father"), f.get("mother")) if p and p != h and p in self.people)

    def living(self, h):
        types = {self.events[e].type for e in self.people[h].events if e in self.events}
        return not types & {DEATH, BURIAL}

    def relation(self, h):
        """`ton arrière-grand-père`, `épouse de ton grand-oncle`, or ""."""
        if h == self.home:
            return "toi"
        r = self.blood(h)
        if r:
            kin = self._kin(h, *r)
            return kin if " de " in kin else _possessive(kin, self.people[h].female)
        for s in self.spouses(h):
            r = self.blood(s)
            if r and s != self.home:
                kin, f = self._kin(s, *r), self.people[s].female
                of = f"{'de la' if f else 'du'} {kin}" if " de " in kin else f"de {_possessive(kin, f)}"
                return f"{'épouse' if self.people[h].female else 'époux'} {of}"
        return ""

    def _kin(self, h, a, b, common):
        f = self.people[h].female
        if a == 0:
            return _down(b, f)
        if b == 0:
            return _up(a, f)
        if a == 1 and b == 1:
            return "sœur" if f else "frère"
        if a == 1:
            return "arrière-" * max(b - 3, 0) + "petite-" * (b > 2) + "nièce" if f else \
                "arrière-" * max(b - 3, 0) + "petit-" * (b > 2) + "neveu"
        if b == 1:
            if a <= 4:
                return "arrière-" * (a - 3) + "grand-" * (a > 2) + ("tante" if f else "oncle")
            anc = self._via(self.home, a - 1, common, 1)
            return f"{'sœur' if f else 'frère'} de {_possessive(_up(a - 1, anc.female), anc.female)}"
        if a == b:
            return _cousin(a, f)
        if a > b:  # cousin of one of my ancestors
            anc = self._via(self.home, a - b, common, b)
            return f"{_cousin(b, f)} de {_possessive(_up(a - b, anc.female), anc.female)}"
        mid = self._via(h, b - a, common, a)  # a cousin of mine, `h` descends from
        return f"{_down(b - a, f)} de {_possessive(_cousin(a, mid.female), mid.female)}"

    def _via(self, h, up, common, rest):
        """The ancestor `up` generations above `h` that is `rest` below `common`."""
        return self.people[next(x for x, g in self.ancestors(h).items()
                                if g == up and self.ancestors(x).get(common) == rest)]


def _up(k, f):
    if k == 1:
        return "mère" if f else "père"
    if k <= 4:
        return "arrière-" * (k - 2) + ("grand-mère" if f else "grand-père")
    return f"aïeule ({k} générations)" if f else f"aïeul ({k} générations)"


def _down(k, f):
    if k == 1:
        return "fille" if f else "fils"
    if k <= 3:
        return "arrière-" * (k - 2) + ("petite-fille" if f else "petit-fils")
    return f"descendante ({k} générations)" if f else f"descendant ({k} générations)"


def _cousin(k, f):
    word = "cousine" if f else "cousin"
    return {2: f"{word} germaine" if f else f"{word} germain",
            3: f"{word} issue de germains" if f else f"{word} issu de germains"}.get(k, f"{word} au {k - 1}ᵉ degré")


def _possessive(kin, female):
    """`ton`/`ta`; `ton` before a vowel, as in `ton arrière-grand-mère`."""
    return f"{'ta' if female and kin[0] not in 'aeiouyéèâàœ' else 'ton'} {kin}"


def couple_kin(tree, a, b):
    """`tes grands-parents` when both are ancestors of the same generation."""
    up = tree.ancestors(tree.home)
    if a in up and b in up and up[a] == up[b]:
        k = up[a]
        if k == 1:
            return "tes parents"
        if k <= 4:
            return "tes " + "arrière-" * (k - 2) + "grands-parents"
        return f"tes aïeux ({k} générations)"
    return ""


def date_fr(ymd):
    y, m, d = ymd
    return f"{'1er' if d == 1 else d} {MONTHS[m - 1]} {y}"


@dataclass(frozen=True)
class Line:
    rank: int  # closeness, smallest first
    text: str
    living: bool  # a birthday to wish, not history


def _on(ymd, day):
    """Same month and day; Feb 29 is marked on Feb 28 in common years."""
    if not ymd:
        return False
    _, m, d = ymd
    if (m, d) == (day.month, day.day):
        return True
    leap = day.year % 4 == 0 and (day.year % 100 or day.year % 400 == 0)
    return (m, d) == (2, 29) and (day.month, day.day) == (2, 28) and not leap


def _rank(tree, h):
    r = tree.blood(h)
    if r:
        return r[0] + r[1]
    return 50 if tree.relation(h) else 99


def tree_lines(tree, day, url):
    """The day's events in the tree, as Lines."""
    link = lambda kind, gid, text: f"[{text}]({url}/{kind}/{gid})"
    who = lambda h: link("person", tree.people[h].id, tree.people[h].name)
    at = lambda ev: f" à {ev.place}" if ev.place else ""
    # `, ton grand-oncle, à Brest` — the closing comma only before a place
    then = lambda kin, ev: (f", {kin}" if kin else "") + ("," if kin and ev.place else "") + at(ev)
    out = []
    for h, p in tree.people.items():
        seen = set()  # merged duplicates can carry the same event twice
        for eh in p.events:
            ev = tree.events.get(eh)
            if not ev or ev.type not in (BIRTH, DEATH) or not _on(ev.date, day) or ev.type in seen:
                continue
            seen.add(ev.type)
            years = day.year - ev.date[0]
            if years <= 0:
                continue
            kin = tree.relation(h)
            when = link("event", ev.id, date_fr(ev.date))
            if ev.type == BIRTH and tree.living(h) and years <= MAX_AGE:
                text = (f"🎂 C'est ton anniversaire : {years} ans ({when})" if h == tree.home else
                        f"🎂 {who(h)}{f', {kin},' if kin else ''} fête ses {years} ans ({when})")
                out.append(Line(_rank(tree, h), text, True))
            elif ev.type == BIRTH:
                out.append(Line(_rank(tree, h), f"👶 Il y a {years} ans naissait {who(h)}"
                                f"{then(kin, ev)} ({when})", False))
            else:
                out.append(Line(_rank(tree, h), f"🕯 Il y a {years} ans s'éteignait {who(h)}"
                                f"{then(kin, ev)} ({when})", False))
    for fam in tree.families.values():
        for eh in fam["events"]:
            ev = tree.events.get(eh)
            if not ev or ev.type != MARRIAGE or not _on(ev.date, day):
                continue
            years = day.year - ev.date[0]
            pair = [x for x in (fam["father"], fam["mother"]) if x in tree.people]
            if years <= 0 or not pair:
                continue
            when = link("event", ev.id, date_fr(ev.date))
            kin = couple_kin(tree, *pair) if len(pair) == 2 else ""
            names = " et ".join(f"{who(x)}" + ("" if kin or not tree.relation(x) else f" ({tree.relation(x)})")
                                for x in pair)
            rank = min(_rank(tree, x) for x in pair)
            if all(tree.living(x) for x in pair) and years <= 80:
                out.append(Line(rank, f"💍 {names}{f', {kin},' if kin else ''} fêtent leurs "
                                f"{years} ans de mariage ({when})", True))
            else:
                out.append(Line(rank, f"💍 Il y a {years} ans, {names}{f', {kin},' if kin else ''} "
                                f"se mariaient{at(ev)} ({when})", False))
    return sorted(out, key=lambda l: (l.rank, l.text))


_BC_NAME = re.compile(r"^🎂\s*(.*?)(?:\s*\(\d{4}\))?$")


def contact_birthdays(blobs, day):
    """[(name, birth year or None)] from Nextcloud birthday-calendar objects."""
    import icalendar  # lazy

    out = set()
    for blob in blobs:
        try:
            cal = icalendar.Calendar.from_ical(blob)
        except ValueError:
            continue
        for ev in cal.walk("VEVENT"):
            if str(ev.get("X-NEXTCLOUD-BC-FIELD-TYPE", "")) != "BDAY":
                continue
            start = ev.decoded("DTSTART")
            if not _on((start.year, start.month, start.day), day):
                continue
            year = None if str(ev.get("X-NEXTCLOUD-BC-UNKNOWN-YEAR", "0")) == "1" else \
                int(str(ev.get("X-NEXTCLOUD-BC-YEAR") or start.year))
            m = _BC_NAME.match(str(ev.get("SUMMARY", "")).strip())
            out.add((m.group(1) if m else str(ev.get("SUMMARY")), year, (start.month, start.day)))
    return sorted(out, key=lambda x: x[0])


def _first(name):
    return name.split()[0].casefold() if name.split() else ""


def birthday_lines(contacts, tree, day):
    """Contact birthdays not already in the tree: same full birth date, or
    same day and first name (Oct 2026: a sister's year differed by two)."""
    dates, names = set(), set()
    if tree:
        for p in tree.people.values():
            for eh in p.events:
                ev = tree.events.get(eh)
                if ev and ev.type == BIRTH and ev.date:
                    dates.add(ev.date)
                    names.add((ev.date[1], ev.date[2], _first(p.name)))
    lines = []
    for name, year, (m, d) in contacts:
        if (year, m, d) in dates or any((m, d, _first(w)) in names for w in name.split(maxsplit=1)[-1:] + [name]):
            continue
        age = day.year - year if year else None
        lines.append(f"🎂 {name}" + (f" · {age} ans" if age and age > 0 else ""))
    return lines


def family_sections(contacts, tree, day, url, show=SHOW):
    """(birthday lines, history lines): living people first, then the tree's
    past events, closest relatives first, at most `show` history lines."""
    rows = tree_lines(tree, day, url) if tree else []
    births = [l.text for l in rows if l.living] + birthday_lines(contacts, tree, day)
    history = [f"- {l.text}" for l in rows if not l.living]
    if len(history) > show:
        history = history[:show] + [f"- *et {len(history) - show} autres*"]
    return [f"- {t}" for t in births], history
