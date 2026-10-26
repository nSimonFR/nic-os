import json
import sqlite3
from datetime import date

import pytest

from nicos_scripts.connectors import journal_family as jf


def _date(y=0, m=0, d=0, modifier=0):
    return {"calendar": 0, "modifier": modifier, "quality": 0, "dateval": [d, m, y, False]}


def make_tree(path, people, families, events, places=()):
    """people: (id, given, surname, female, parent fams, own fams, event ids)."""
    db = sqlite3.connect(path)
    for t in ("person", "family", "event", "place"):
        db.execute(f"CREATE TABLE {t} (handle TEXT, json_data TEXT)")
    ref = lambda e: {"ref": e, "role": {"value": 1}}
    for pid, given, surname, female, parents, fams, evs in people:
        db.execute("INSERT INTO person VALUES (?, ?)", (pid, json.dumps({
            "handle": pid, "gramps_id": pid, "gender": 0 if female else 1,
            "primary_name": {"first_name": given, "call": "", "surname_list": [{"surname": surname}]},
            "parent_family_list": parents, "family_list": fams, "event_ref_list": [ref(e) for e in evs]})))
    for fid, father, mother, children, evs in families:
        db.execute("INSERT INTO family VALUES (?, ?)", (fid, json.dumps({
            "handle": fid, "gramps_id": fid, "father_handle": father, "mother_handle": mother,
            "child_ref_list": [{"ref": c} for c in children],
            "event_ref_list": [{"ref": e, "role": {"value": 8}} for e in evs]})))
    for eid, etype, d, place in events:
        db.execute("INSERT INTO event VALUES (?, ?)", (eid, json.dumps({
            "handle": eid, "gramps_id": eid, "type": {"value": etype}, "date": d, "place": place})))
    for hid, name in places:
        db.execute("INSERT INTO place VALUES (?, ?)", (hid, json.dumps({"handle": hid, "name": {"value": name}})))
    db.commit()
    db.close()
    return path


B, D, M = jf.BIRTH, jf.DEATH, jf.MARRIAGE


@pytest.fixture
def tree(tmp_path):
    people = [
        ("I1", "Nicolas Malo", "Simon", False, ["F1"], [], ["E1"]),
        ("I2", "Mathilde", "Simon", True, ["F1"], [], ["E2", "E2b"]),
        ("I3", "Franck", "Simon", False, ["F2"], ["F1"], []),
        ("I4", "Anne", "Dolou", True, [], ["F1"], []),
        ("I5", "Roger", "Simon", False, ["F4"], ["F2"], ["E5", "E5d"]),
        ("I6", "Claude", "Le Dreff", True, [], ["F2"], ["E6"]),
        ("I7", "Pierre", "Simon", False, ["F2"], ["F3"], []),
        ("I8", "Marie", "Kerbiquet", True, [], ["F3"], []),
        ("I9", "Lou", "Simon", True, ["F3"], [], []),
        ("I10", "Yves", "Simon", False, [], ["F4"], []),
        ("I11", "Jeanne", "Pennec", True, [], ["F4"], []),
        ("I12", "Jean", "Simon", False, ["F4"], [], ["E12", "E12d"]),
    ]
    families = [
        ("F1", "I3", "I4", ["I1", "I2"], []),
        ("F2", "I5", "I6", ["I3", "I7"], ["E20"]),
        ("F3", "I7", "I8", ["I9"], []),
        ("F4", "I10", "I11", ["I5", "I12"], []),
    ]
    events = [
        ("E1", B, _date(1996, 11, 27), ""),
        ("E2", B, _date(1998, 12, 28), ""),
        ("E2b", B, _date(1998, 12, 28), ""),  # a merged duplicate
        ("E5", B, _date(1930, 3, 1), "P1"),
        ("E5d", D, _date(2001, 12, 28), "P1"),
        ("E6", B, _date(1932, 12, 28, modifier=3), ""),  # "about": not exact
        ("E12", B, _date(1925, 2, 29), ""),
        ("E12d", D, _date(), ""),  # died, date unknown
        ("E20", M, _date(1955, 12, 28), "P1"),
    ]
    path = make_tree(str(tmp_path / "sqlite.db"), people, families, events, [("P1", "Brest")])
    return jf.Tree.load(path, "I1")


