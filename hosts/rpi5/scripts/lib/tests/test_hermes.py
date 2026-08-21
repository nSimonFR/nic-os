"""Tests for the Hermes no_agent cron scripts.

The invariant worth most of these is the delivery contract: stdout IS the Telegram
message, so "prints nothing on success" and "prints nothing when there is no news"
are correctness properties, not cosmetics.
"""

import json
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from conftest import FakeResponse, json_reply
from nicos_scripts.hermes import calendar_digest as cal
from nicos_scripts.hermes import cron_check as chk
from nicos_scripts.hermes import dawarich_daily as daw
from nicos_scripts.hermes import zen_watch as zen

TZ = ZoneInfo("Europe/Paris")
DAY = date(2026, 8, 20)


# ===================================================================
# dawarich_daily
# ===================================================================


def _point(epoch, city="Brest", street=None, country="France"):
    props = {"lat": 48.4, "lon": -4.5, "country": country}
    if city:
        props["city"] = city
    if street:
        props["street"] = street
    return {"timestamp": epoch, "city": city, "geodata": {"properties": props}}


def _at(hour, minute=0):
    return int(datetime(DAY.year, DAY.month, DAY.day, hour, minute, tzinfo=TZ).timestamp())


def test_target_day_defaults_to_yesterday_and_honours_the_override():
    assert daw.target_day(daw.Config(), today=date(2026, 8, 21)) == DAY
    assert daw.target_day(daw.Config(day="2026-01-05")) == date(2026, 1, 5)


@pytest.mark.parametrize(
    "seconds,expected",
    [(0, "1min"), (30, "1min"), (2220, "37min"), (4306, "1h12"), (13800, "3h50"), (7200, "2h")],
)
def test_human_duration(seconds, expected):
    assert daw.human_duration(seconds) == expected


def test_point_place_prefers_city_then_street_then_coords():
    assert daw.point_place(_point(0, city="Brest")) == "Brest"
    assert daw.point_place(_point(0, city=None, street="Route Du Menhir")) == "Route Du Menhir"
    assert daw.point_place({"geodata": {"properties": {"lat": 48.3227, "lon": -4.2889}}}) == (
        "48.323,-4.289"
    )


def test_cluster_merges_same_place_but_splits_on_a_long_gap():
    """Home this morning and home tonight is two sightings, not a 14h stop."""
    merged = daw.cluster_points(
        [_point(_at(12, 0), "Plouzané"), _point(_at(12, 30), "Plouzané"), _point(_at(12, 45), "Brest")]
    )
    assert [(c["place"], c["n"]) for c in merged] == [("Plouzané", 2), ("Brest", 1)]
    assert len(daw.cluster_points([_point(_at(8), "Brest"), _point(_at(22), "Brest")])) == 2


def test_cluster_skips_points_with_no_timestamp():
    assert len(daw.cluster_points([_point(_at(9)), {"geodata": {"properties": {"city": "X"}}}])) == 1


def test_place_line_orders_by_first_sighting_and_truncates():
    assert daw.place_line([_point(_at(9), "Plouzané"), _point(_at(10), "Brest")]) == (
        "Plouzané → Brest, France"
    )
    line = daw.place_line([_point(_at(h), f"City{h}") for h in range(1, 8)])
    assert line.count("→") == 3 and "(+3)" in line


def test_build_message_escapes_ampersands_and_html_and_flags_sparse():
    body = daw.build_message(daw.Config(), DAY, [_point(_at(12), "Ben & Jerry's <b>")], [])
    assert "Dawarich · Thu 20 Aug" in body
    # A bare & in an href is what Telegram rejects with a parse error.
    assert "&amp;date=2026-08-20" in body and "&date=" not in body
    assert "1 pts (sparse)" in body
    # The injected tag is neutralised; the only live <b> are the two we emit.
    assert "Ben &amp; Jerry" in body and "&lt;b&gt;" in body and body.count("<b>") == 2
    assert "No transport segment detected." in body


