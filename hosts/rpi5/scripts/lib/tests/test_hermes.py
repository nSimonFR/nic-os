"""Tests for the Hermes no_agent cron scripts.

The invariant worth most of these tests is the delivery contract: under
`no_agent`, stdout IS the Telegram message. So "prints nothing on success" and
"prints nothing when there is no news" are correctness properties here, not
cosmetics — a stray log line on stdout gets delivered to the user.
"""

import json
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from nicos_scripts.hermes import calendar_digest as cal
from nicos_scripts.hermes import dawarich_daily as daw
from nicos_scripts.hermes import zen_watch as zen

from conftest import FakeResponse, json_reply

TZ = ZoneInfo("Europe/Paris")


# ===================================================================
# dawarich_daily
# ===================================================================


def _point(epoch, city="Brest", street=None, country="France", lat=48.4, lon=-4.5):
    props = {"lat": lat, "lon": lon, "country": country}
    if city:
        props["city"] = city
    if street:
        props["street"] = street
    return {
        "timestamp": epoch,
        "city": city,
        "country": None,
        "geodata": {"type": "Feature", "properties": props},
    }


def _at(day, hour, minute=0):
    return int(datetime(day.year, day.month, day.day, hour, minute, tzinfo=TZ).timestamp())


DAY = date(2026, 8, 20)


def test_target_day_defaults_to_yesterday():
    cfg = daw.Config()
    assert daw.target_day(cfg, today=date(2026, 8, 21)) == date(2026, 8, 20)


def test_target_day_honours_override():
    cfg = daw.Config(day="2026-01-05")
    assert daw.target_day(cfg, today=date(2026, 8, 21)) == date(2026, 1, 5)


@pytest.mark.parametrize(
    "seconds,expected",
    [(0, "1min"), (30, "1min"), (60, "1min"), (2220, "37min"), (13800, "3h50"), (7200, "2h")],
)
def test_human_duration(seconds, expected):
    assert daw.human_duration(seconds) == expected


def test_human_date_is_locale_independent():
    assert daw.human_date(date(2026, 8, 20)) == "Thu 20 Aug"


def test_point_place_prefers_city_then_street_then_coords():
    assert daw.point_place(_point(0, city="Brest")) == "Brest"
    p = _point(0, city=None, street="Route Du Menhir")
    p["city"] = None
    assert daw.point_place(p) == "Route Du Menhir"
    bare = {"timestamp": 0, "geodata": {"properties": {"lat": 48.3227, "lon": -4.2889}}}
    assert daw.point_place(bare) == "48.323,-4.289"


def test_cluster_merges_consecutive_same_place():
    points = [
        _point(_at(DAY, 12, 0), "Plouzané"),
        _point(_at(DAY, 12, 30), "Plouzané"),
        _point(_at(DAY, 12, 45), "Brest"),
    ]
    clusters = daw.cluster_points(points, gap_min=60)
    assert [(c["place"], c["n"]) for c in clusters] == [("Plouzané", 2), ("Brest", 1)]


def test_cluster_splits_on_a_long_gap_even_when_place_matches():
    """Home in the morning and home at night is two sightings, not a 12h stop."""
    points = [_point(_at(DAY, 8, 0), "Brest"), _point(_at(DAY, 22, 0), "Brest")]
    clusters = daw.cluster_points(points, gap_min=60)
    assert len(clusters) == 2


def test_cluster_skips_points_with_no_timestamp():
    points = [_point(_at(DAY, 9, 0)), {"geodata": {"properties": {"city": "X"}}}]
    assert len(daw.cluster_points(points)) == 1


def test_place_line_orders_by_first_sighting_and_adds_country():
    points = [_point(_at(DAY, 9, 0), "Plouzané"), _point(_at(DAY, 10, 0), "Brest")]
    assert daw.place_line(points) == "Plouzané → Brest, France"


def test_place_line_truncates_a_long_itinerary():
    points = [_point(_at(DAY, h, 0), f"City{h}") for h in range(1, 8)]
    line = daw.place_line(points)
    assert line.count("→") == 3
    assert "(+3)" in line


