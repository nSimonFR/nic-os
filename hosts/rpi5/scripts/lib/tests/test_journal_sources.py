import base64
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from conftest import FakeOpener, json_reply
from nicos_scripts.connectors import journal_sources as js

TZ = ZoneInfo("Europe/Paris")
LO = datetime(2026, 10, 20, 4, tzinfo=TZ)
HI = LO + timedelta(days=1)
ME = "me@work.example"


def ics(*events):
    return ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:test\r\n" + "".join(events)
            + "END:VCALENDAR\r\n").encode()


def vevent(uid, start, end, title, attendees=(), extra=""):
    att = "".join(f"ATTENDEE;CUTYPE={c};PARTSTAT={p}:mailto:{m}\r\n" for m, c, p in attendees)
    return (f"BEGIN:VEVENT\r\nUID:{uid}\r\nDTSTART;TZID=Europe/Paris:{start}\r\n"
            f"DTEND;TZID=Europe/Paris:{end}\r\nSUMMARY:{title}\r\n{att}{extra}END:VEVENT\r\n")


def person(m, p="ACCEPTED"):
    return (m, "INDIVIDUAL", p)


DAY = [
    ics(vevent("standup", "20261019T093000", "20261019T094500", "Standup",
               [person(ME), person("a@x"), person("b@x")], "RRULE:FREQ=DAILY;COUNT=5\r\n")),
    ics(vevent("sync", "20261020T100000", "20261020T110000", "Sync",
               [person(ME), person("c@x"), ("room-1@resource.calendar.google.com", "RESOURCE", "ACCEPTED")])),
    ics(vevent("overlap", "20261020T103000", "20261020T113000", "Overlap", [person(ME), person("a@x")])),
    ics(vevent("declined", "20261020T140000", "20261020T150000", "Nope", [person(ME, "DECLINED"), person("d@x")])),
    ics(vevent("focus", "20261020T160000", "20261020T170000", "Focus block", [person(ME)])),
    ics(vevent("gone", "20261020T170000", "20261020T180000", "Cancelled", [person(ME), person("e@x")],
               "STATUS:CANCELLED\r\n")),
]


def test_expand_unrolls_recurrences_and_drops_cancelled():
    events = js.expand(DAY, LO, HI, TZ)
    assert [e.title for e in events] == ["Standup", "Sync", "Overlap", "Nope", "Focus block"]
    assert events[0].start == datetime(2026, 10, 20, 9, 30, tzinfo=TZ)


def test_owner_is_the_attendee_on_most_events():
    assert js.owner(js.expand(DAY, LO, HI, TZ)) == ME


def test_work_summary_merges_overlaps_skips_declined_rooms_and_solo_blocks():
    n, minutes, people = js.work_summary(js.expand(DAY, LO, HI, TZ), LO, HI, ME)
    # standup 15 min + sync 10:00-11:30 merged with overlap = 105 min; Nope declined; Focus solo
    assert (n, minutes, people) == (3, 105, 3)   # a, b, c — not the room, not d


def test_no_meetings_is_none():
    assert js.work_summary([], LO, HI, ME) is None


def test_personal_lines_all_day_first():
    allday = ics("BEGIN:VEVENT\r\nUID:x\r\nDTSTART;VALUE=DATE:20261020\r\nDTEND;VALUE=DATE:20261021\r\n"
                 "SUMMARY:Holiday\r\nEND:VEVENT\r\n")
    dinner = ics(vevent("d", "20261020T190000", "20261020T210000", "Dinner"))
    events = js.expand([dinner, allday], LO, HI, TZ)
    assert js.personal_lines(events, TZ) == ["- **Journée** Holiday", "- **19:00-21:00** Dinner"]


def test_calendar_blobs_decodes_and_filters_by_name():
    sent = []

    def run(cmd):
        sent.append(cmd[cmd.index("-c") + 1])
        return base64.b64encode(b"BEGIN:VCALENDAR").decode() + "\n"

    assert js.calendar_blobs(run, ["PERSO", "O'Brien"], 100, 200) == [b"BEGIN:VCALENDAR"]
    assert "'PERSO', 'O''Brien'" in sent[0] and "< 200" in sent[0] and "> 100" in sent[0]
    assert "o.deleted_at IS NULL" in sent[0]  # trashed events stay in the table


def test_weather_line():
    op = FakeOpener([json_reply({"daily": {"weather_code": [61], "temperature_2m_min": [5.6],
                                           "temperature_2m_max": [12.6], "precipitation_sum": [0.3]}})])
    assert js.weather_line(date(2026, 10, 19), 48.8566, 2.3522, op) == "🌧 Pluie légère · 6-13 °C · 0,3 mm"
    assert "start_date=2026-10-19" in op.last.full_url and "timezone=Europe%2FParis" in op.last.full_url
    dry = FakeOpener([json_reply({"daily": {"weather_code": [0], "temperature_2m_min": [3],
                                            "temperature_2m_max": [9], "precipitation_sum": [0]}})])
    assert js.weather_line(date(2026, 10, 19), 48.8, 2.3, dry) == "☀️ Ciel dégagé · 3-9 °C"


def test_mirrored_calendars_are_merged_keeping_the_fuller_title():
    a = ics(vevent("p", "20261020T170000", "20261020T180000", "Heure de conduite"))
    b = ics(vevent("g", "20261020T170000", "20261020T180000", "Heure de conduite — En Voiture Simone"))
    c = ics(vevent("o", "20261020T170000", "20261020T180000", "Something else"))
    lines = js.personal_lines(js.expand([a, b, c], LO, HI, TZ), TZ)
    assert sorted(lines) == ["- **17:00-18:00** Heure de conduite — En Voiture Simone",
                             "- **17:00-18:00** Something else"]


def test_music_section_top_artists_tracks_and_rest():
    L = js.Listen
    plays = [L("A1", "A", 3600), L("B1", "B", 60), L("A2", "A", 60), L("A1", "A", 60), L("A3", "A", 0),
             L("A4", "A", 0), L("X", "", 0), *[L(f"T{i}", f"Z{i}", 0) for i in range(5)]]
    head, lines = js.music_section(plays, top=3)
    assert head == "12 titres · 1 h 03"
    assert lines[0] == "- **A** · A1 (2), A2, A3 …"
    assert lines[1:] == ["- **B** · B1", "- **Artiste inconnu** · X", "- *et 5 autres artistes*"]