def test_build_message_is_honest_about_no_points_and_no_stops():
    assert "No points recorded" in daw.build_message(daw.Config(), DAY, [], [])
    scattered = [_point(_at(9), "A"), _point(_at(15), "B")]
    assert "No confident stop" in daw.build_message(daw.Config(), DAY, scattered, [])
    dwelt = [_point(_at(9, 0), "A"), _point(_at(9, 20), "A")]
    assert "No confident stop" not in daw.build_message(daw.Config(), DAY, dwelt, [])


def test_build_message_drops_the_sparse_flag_above_the_threshold():
    points = [_point(_at(12, m)) for m in (0, 10, 20)]
    assert "(sparse)" not in daw.build_message(daw.Config(sparse_at=2), DAY, points, [])


def test_track_line_formats_and_survives_missing_fields():
    assert daw.track_line(
        {
            "start_at": "2026-08-19T17:52:57+02:00",
            "end_at": "2026-08-19T19:04:43+02:00",
            "duration": 4306,
            "distance": 4082,
            "dominant_mode": "walking",
            "dominant_mode_emoji": "🚶",
        }
    ) == "17:52–19:04 · 1h12 · 🚶 walking · 4.1 km"
    assert daw.track_line({}) == "? · unknown"
    assert "80 m" in daw.track_line({"start_at": "2026-08-19T10:00:00+02:00", "distance": 80})


def test_fetch_points_sorts_and_authenticates(opener):
    fake = opener([json_reply([_point(200), _point(100)])])
    points = daw.fetch_points(daw.Config(api_key="k"), DAY, opener=fake)
    assert [p["timestamp"] for p in points] == [100, 200]
    assert fake.last.headers["Authorization"] == "Bearer k"
    assert "per_page=1000" in fake.last.full_url


def test_fetch_tracks_unwraps_geojson_and_uses_offset_bounds(opener):
    body = {
        "features": [
            {"properties": {"start_at": "2026-08-20T18:00:00+02:00", "id": 2}},
            {"properties": {"start_at": "2026-08-20T09:00:00+02:00", "id": 1}},
        ]
    }
    fake = opener([json_reply(body)])
    assert [t["id"] for t in daw.fetch_tracks(daw.Config(api_key="k"), DAY, opener=fake)] == [1, 2]
    # Offset-qualified, or the window slides by the UTC offset.
    assert "%2B02%3A00" in fake.last.full_url


def test_send_checks_the_api_reply_not_just_the_exit_code():
    """telegram-send always exits 0 by design, so `ok` is the only real signal."""
    with pytest.raises(RuntimeError, match="Telegram rejected"):
        daw.send(daw.Config(chat_id="7"), "hi", run=lambda a, b: (0, '{"ok":false}'))
    with pytest.raises(RuntimeError, match="exited 3"):
        daw.send(daw.Config(chat_id="7"), "hi", run=lambda a, b: (3, "boom"))
    assert daw.send(daw.Config(chat_id="7"), "hi", run=lambda a, b: (0, '{ "ok" : true }'))


def test_dawarich_main_bails_silently_on_missing_config(capsys):
    assert daw.main(argv=[], env={}) == 1
    assert daw.main(argv=[], env={"DAWARICH_API_KEY": "k"}) == 1
    assert capsys.readouterr().out == ""


# ===================================================================
# calendar_digest
# ===================================================================


RESPONSE = (
    " <d:response><d:propstat><d:prop><cal:calendar-data>{blob}"
    "</cal:calendar-data></d:prop></d:propstat></d:response>"
)


def _multistatus(*blobs):
    return (
        '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" '
        'xmlns:cal="urn:ietf:params:xml:ns:caldav">'
        + "".join(RESPONSE.format(blob=b) for b in blobs)
        + "</d:multistatus>"
    )


def _ics(*vevents):
    return "BEGIN:VCALENDAR\r\n" + "".join(vevents) + "END:VCALENDAR\r\n"