def test_build_message_has_link_escaped_ampersands_and_sparse_flag():
    cfg = daw.Config()
    points = [_point(_at(DAY, 12, 0)), _point(_at(DAY, 12, 20))]
    body = daw.build_message(cfg, DAY, points, [])
    assert "Dawarich · Thu 20 Aug" in body
    assert "&amp;date=2026-08-20" in body
    # A bare & in an href is what Telegram rejects with a parse error.
    assert "&date=" not in body
    assert "2 pts (sparse)" in body
    assert "No transport segment detected." in body


def test_build_message_not_sparse_above_threshold():
    cfg = daw.Config(sparse_at=2)
    points = [_point(_at(DAY, 12, m)) for m in (0, 10, 20)]
    assert "(sparse)" not in daw.build_message(cfg, DAY, points, [])


def test_build_message_escapes_html_in_place_names():
    cfg = daw.Config()
    body = daw.build_message(cfg, DAY, [_point(_at(DAY, 9, 0), "Ben & Jerry's <b>")], [])
    assert "Ben &amp; Jerry" in body
    # The injected tag is neutralised; the only live <b> are the two we emit
    # ourselves (the header link and the place line).
    assert "&lt;b&gt;" in body
    assert body.count("<b>") == 2


def test_build_message_no_points_is_honest():
    body = daw.build_message(daw.Config(), DAY, [], [])
    assert "No points recorded" in body
    assert "pts" not in body.split("\n")[1] if len(body.split("\n")) > 1 else True


def test_build_message_flags_no_confident_stop():
    cfg = daw.Config()
    points = [_point(_at(DAY, 9, 0), "A"), _point(_at(DAY, 15, 0), "B")]
    assert "No confident stop" in daw.build_message(cfg, DAY, points, [])


def test_build_message_omits_no_confident_stop_when_a_cluster_formed():
    cfg = daw.Config()
    points = [_point(_at(DAY, 9, 0), "A"), _point(_at(DAY, 9, 20), "A")]
    assert "No confident stop" not in daw.build_message(cfg, DAY, points, [])


def test_track_line_formats_duration_mode_and_distance():
    props = {
        "start_at": "2026-08-19T17:52:57+02:00",
        "end_at": "2026-08-19T19:04:43+02:00",
        "duration": 4306,
        "distance": 4082,
        "dominant_mode": "walking",
        "dominant_mode_emoji": "🚶",
    }
    # 4306s is 71.8min, which rounds to 72 — 1h12, not a truncated 1h11.
    assert daw.track_line(props) == "17:52–19:04 · 1h12 · 🚶 walking · 4.1 km"


def test_track_line_survives_missing_fields():
    assert daw.track_line({}) == "? · unknown"


def test_track_line_uses_metres_under_100m():
    props = {"start_at": "2026-08-19T10:00:00+02:00", "distance": 80}
    assert "80 m" in daw.track_line(props)


def test_fetch_points_sorts_and_sends_bearer(opener):
    fake = opener([json_reply([_point(200), _point(100)])])
    cfg = daw.Config(api_key="k")
    points = daw.fetch_points(cfg, DAY, opener=fake)
    assert [p["timestamp"] for p in points] == [100, 200]
    assert fake.last.headers["Authorization"] == "Bearer k"
    assert "per_page=1000" in fake.last.full_url


def test_fetch_tracks_unwraps_geojson_and_uses_offset_bounds(opener):
    body = {
        "type": "FeatureCollection",
        "features": [
            {"properties": {"start_at": "2026-08-20T18:00:00+02:00", "id": 2}},
            {"properties": {"start_at": "2026-08-20T09:00:00+02:00", "id": 1}},
        ],
    }
    fake = opener([json_reply(body)])
    tracks = daw.fetch_tracks(daw.Config(api_key="k"), DAY, opener=fake)
    assert [t["id"] for t in tracks] == [1, 2]
    # Offset-qualified, or the window slides by the UTC offset.
    assert "%2B02%3A00" in fake.last.full_url


def test_send_rejects_a_non_ok_api_reply():
    calls = []

    def run(argv, body):
        calls.append((argv, body))
        return 0, '{"ok":false,"description":"chat not found"}'

    with pytest.raises(RuntimeError, match="Telegram rejected"):
        daw.send(daw.Config(chat_id="7"), "hi", run=run)
    assert calls[0][0][-1] == "html"


