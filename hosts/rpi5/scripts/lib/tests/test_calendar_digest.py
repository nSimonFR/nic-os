from datetime import date, datetime

from nicos_scripts.hermes.calendar_digest import build_digest, format_event


def test_digest_uses_native_rich_markdown_hierarchy():
    events = [
        {
            "start": datetime(2026, 10, 16, 19, 0),
            "end": datetime(2026, 10, 16, 21, 0),
            "summary": "Théâtre",
            "location": "Rendez-vous d'ailleurs, Paris",
        },
        {
            "start": date(2026, 10, 17),
            "end": date(2026, 10, 18),
            "summary": "Journée",
            "location": None,
        },
    ]
    text = build_digest(events, date(2026, 10, 16), 7)
    assert text.startswith("# 📅 Cette semaine\n*Agenda · 7 prochains jours")
    assert "## aujourd'hui 16 octobre" in text
    assert "**19:00–21:00**  Théâtre\n   📍 Rendez-vous d'ailleurs, Paris" in text
    assert "## demain 17 octobre" in text
    assert "**Toute la journée**  Journée" in text


def test_user_text_escapes_rich_markdown_delimiters():
    text = format_event({
        "start": datetime(2026, 10, 16, 9, 0),
        "end": datetime(2026, 10, 16, 10, 0),
        "summary": "Événement *important*",
        "location": "Rue `test`",
    })
    assert r"\*important\*" in text
    assert r"\`test\`" in text


def test_empty_digest_names_its_horizon():
    text = build_digest([], date(2026, 10, 16), 7)
    assert text == "# 📅 Cette semaine\n\nAucun événement jusqu’au vendredi 23 octobre."