# Unexpanded (pass 1) — carries the true time kind.
ZONED_MASTER = (
    "BEGIN:VEVENT\r\nUID:menage\r\nSUMMARY:Ménage\r\n"
    "DTSTART;TZID=Europe/Paris:20260211T160000\r\n"
    "DTEND;TZID=Europe/Paris:20260211T180000\r\n"
    "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=WE\r\nEND:VEVENT\r\n"
)
FLOATING_MASTER = (
    "BEGIN:VEVENT\r\nUID:festnoz\r\nSUMMARY:Fest-Noz\r\n"
    "DTSTART:20260822T180000\r\nDTEND:20260823T000000\r\n"
    "LOCATION:Port du Tinduff\r\nEND:VEVENT\r\n"
)
ALLDAY = (
    "BEGIN:VEVENT\r\nUID:rock\r\nSUMMARY:Rock en Seine 2026\r\n"
    "DTSTART;VALUE=DATE:20260827\r\nDTEND;VALUE=DATE:20260828\r\nEND:VEVENT\r\n"
)

# Expanded (pass 2) — Nextcloud stamps EVERYTHING with Z, floating included.
ZONED_INSTANCE = (
    "BEGIN:VEVENT\r\nUID:menage\r\nSUMMARY:Ménage\r\n"
    "DTSTART:20260826T140000Z\r\nDTEND:20260826T160000Z\r\n"
    "LOCATION:82 Rue Alexandre Dumas\r\nEND:VEVENT\r\n"
)
FLOATING_INSTANCE = (
    "BEGIN:VEVENT\r\nUID:festnoz\r\nSUMMARY:Fest-Noz\r\n"
    "DTSTART:20260822T180000Z\r\nDTEND:20260823T000000Z\r\n"
    "LOCATION:Port du Tinduff\r\nEND:VEVENT\r\n"
)


def test_query_body_expand_flag_controls_the_expand_element():
    lo, hi = datetime(2026, 8, 21, tzinfo=cal.UTC), datetime(2026, 9, 4, tzinfo=cal.UTC)
    expanded, plain = cal.query_body(lo, hi, True), cal.query_body(lo, hi, False)
    assert "<c:expand " in expanded and 'start="20260821T000000Z"' in expanded
    assert "<c:expand" not in plain and "<c:calendar-data/>" in plain
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


def test_series_kinds_reads_pass_one_and_first_component_wins():
    """An override may move an occurrence's clock; never the series' kind."""
    override = (
        "BEGIN:VEVENT\r\nUID:menage\r\nDTSTART;VALUE=DATE:20260729\r\nEND:VEVENT\r\n"
    )
    kinds = cal.series_kinds([_ics(ZONED_MASTER, override, FLOATING_MASTER, ALLDAY)])
    assert kinds == {
        "menage": cal.KIND_ABSOLUTE,
        "festnoz": cal.KIND_FLOATING,
        "rock": cal.KIND_DATE,
    }


def test_read_clock_converts_absolute_but_never_shifts_floating():
    """The regression the two-pass design exists for: Nextcloud labels a floating
    18:00 as `18:00Z`, which read as UTC becomes 20:00 Paris."""
    assert cal.read_clock("", "20260826T140000Z", cal.KIND_ABSOLUTE).strftime("%H:%M") == "16:00"
    floating = cal.read_clock("", "20260822T180000Z", cal.KIND_FLOATING)
    assert floating.strftime("%H:%M") == "18:00" and floating.tzinfo == cal.TZ
    assert cal.read_clock("VALUE=DATE", "20260827", cal.KIND_DATE) == date(2026, 8, 27)
    assert cal.read_clock("", "20260827XX", cal.KIND_ABSOLUTE) == date(2026, 8, 27)


def test_build_instances_applies_the_series_kind_not_the_payload():
    kinds = cal.series_kinds([_ics(ZONED_MASTER, FLOATING_MASTER)])
    by_uid = {
        e["uid"]: e for e in cal.build_instances([_ics(ZONED_INSTANCE, FLOATING_INSTANCE)], kinds)
    }
    assert by_uid["menage"]["start"].strftime("%H:%M") == "16:00"
    assert by_uid["festnoz"]["start"].strftime("%H:%M") == "18:00"
    assert by_uid["festnoz"]["end"].strftime("%H:%M") == "00:00"
    # An unknown uid falls back to the payload's own claim.
    assert cal.build_instances([_ics(ZONED_INSTANCE)], {})[0]["start"].strftime("%H:%M") == "16:00"