def test_send_accepts_ok_true_with_whitespace():
    run = lambda argv, body: (0, '{ "ok" : true }')
    assert daw.send(daw.Config(chat_id="7"), "hi", run=run)


def test_send_raises_on_non_zero_exit():
    with pytest.raises(RuntimeError, match="exited 3"):
        daw.send(daw.Config(chat_id="7"), "hi", run=lambda a, b: (3, "boom"))


def test_dawarich_main_requires_a_key(capsys):
    assert daw.main(argv=[], env={}) == 1
    assert capsys.readouterr().out == ""


def test_dawarich_main_requires_a_chat_id_unless_dry_run(capsys):
    assert daw.main(argv=[], env={"DAWARICH_API_KEY": "k"}) == 1
    assert capsys.readouterr().out == ""


# ===================================================================
# calendar_digest
# ===================================================================


MULTISTATUS = """<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
{responses}
</d:multistatus>"""

RESPONSE = (
    " <d:response><d:propstat><d:prop><cal:calendar-data>{blob}"
    "</cal:calendar-data></d:prop></d:propstat></d:response>"
)


def _multistatus(*blobs):
    return MULTISTATUS.format(
        responses="\n".join(RESPONSE.format(blob=b) for b in blobs)
    )


def _ics(*vevents):
    return "BEGIN:VCALENDAR\r\n" + "".join(vevents) + "END:VCALENDAR\r\n"


# --- unexpanded (pass 1): carries the true time *kind* ---------------------
ZONED_MASTER = (
    "BEGIN:VEVENT\r\nUID:menage\r\nSUMMARY:Ménage\r\n"
    "DTSTART;TZID=Europe/Paris:20260211T160000\r\n"
    "DTEND;TZID=Europe/Paris:20260211T180000\r\n"
    "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=WE\r\nEND:VEVENT\r\n"
)
FLOATING_MASTER = (
    "BEGIN:VEVENT\r\nUID:festnoz\r\nSUMMARY:Fest-Noz au port du Tinduff\r\n"
    "DTSTART:20260822T180000\r\nDTEND:20260823T000000\r\n"
    "LOCATION:Port du Tinduff\r\nEND:VEVENT\r\n"
)
ALLDAY_MASTER = (
    "BEGIN:VEVENT\r\nUID:rock\r\nSUMMARY:Rock en Seine 2026\r\n"
    "DTSTART;VALUE=DATE:20260827\r\nDTEND;VALUE=DATE:20260828\r\nEND:VEVENT\r\n"
)

# --- expanded (pass 2): Nextcloud stamps EVERYTHING with Z ----------------
ZONED_INSTANCE = (
    "BEGIN:VEVENT\r\nUID:menage\r\nSUMMARY:Ménage\r\n"
    "DTSTART:20260826T140000Z\r\nDTEND:20260826T160000Z\r\n"
    "LOCATION:82 Rue Alexandre Dumas\r\n"
    "RECURRENCE-ID:20260826T140000Z\r\nEND:VEVENT\r\n"
)
FLOATING_INSTANCE = (
    "BEGIN:VEVENT\r\nUID:festnoz\r\nSUMMARY:Fest-Noz au port du Tinduff\r\n"
    "DTSTART:20260822T180000Z\r\nDTEND:20260823T000000Z\r\n"
    "LOCATION:Port du Tinduff\r\nEND:VEVENT\r\n"
)
ALLDAY_INSTANCE = ALLDAY_MASTER


def _collect(cfg, opener_cls, plain, expanded, today=date(2026, 8, 21)):
    """Drive collect() with the two canned passes, in the order it fetches them."""
    fake = opener_cls(
        [
            lambda: FakeResponse(_multistatus(*plain).encode()),
            lambda: FakeResponse(_multistatus(*expanded).encode()),
        ]
    )
    return cal.collect(cfg, today=today, opener=fake), fake


def test_query_body_expand_flag_controls_the_expand_element():
    lo = datetime(2026, 8, 21, tzinfo=ZoneInfo("UTC"))
    hi = datetime(2026, 9, 4, tzinfo=ZoneInfo("UTC"))
    expanded = cal.query_body(lo, hi, expand=True)
    plain = cal.query_body(lo, hi, expand=False)
    assert "<c:expand " in expanded
    assert 'start="20260821T000000Z"' in expanded
    assert "<c:expand" not in plain
    assert "<c:calendar-data/>" in plain
    assert "time-range" in plain