def test_relations_by_blood_and_by_marriage(tree):
    rel = {pid: tree.relation(pid) for pid in tree.people}
    assert rel == {
        "I1": "toi", "I2": "ta sœur", "I3": "ton père", "I4": "ta mère",
        "I5": "ton grand-père", "I6": "ta grand-mère", "I7": "ton oncle",
        "I8": "épouse de ton oncle", "I9": "ta cousine germaine",
        "I10": "ton arrière-grand-père", "I11": "ton arrière-grand-mère", "I12": "ton grand-oncle",
    }


def test_far_relations_stay_readable():
    assert jf._up(4, True) == "arrière-arrière-grand-mère"
    assert jf._up(7, False) == "aïeul (7 générations)"
    assert jf._down(2, True) == "petite-fille"
    assert jf._cousin(3, False) == "cousin issu de germains"
    assert jf._possessive("arrière-grand-mère", True) == "ton arrière-grand-mère"
    assert jf._possessive("tante", True) == "ta tante"


def test_unknown_home_person_is_an_error(tmp_path):
    path = make_tree(str(tmp_path / "t.db"), [], [], [])
    with pytest.raises(ValueError):
        jf.Tree.load(path, "I0009")


def test_day_lines_birthday_death_marriage(tree):
    births, history = jf.family_sections([], tree, date(2026, 12, 28), "https://g")
    assert births == ["- 🎂 [Mathilde Simon](https://g/person/I2), ta sœur, fête ses 28 ans "
                      "([28 décembre 1998](https://g/event/E2))"]
    assert history == [
        "- 💍 Il y a 71 ans, [Roger Simon](https://g/person/I5) et [Claude Le Dreff](https://g/person/I6), "
        "tes grands-parents, se mariaient à Brest ([28 décembre 1955](https://g/event/E20))",
        "- 🕯 Il y a 25 ans s'éteignait [Roger Simon](https://g/person/I5), ton grand-père, "
        "à Brest ([28 décembre 2001](https://g/event/E5d))",
    ]


def test_own_birthday_and_feb_29_in_a_common_year(tree):
    births, _ = jf.family_sections([], tree, date(2026, 11, 27), "https://g")
    assert births == ["- 🎂 C'est ton anniversaire : 30 ans ([27 novembre 1996](https://g/event/E1))"]
    _, history = jf.family_sections([], tree, date(2026, 2, 28), "https://g")
    assert history == ["- 👶 Il y a 101 ans naissait [Jean Simon](https://g/person/I12), ton grand-oncle "
                       "([29 février 1925](https://g/event/E12))"]


def test_history_is_capped(tree):
    rows = [jf.Line(i, f"l{i}", False) for i in range(9)]
    tree_lines = jf.tree_lines
    try:
        jf.tree_lines = lambda *a: rows
        _, history = jf.family_sections([], tree, date(2026, 1, 1), "u", show=6)
    finally:
        jf.tree_lines = tree_lines
    assert history[-1] == "- *et 3 autres*" and len(history) == 7


def bday(summary, ymd, unknown=False, field="BDAY"):
    y, m, d = ymd
    return (f"BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART;VALUE=DATE:{y:04d}{m:02d}{d:02d}\r\n"
            f"SUMMARY:{summary}\r\nRRULE:FREQ=YEARLY\r\nX-NEXTCLOUD-BC-FIELD-TYPE:{field}\r\n"
            f"X-NEXTCLOUD-BC-UNKNOWN-YEAR:{1 if unknown else 0}\r\nX-NEXTCLOUD-BC-YEAR:{y}\r\n"
            "END:VEVENT\r\nEND:VCALENDAR\r\n").encode()


def test_contact_birthdays_skip_people_already_in_the_tree(tree):
    blobs = [bday("🎂 Mathilde Dolou (1996)", (1996, 12, 28)),  # same first name and day: the sister
             bday("🎂 Antoine Martin (1997)", (1997, 12, 28)),
             bday("🎂 Guy Le Moal", (1970, 12, 28), unknown=True),
             bday("🎂 Roger Simon (1930)", (1930, 3, 1)),  # another day
             bday("💀 Old", (1900, 12, 28), field="DEATHDATE")]
    day = date(2026, 12, 28)
    contacts = jf.contact_birthdays(blobs, day)
    assert [(n, y) for n, y, _ in contacts] == [("Antoine Martin", 1997), ("Guy Le Moal", None),
                                                 ("Mathilde Dolou", 1996)]
    assert jf.birthday_lines(contacts, tree, day) == ["🎂 Antoine Martin · 29 ans", "🎂 Guy Le Moal"]
    assert jf.birthday_lines(contacts, None, day)[-1] == "🎂 Mathilde Dolou · 30 ans"