def test_parse_components_unfolds_unescapes_and_skips_dtstart_less_events():
    folded = (
        "BEGIN:VEVENT\r\nUID:c\r\nDTSTART;VALUE=DATE:20260901\r\n"
        "SUMMARY:A long title that the\r\n  server folded\r\nEND:VEVENT\r\n"
    )
    assert cal.parse_components(_ics(folded))[0]["summary"] == "A long title that the server folded"
    escaped = (
        "BEGIN:VEVENT\r\nUID:d\r\nDTSTART;VALUE=DATE:20260901\r\n"
        "SUMMARY:Foo\\, bar\\; baz\\nnext\r\nEND:VEVENT\r\n"
    )
    assert cal.parse_components(_ics(escaped))[0]["summary"] == "Foo, bar; baz next"
    assert cal.parse_components(_ics("BEGIN:VEVENT\r\nUID:e\r\nEND:VEVENT\r\n")) == []


def test_build_digest_groups_by_day_in_french():
    kinds = cal.series_kinds([_ics(ZONED_MASTER, ALLDAY)])
    events = cal.build_instances([_ics(ZONED_INSTANCE, ALLDAY)], kinds)
    out = cal.build_digest(events, date(2026, 8, 21), 14)
    assert "📅 Agenda personnel · 14 prochains jours" in out
    assert "mercredi 26 août" in out and "• 16:00–18:00 · Ménage" in out
    assert "📍 82 Rue Alexandre Dumas" in out
    assert "jeudi 27 août" in out and "• toute la journée · Rock en Seine 2026" in out


def test_build_digest_labels_relative_days_and_sorts_all_day_first():
    today = date(2026, 8, 21)
    events = [
        {"start": today, "all_day": True, "summary": "A"},
        {"start": today + timedelta(days=1), "all_day": True, "summary": "B"},
        {"start": datetime(2026, 8, 25, 9, 0, tzinfo=TZ), "all_day": False, "summary": "Timed"},
        {"start": date(2026, 8, 25), "all_day": True, "summary": "AllDay"},
    ]
    out = cal.build_digest(events, today, 14)
    assert "aujourd'hui 21 août" in out and "demain 22 août" in out
    assert out.index("AllDay") < out.index("Timed")


def test_build_digest_empty_and_untitled():
    assert cal.build_digest([], date(2026, 8, 21), 14) == (
        "📅 Aucun événement personnel dans les 14 prochains jours."
    )
    untitled = [{"start": date(2026, 8, 25), "all_day": True}]
    assert "(sans titre)" in cal.build_digest(untitled, date(2026, 8, 21), 14)


def test_collect_joins_both_passes_in_order_and_filters_the_window(opener):
    late = "BEGIN:VEVENT\r\nUID:late\r\nDTSTART;VALUE=DATE:20261001\r\nEND:VEVENT\r\n"
    fake = opener(
        [
            lambda: FakeResponse(_multistatus(_ics(ZONED_MASTER, FLOATING_MASTER)).encode()),
            lambda: FakeResponse(
                _multistatus(_ics(ZONED_INSTANCE, FLOATING_INSTANCE, late)).encode()
            ),
        ]
    )
    events = cal.collect(cal.Config(password="pw"), today=date(2026, 8, 21), opener=fake)
    by_uid = {e["uid"]: e for e in events}
    assert by_uid["festnoz"]["start"].strftime("%H:%M") == "18:00"
    assert by_uid["menage"]["start"].strftime("%H:%M") == "16:00"
    assert "late" not in by_uid
    # Pass 1 unexpanded, pass 2 expanded — in that order.
    assert "<c:expand" not in fake.requests[0].data.decode()
    assert "<c:expand" in fake.requests[1].data.decode()
    assert fake.last.method == "REPORT"
    assert fake.last.headers["Depth"] == "1"
    assert fake.last.headers["Authorization"].startswith("Basic ")
    assert fake.last.full_url.endswith("/personal/")


def test_config_strips_crlf_and_tolerates_a_missing_password_file(tmp_path):
    assert cal.Config.from_env({"CALDAV_PASSWORD": "secret\r\n"}).password == "secret"
    path = tmp_path / "pw"
    path.write_text("filepw\r\n")
    assert cal.Config.from_env({"CALDAV_PASSWORD_FILE": str(path)}).password == "filepw"
    assert cal.Config.from_env({"CALDAV_PASSWORD_FILE": str(tmp_path / "nope")}).password == ""