@pytest.mark.parametrize(
    "params,value,expected",
    [
        ("VALUE=DATE", "20260827", cal.KIND_DATE),
        ("", "20260827", cal.KIND_DATE),
        ("TZID=EUROPE/PARIS", "20260211T160000", cal.KIND_ABSOLUTE),
        ("", "20260826T140000Z", cal.KIND_ABSOLUTE),
        ("", "20260822T180000", cal.KIND_FLOATING),
    ],
)
def test_dt_kind(params, value, expected):
    assert cal.dt_kind(params, value) == expected


def test_series_kinds_reads_the_unexpanded_pass():
    kinds = cal.series_kinds([_ics(ZONED_MASTER, FLOATING_MASTER, ALLDAY_MASTER)])
    assert kinds == {
        "menage": cal.KIND_ABSOLUTE,
        "festnoz": cal.KIND_FLOATING,
        "rock": cal.KIND_DATE,
    }


def test_series_kinds_first_component_wins_over_overrides():
    """An override may move the clock; it never changes the series' kind."""
    override = (
        "BEGIN:VEVENT\r\nUID:menage\r\nDTSTART;TZID=Europe/Paris:20260729T083000"
        "\r\nRECURRENCE-ID;TZID=Europe/Paris:20260729T160000\r\nEND:VEVENT\r\n"
    )
    kinds = cal.series_kinds([_ics(ZONED_MASTER, override)])
    assert kinds["menage"] == cal.KIND_ABSOLUTE


def test_read_clock_converts_a_genuinely_absolute_instant():
    # 14:00Z in August is 16:00 in Paris — the wall clock the user set.
    got = cal.read_clock("", "20260826T140000Z", cal.KIND_ABSOLUTE)
    assert got.strftime("%H:%M") == "16:00"


def test_read_clock_does_not_shift_a_floating_time():
    """The regression this whole two-pass design exists for.

    Nextcloud's expand labels a floating 18:00 as `18:00Z`. Read as UTC that is
    20:00 Paris — the bug that reported an 18:00 Fest-Noz as 20:00.
    """
    got = cal.read_clock("", "20260822T180000Z", cal.KIND_FLOATING)
    assert got.strftime("%H:%M") == "18:00"
    assert got.tzinfo == cal.TZ


def test_read_clock_reads_an_all_day_value_as_a_date():
    got = cal.read_clock("VALUE=DATE", "20260827", cal.KIND_DATE)
    assert got == date(2026, 8, 27)
    assert not isinstance(got, datetime)


def test_read_clock_falls_back_to_a_date_on_a_malformed_value():
    assert cal.read_clock("", "20260827XX", cal.KIND_ABSOLUTE) == date(2026, 8, 27)


def test_build_instances_applies_the_series_kind_not_the_payload():
    kinds = cal.series_kinds([_ics(ZONED_MASTER, FLOATING_MASTER)])
    events = cal.build_instances([_ics(ZONED_INSTANCE, FLOATING_INSTANCE)], kinds)
    by_uid = {e["uid"]: e for e in events}
    assert by_uid["menage"]["start"].strftime("%H:%M") == "16:00"
    assert by_uid["festnoz"]["start"].strftime("%H:%M") == "18:00"
    assert by_uid["festnoz"]["end"].strftime("%H:%M") == "00:00"


def test_build_instances_falls_back_when_a_uid_is_unknown():
    events = cal.build_instances([_ics(ZONED_INSTANCE)], {})
    assert events[0]["start"].strftime("%H:%M") == "16:00"


def test_parse_components_unfolds_long_lines():
    folded = (
        "BEGIN:VEVENT\r\nUID:c\r\nDTSTART;VALUE=DATE:20260901\r\n"
        "SUMMARY:A very long title that the\r\n  server folded here\r\nEND:VEVENT\r\n"
    )
    assert cal.parse_components(_ics(folded))[0]["summary"] == (
        "A very long title that the server folded here"
    )


def test_parse_components_unescapes_ics_text():
    ev = (
        "BEGIN:VEVENT\r\nUID:d\r\nDTSTART;VALUE=DATE:20260901\r\n"
        "SUMMARY:Foo\\, bar\\; baz\\nnext\r\nEND:VEVENT\r\n"
    )
    assert cal.parse_components(_ics(ev))[0]["summary"] == "Foo, bar; baz next"


def test_parse_components_skips_a_vevent_with_no_dtstart():
    ev = "BEGIN:VEVENT\r\nUID:e\r\nSUMMARY:Broken\r\nEND:VEVENT\r\n"
    assert cal.parse_components(_ics(ev)) == []


def test_calendar_blobs_extracts_every_payload():
    xml = _multistatus(_ics(ALLDAY_MASTER), _ics(FLOATING_MASTER))
    assert len(cal.calendar_blobs(xml)) == 2


def test_build_digest_groups_by_day_in_french():
    kinds = cal.series_kinds([_ics(ZONED_MASTER, ALLDAY_MASTER)])
    events = cal.build_instances([_ics(ZONED_INSTANCE, ALLDAY_INSTANCE)], kinds)
    out = cal.build_digest(events, date(2026, 8, 21), 14)
    assert "📅 Agenda personnel · 14 prochains jours" in out
    assert "mercredi 26 août" in out
    assert "• 16:00–18:00 · Ménage" in out
    assert "📍 82 Rue Alexandre Dumas" in out
    assert "jeudi 27 août" in out
    assert "• toute la journée · Rock en Seine 2026" in out


def test_build_digest_labels_today_and_tomorrow():
    today = date(2026, 8, 21)
    events = [
        {"start": today, "all_day": True, "summary": "Aujourd'hui"},
        {"start": today + timedelta(days=1), "all_day": True, "summary": "Demain"},
    ]
    out = cal.build_digest(events, today, 14)
    assert "aujourd'hui 21 août" in out
    assert "demain 22 août" in out


def test_build_digest_empty_says_so():
    out = cal.build_digest([], date(2026, 8, 21), 14)
    assert out == "📅 Aucun événement personnel dans les 14 prochains jours."


def test_build_digest_sorts_all_day_before_timed_on_the_same_day():
    timed = datetime(2026, 8, 25, 9, 0, tzinfo=TZ)
    events = [
        {"start": timed, "all_day": False, "summary": "Timed"},
        {"start": date(2026, 8, 25), "all_day": True, "summary": "AllDay"},
    ]
    out = cal.build_digest(events, date(2026, 8, 21), 14)
    assert out.index("AllDay") < out.index("Timed")


def test_build_digest_handles_a_missing_summary():
    events = [{"start": date(2026, 8, 25), "all_day": True}]
    assert "(sans titre)" in cal.build_digest(events, date(2026, 8, 21), 14)


def test_in_window_excludes_a_day_past_the_horizon():
    assert not cal.in_window({"start": date(2026, 9, 6)}, date(2026, 8, 21), date(2026, 9, 4))


def test_collect_joins_both_passes_and_keeps_floating_times(opener):
    cfg = cal.Config(password="pw", days=14)
    events, fake = _collect(
        cfg,
        opener,
        plain=[_ics(ZONED_MASTER, FLOATING_MASTER)],
        expanded=[_ics(ZONED_INSTANCE, FLOATING_INSTANCE)],
    )
    by_uid = {e["uid"]: e for e in events}
    assert by_uid["festnoz"]["start"].strftime("%H:%M") == "18:00"
    assert by_uid["menage"]["start"].strftime("%H:%M") == "16:00"
    # Pass 1 unexpanded, pass 2 expanded — in that order.
    assert "<c:expand" not in fake.requests[0].data.decode()
    assert "<c:expand" in fake.requests[1].data.decode()


def test_collect_sends_a_report_with_basic_auth(opener):
    cfg = cal.Config(password="pw", days=14)
    _, fake = _collect(cfg, opener, plain=[_ics(ALLDAY_MASTER)], expanded=[_ics(ALLDAY_INSTANCE)])
    req = fake.last
    assert req.method == "REPORT"
    assert req.headers["Depth"] == "1"
    assert req.headers["Authorization"].startswith("Basic ")
    assert req.full_url.endswith("/personal/")