def test_calendar_main_without_a_password_is_fatal_and_silent(capsys):
    assert cal.main(env={"CALDAV_PASSWORD_FILE": "/nonexistent/nope"}) == 1
    assert capsys.readouterr().out == ""


# ===================================================================
# zen_watch
# ===================================================================


SYNC = "src/zen/sync/ZenSyncManager.sys.mjs"
WORKSPACES = "src/zen/sync/ZenWorkspacesSync.sys.mjs"
RELEASE = {
    "tag_name": "1.21.15b",
    "published_at": "2026-08-19T17:13:06Z",
    "html_url": "https://github.com/zen-browser/desktop/releases/tag/1.21.15b",
}


def _tree(*paths):
    return {"truncated": False, "tree": [{"path": p} for p in paths]}


def _commit(when, message):
    return [{"commit": {"author": {"date": when}, "message": message}}]


def _state(tmp_path, paths):
    path = tmp_path / "state.json"
    path.write_text(json.dumps({"tag": "1.20.0", "paths": paths}))
    return str(path)


def test_config_parses_watch_paths_with_a_default():
    assert cal and zen.Config.from_env({"ZEN_WATCH_PATHS": "a/b.mjs:c/d.mjs"}).watch_paths == (
        "a/b.mjs",
        "c/d.mjs",
    )
    assert zen.Config.from_env({}).watch_paths == zen.DEFAULT_WATCH_PATHS


def test_diff_presence_reports_only_flips():
    prev, cur = {SYNC: False, WORKSPACES: True}, {SYNC: True, WORKSPACES: True}
    assert zen.diff_presence(prev, cur) == [(SYNC, True)]
    assert zen.diff_presence({SYNC: True}, {SYNC: True}) == []


def test_first_run_reports_only_what_exists_and_saves_a_baseline(opener, tmp_path):
    state = str(tmp_path / "state.json")
    fake = opener(
        [
            json_reply(RELEASE),
            json_reply(_tree(SYNC, "src/other.mjs")),
            json_reply(_commit("2026-07-04T09:18:08Z", "gh-14470: Add space and container sync")),
        ]
    )
    out = zen.run(zen.Config(state_file=state), opener=fake)
    assert "1.21.15b" in out and SYNC in out
    # Absent paths are not news on a first run — there is no baseline to diff.
    assert WORKSPACES not in out
    assert "arrivé le 2026-07-04" in out and "synchronisation desktop" in out
    assert "Non vérifiable ici" in out and RELEASE["html_url"] in out
    saved = json.loads(open(state).read())
    assert saved["tag"] == "1.21.15b"
    assert saved["paths"][SYNC] is True and saved["paths"][WORKSPACES] is False


def test_a_new_release_alone_stays_silent(opener, tmp_path):
    """The tag changes most weeks and says nothing about sync."""
    baseline = {SYNC: True, WORKSPACES: False, zen.DEFAULT_WATCH_PATHS[2]: False}
    fake = opener([json_reply(RELEASE), json_reply(_tree(SYNC))])
    assert zen.run(zen.Config(state_file=_state(tmp_path, baseline)), opener=fake) == ""


def test_always_report_restores_the_weekly_heartbeat(opener, tmp_path):
    baseline = {SYNC: True, WORKSPACES: False, zen.DEFAULT_WATCH_PATHS[2]: False}
    fake = opener([json_reply(RELEASE), json_reply(_tree(SYNC))])
    cfg = zen.Config(state_file=_state(tmp_path, baseline), always_report=True)
    assert zen.run(cfg, opener=fake) == "Zen : aucun changement matériel détecté cette semaine."


def test_an_appearing_path_speaks_and_a_vanishing_one_too(opener, tmp_path):
    baseline = {SYNC: True, WORKSPACES: False, zen.DEFAULT_WATCH_PATHS[2]: False}
    fake = opener(
        [
            json_reply(RELEASE),
            json_reply(_tree(SYNC, WORKSPACES)),
            json_reply(_commit("2026-08-20T17:16:13Z", "gh-14470: Add tab and folder sync")),
        ]
    )
    out = zen.run(zen.Config(state_file=_state(tmp_path, baseline)), opener=fake)
    assert WORKSPACES in out and "Nouveau dans l'arbre source" in out

    gone = opener([json_reply(RELEASE), json_reply(_tree("src/unrelated.mjs"))])
    out = zen.run(zen.Config(state_file=_state(tmp_path, baseline)), opener=gone)
    assert "Disparu de l'arbre source" in out and SYNC in out