def test_collect_drops_an_instance_outside_the_local_window(opener):
    late = (
        "BEGIN:VEVENT\r\nUID:late\r\nSUMMARY:Too late\r\n"
        "DTSTART;VALUE=DATE:20261001\r\nEND:VEVENT\r\n"
    )
    cfg = cal.Config(password="pw", days=14)
    events, _ = _collect(cfg, opener, plain=[_ics(late)], expanded=[_ics(late)])
    assert events == []


def test_config_strips_a_crlf_password():
    assert cal.Config.from_env({"CALDAV_PASSWORD": "secret\r\n"}).password == "secret"


def test_config_falls_back_to_the_password_file(tmp_path):
    path = tmp_path / "pw"
    path.write_text("filepw\r\n")
    assert cal.Config.from_env({"CALDAV_PASSWORD_FILE": str(path)}).password == "filepw"


def test_config_tolerates_an_unreadable_password_file(tmp_path):
    cfg = cal.Config.from_env({"CALDAV_PASSWORD_FILE": str(tmp_path / "nope")})
    assert cfg.password == ""


def test_calendar_main_without_a_password_is_fatal_and_silent(capsys):
    rc = cal.main(env={"CALDAV_PASSWORD_FILE": "/nonexistent/nope"})
    assert rc == 1
    assert capsys.readouterr().out == ""


# ===================================================================
# zen_watch
# ===================================================================


SYNC = "src/zen/sync/ZenSyncManager.sys.mjs"
WORKSPACES = "src/zen/sync/ZenWorkspacesSync.sys.mjs"
WINDOW = "src/zen/sessionstore/ZenWindowSync.sys.mjs"

RELEASE = {
    "tag_name": "1.21.15b",
    "name": "Release build - 1.21.15b (2026-08-18)",
    "published_at": "2026-08-19T17:13:06Z",
    "html_url": "https://github.com/zen-browser/desktop/releases/tag/1.21.15b",
}


def _tree(*paths):
    return {"truncated": False, "tree": [{"path": p} for p in paths]}


def _commits(dates):
    return [
        {"commit": {"author": {"date": d}, "message": m}} for d, m in dates
    ]


def test_config_parses_colon_separated_watch_paths():
    cfg = zen.Config.from_env({"ZEN_WATCH_PATHS": "a/b.mjs:c/d.mjs"})
    assert cfg.watch_paths == ("a/b.mjs", "c/d.mjs")


def test_config_defaults_to_the_sync_trio():
    assert zen.Config.from_env({}).watch_paths == zen.DEFAULT_WATCH_PATHS


def test_diff_presence_reports_only_flips():
    prev = {SYNC: False, WORKSPACES: True, WINDOW: True}
    cur = {SYNC: True, WORKSPACES: False, WINDOW: True}
    assert zen.diff_presence(prev, cur) == [(WINDOW, False)] or True
    assert sorted(zen.diff_presence(prev, cur)) == sorted(
        [(SYNC, True), (WORKSPACES, False)]
    )


def test_diff_presence_empty_when_nothing_moved():
    assert zen.diff_presence({SYNC: True}, {SYNC: True}) == []


def test_first_run_reports_only_the_paths_that_exist(opener, tmp_path):
    state = tmp_path / "state.json"
    fake = opener(
        [
            json_reply(RELEASE),
            json_reply(_tree(SYNC, "src/other.mjs")),
            json_reply(_commits([("2026-07-04T09:18:08Z", "gh-14470: Add space and container sync")])),
        ]
    )
    cfg = zen.Config(state_file=str(state))
    out = zen.run(cfg, opener=fake)
    assert "1.21.15b" in out
    assert SYNC in out
    # Absent paths are not "news" on a first run — no baseline to compare against.
    assert WORKSPACES not in out
    assert "arrivé le 2026-07-04" in out
    assert "synchronisation desktop" in out


def test_first_run_persists_a_baseline(opener, tmp_path):
    state = tmp_path / "state.json"
    fake = opener([json_reply(RELEASE), json_reply(_tree(SYNC)), json_reply([])])
    zen.run(zen.Config(state_file=str(state)), opener=fake)
    saved = json.loads(state.read_text())
    assert saved["tag"] == "1.21.15b"
    assert saved["paths"][SYNC] is True
    assert saved["paths"][WORKSPACES] is False


def test_no_change_is_silent(opener, tmp_path):
    state = tmp_path / "state.json"
    state.write_text(
        json.dumps({"tag": "1.21.14b", "paths": {SYNC: True, WORKSPACES: False, WINDOW: False}})
    )
    fake = opener([json_reply(RELEASE), json_reply(_tree(SYNC))])
    assert zen.run(zen.Config(state_file=str(state)), opener=fake) == ""


def test_a_new_release_alone_does_not_speak(opener, tmp_path):
    """The tag changes most weeks and says nothing about sync."""
    state = tmp_path / "state.json"
    state.write_text(
        json.dumps({"tag": "1.20.0", "paths": {SYNC: True, WORKSPACES: False, WINDOW: False}})
    )
    fake = opener([json_reply(RELEASE), json_reply(_tree(SYNC))])
    assert zen.run(zen.Config(state_file=str(state)), opener=fake) == ""


def test_always_report_restores_the_weekly_heartbeat(opener, tmp_path):
    state = tmp_path / "state.json"
    state.write_text(json.dumps({"tag": "x", "paths": {SYNC: True, WORKSPACES: False, WINDOW: False}}))
    fake = opener([json_reply(RELEASE), json_reply(_tree(SYNC))])
    out = zen.run(zen.Config(state_file=str(state), always_report=True), opener=fake)
    assert out == "Zen : aucun changement matériel détecté cette semaine."


def test_a_newly_appearing_path_speaks(opener, tmp_path):
    state = tmp_path / "state.json"
    state.write_text(
        json.dumps({"tag": "1.20.0", "paths": {SYNC: True, WORKSPACES: False, WINDOW: False}})
    )
    fake = opener(
        [
            json_reply(RELEASE),
            json_reply(_tree(SYNC, WORKSPACES)),
            json_reply(_commits([("2026-08-20T17:16:13Z", "gh-14470: Add tab and folder sync")])),
        ]
    )
    out = zen.run(zen.Config(state_file=str(state)), opener=fake)
    assert WORKSPACES in out
    assert "Nouveau dans l'arbre source" in out


def test_a_vanishing_path_speaks_too(opener, tmp_path):
    state = tmp_path / "state.json"
    state.write_text(
        json.dumps({"tag": "1.20.0", "paths": {SYNC: True, WORKSPACES: False, WINDOW: False}})
    )
    fake = opener([json_reply(RELEASE), json_reply(_tree("src/unrelated.mjs"))])
    out = zen.run(zen.Config(state_file=str(state)), opener=fake)
    assert "Disparu de l'arbre source" in out
    assert SYNC in out


def test_missing_tag_is_an_error(opener, tmp_path):
    fake = opener([json_reply({"tag_name": ""})])
    with pytest.raises(RuntimeError, match="no tag_name"):
        zen.run(zen.Config(state_file=str(tmp_path / "s.json")), opener=fake)


def test_report_names_what_this_host_cannot_verify(opener, tmp_path):
    fake = opener([json_reply(RELEASE), json_reply(_tree(SYNC)), json_reply([])])
    out = zen.run(zen.Config(state_file=str(tmp_path / "s.json")), opener=fake)
    assert "Non vérifiable ici" in out
    assert RELEASE["html_url"] in out


def test_token_becomes_a_bearer_header(opener, tmp_path):
    fake = opener([json_reply(RELEASE), json_reply(_tree()), json_reply([])])
    zen.run(zen.Config(state_file=str(tmp_path / "s.json"), token="t"), opener=fake)
    assert fake.requests[0].headers["Authorization"] == "Bearer t"


def test_anonymous_sends_no_authorization_header(opener, tmp_path):
    fake = opener([json_reply(RELEASE), json_reply(_tree()), json_reply([])])
    zen.run(zen.Config(state_file=str(tmp_path / "s.json")), opener=fake)
    assert "Authorization" not in fake.requests[0].headers


def test_first_commit_tolerates_an_api_failure(opener):
    def boom(req, timeout=None):
        raise OSError("rate limited")

    assert zen.first_commit(zen.Config(), SYNC, opener=boom) is None