def test_token_is_optional_and_becomes_a_bearer_header(opener, tmp_path):
    fake = opener([json_reply(RELEASE), json_reply(_tree()), json_reply([])])
    zen.run(zen.Config(state_file=str(tmp_path / "a.json"), token="t"), opener=fake)
    assert fake.requests[0].headers["Authorization"] == "Bearer t"

    anon = opener([json_reply(RELEASE), json_reply(_tree()), json_reply([])])
    zen.run(zen.Config(state_file=str(tmp_path / "b.json")), opener=anon)
    assert "Authorization" not in anon.requests[0].headers


def test_missing_tag_raises_and_a_commit_lookup_failure_degrades(opener, tmp_path):
    fake = opener([json_reply({"tag_name": ""})])
    with pytest.raises(RuntimeError, match="no tag_name"):
        zen.run(zen.Config(state_file=str(tmp_path / "s.json")), opener=fake)

    def boom(req, timeout=None):
        raise OSError("rate limited")

    assert zen.first_commit(zen.Config(), SYNC, opener=boom) is None


# ---------------------------------------------------------------------------
# cron_check
# ---------------------------------------------------------------------------
# The point of this one is that it stays QUIET when everything resolves and never
# raises — it runs in hermes' ExecStartPre, so a false alarm is noise every
# restart and an exception would keep the agent down.


def _home(tmp_path, jobs, seeded=()):
    (tmp_path / "cron").mkdir(parents=True, exist_ok=True)
    (tmp_path / "scripts").mkdir(parents=True, exist_ok=True)
    (tmp_path / "cron" / "jobs.json").write_text(json.dumps(jobs))
    for name in seeded:
        (tmp_path / "scripts" / name).write_text("#!/usr/bin/env bash\n")
    return chk.Config(hermes_home=str(tmp_path))


def test_silent_when_every_no_agent_binding_resolves(tmp_path):
    cfg = _home(
        tmp_path,
        [
            {"id": "a", "no_agent": True, "script": "zen-watch.sh"},
            {"id": "b", "no_agent": False, "script": None},  # LLM job: not our problem
            {"id": "c", "no_agent": True, "script": ""},  # no script yet: not a mismatch
        ],
        seeded=["zen-watch.sh"],
    )
    assert chk.run(cfg) == ""


def test_names_the_job_when_its_script_is_gone(tmp_path):
    cfg = _home(
        tmp_path,
        [{"id": "b201", "name": "Veille Zen", "no_agent": True, "script": "zen-watch.sh"}],
        seeded=[],
    )
    out = chk.run(cfg)
    assert "zen-watch.sh" in out and "b201" in out and "Veille Zen" in out


def test_a_directory_is_not_a_script_and_dict_shaped_jobs_are_read(tmp_path):
    (tmp_path / "scripts" / "zen-watch.sh").mkdir(parents=True)
    cfg = _home(tmp_path, {"jobs": [{"id": "a", "no_agent": True, "script": "zen-watch.sh"}]})
    assert "zen-watch.sh" in chk.run(cfg)


def test_unreadable_jobs_json_is_skipped_not_raised(tmp_path):
    cfg = chk.Config(hermes_home=str(tmp_path / "nope"))
    assert chk.run(cfg) == ""
    (tmp_path / "cron").mkdir(parents=True)
    (tmp_path / "cron" / "jobs.json").write_text("{ not json")
    assert chk.run(chk.Config(hermes_home=str(tmp_path))) == ""


def test_main_prints_the_nudge_and_always_exits_zero(tmp_path, capsys):
    _home(tmp_path, [{"id": "a", "no_agent": True, "script": "gone.sh"}])
    assert chk.main(env={"HERMES_HOME": str(tmp_path)}) == 0
    assert "gone.sh" in capsys.readouterr().out
