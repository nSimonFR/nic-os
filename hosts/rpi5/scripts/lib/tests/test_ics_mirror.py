"""ics-mirror: windowing, master/override survival, freshness and the safe default."""

import datetime
import gzip
import io
import json

import pytest

from nicos_scripts.connectors import ics_mirror as m

TODAY = datetime.date(2026, 9, 15)
LO = TODAY - datetime.timedelta(days=92)  # 2026-06-15
HI = TODAY + datetime.timedelta(days=365)  # 2027-09-15


def cal(*components, header=None):
    head = header or [
        "PRODID:-//Google Inc//Google Calendar 70.9054//EN",
        "VERSION:2.0",
        "X-WR-CALNAME:TRUSK",
    ]
    return "\r\n".join(["BEGIN:VCALENDAR", *head, *components, "END:VCALENDAR"]) + "\r\n"


def vevent(uid, dtstart, dtend=None, rrule=None, recurrence_id=None, extra=()):
    lines = [f"BEGIN:VEVENT", f"UID:{uid}", f"DTSTART:{dtstart}"]
    if dtend:
        lines.append(f"DTEND:{dtend}")
    if rrule:
        lines.append(f"RRULE:{rrule}")
    if recurrence_id:
        lines.append(f"RECURRENCE-ID:{recurrence_id}")
    lines.extend(extra)
    lines.append("END:VEVENT")
    return "\r\n".join(lines)


def kept_uids(ics):
    _, comps = m.parse(ics)
    return [
        m.prop_value(c["logical"], "UID") for c in comps if c["name"] == "VEVENT"
    ]


# ── windowing ──────────────────────────────────────────────────────────────────


def test_drops_events_before_the_window():
    src = cal(vevent("old", "20190401T090000"), vevent("now", "20260901T090000"))
    out, stats = m.window_ics(src, LO, HI)
    assert kept_uids(out) == ["now"]
    assert stats == {"events_in": 2, "events_out": 1}


def test_drops_events_after_the_window():
    src = cal(vevent("far", "20300401T090000"), vevent("now", "20260901T090000"))
    out, _ = m.window_ics(src, LO, HI)
    assert kept_uids(out) == ["now"]


def test_keeps_an_event_straddling_the_window_start():
    """Ends inside the window although it started well before it."""
    src = cal(vevent("straddle", "20260101T090000", dtend="20260701T090000"))
    out, _ = m.window_ics(src, LO, HI)
    assert kept_uids(out) == ["straddle"]


@pytest.mark.parametrize("boundary", ["20260615", "20270915"])
def test_window_bounds_are_inclusive(boundary):
    src = cal(vevent("edge", f"{boundary}T090000"))
    out, _ = m.window_ics(src, LO, HI)
    assert kept_uids(out) == ["edge"]


def test_all_day_value_date_form_is_parsed():
    src = cal(
        "\r\n".join(
            [
                "BEGIN:VEVENT",
                "UID:allday",
                "DTSTART;VALUE=DATE:20260901",
                "END:VEVENT",
            ]
        )
    )
    out, _ = m.window_ics(src, LO, HI)
    assert kept_uids(out) == ["allday"]


def test_tzid_form_is_parsed():
    src = cal(
        "\r\n".join(
            [
                "BEGIN:VEVENT",
                "UID:tz",
                "DTSTART;TZID=Europe/Paris:20190901T090000",
                "END:VEVENT",
            ]
        )
    )
    out, _ = m.window_ics(src, LO, HI)
    assert kept_uids(out) == []


# ── recurrence ─────────────────────────────────────────────────────────────────


def test_unbounded_rrule_survives_however_old_it_is():
    """The 14 unbounded rules in the real feed start in 2019 but still occur today."""
    src = cal(vevent("weekly", "20190401T090000", rrule="FREQ=WEEKLY"))
    out, _ = m.window_ics(src, LO, HI)
    assert kept_uids(out) == ["weekly"]


def test_rrule_with_until_before_the_window_is_dropped():
    src = cal(vevent("ended", "20190401T090000", rrule="FREQ=WEEKLY;UNTIL=20200101T000000Z"))
    out, _ = m.window_ics(src, LO, HI)
    assert kept_uids(out) == []


def test_rrule_with_until_inside_the_window_is_kept():
    src = cal(vevent("live", "20190401T090000", rrule="FREQ=WEEKLY;UNTIL=20261201T000000Z"))
    out, _ = m.window_ics(src, LO, HI)
    assert kept_uids(out) == ["live"]


def test_count_rrule_is_kept_conservatively():
    """COUNT cannot be resolved without expanding; over-keeping beats losing a series."""
    src = cal(vevent("counted", "20190401T090000", rrule="FREQ=WEEKLY;COUNT=500"))
    out, _ = m.window_ics(src, LO, HI)
    assert kept_uids(out) == ["counted"]


def test_master_is_kept_when_an_override_survives():
    """The regression that matters: 44% of the real feed is overrides."""
    src = cal(
        vevent("series", "20190401T090000", rrule="FREQ=WEEKLY;UNTIL=20270101T000000Z"),
        vevent("series", "20260901T100000", recurrence_id="20260901T090000"),
    )
    out, _ = m.window_ics(src, LO, HI)
    assert kept_uids(out) == ["series", "series"]


def test_out_of_window_override_is_dropped_but_master_stays():
    src = cal(
        vevent("series", "20190401T090000", rrule="FREQ=WEEKLY"),
        vevent("series", "20190501T100000", recurrence_id="20190501T090000"),
    )
    out, _ = m.window_ics(src, LO, HI)
    # Only the master survives — the 2019 exception is outside the window anyway.
    assert kept_uids(out) == ["series"]


def test_override_without_a_master_passes_through():
    """Google exports 6 such UIDs; we cannot invent a master it never sent."""
    src = cal(vevent("lonely", "20260901T100000", recurrence_id="20260901T090000"))
    out, _ = m.window_ics(src, LO, HI)
    assert kept_uids(out) == ["lonely"]


# ── structure preservation ─────────────────────────────────────────────────────


def test_vtimezone_is_always_kept():
    src = cal(
        "\r\n".join(["BEGIN:VTIMEZONE", "TZID:Europe/Paris", "END:VTIMEZONE"]),
        vevent("old", "20190401T090000"),
    )
    out, _ = m.window_ics(src, LO, HI)
    _, comps = m.parse(out)
    assert [c["name"] for c in comps] == ["VTIMEZONE"]


def test_folded_lines_survive_byte_for_byte():
    """Kept components are re-emitted as their ORIGINAL physical lines."""
    folded = "\r\n".join(
        [
            "BEGIN:VEVENT",
            "UID:folded",
            "DTSTART:20260901T090000",
            "SUMMARY:a very long summary that Google folded across",
            "  two physical lines",
            "END:VEVENT",
        ]
    )
    out, _ = m.window_ics(cal(folded), LO, HI)
    assert "SUMMARY:a very long summary that Google folded across\r\n  two physical lines" in out


def test_nested_valarm_does_not_confuse_component_boundaries():
    src = cal(
        "\r\n".join(
            [
                "BEGIN:VEVENT",
                "UID:alarmed",
                "DTSTART:20260901T090000",
                "BEGIN:VALARM",
                "TRIGGER:-PT10M",
                "ACTION:DISPLAY",
                "END:VALARM",
                "END:VEVENT",
            ]
        )
    )
    out, _ = m.window_ics(src, LO, HI)
    _, comps = m.parse(out)
    assert [c["name"] for c in comps] == ["VEVENT"]
    assert "BEGIN:VALARM" in out


def test_header_is_carried_over_and_unknown_props_dropped():
    src = cal(vevent("now", "20260901T090000"), header=["PRODID:-//x//EN", "VERSION:2.0", "X-WR-CALNAME:TRUSK", "X-SECRET-TOKEN:leaky"])
    out, _ = m.window_ics(src, LO, HI)
    assert "X-WR-CALNAME:TRUSK" in out
    assert "X-SECRET-TOKEN" not in out


def test_output_is_crlf_terminated():
    out, _ = m.window_ics(cal(vevent("now", "20260901T090000")), LO, HI)
    assert out.endswith("END:VCALENDAR\r\n")
    assert "\n" not in out.replace("\r\n", "")


# ── config ─────────────────────────────────────────────────────────────────────


def test_empty_env_cannot_write():
    """CLAUDE.md's rule: a Config built with no env must not be able to write."""
    cfg = m.Config.from_env({})
    assert cfg.out_dir == ""


def test_window_uses_configured_spans():
    cfg = m.Config.from_env({"ICS_MIRROR_BACK_DAYS": "10", "ICS_MIRROR_FWD_DAYS": "20"})
    lo, hi = cfg.window(TODAY)
    assert (lo, hi) == (datetime.date(2026, 9, 5), datetime.date(2026, 10, 5))


def test_garbage_day_counts_fall_back_to_defaults():
    cfg = m.Config.from_env({"ICS_MIRROR_BACK_DAYS": "not-a-number"})
    assert cfg.back_days == m.DEFAULT_BACK_DAYS


@pytest.mark.parametrize(
    "payload",
    [
        {},
        [],
        {"BadSlug": "https://x/y.ics"},
        {"ok": "http://insecure/y.ics"},
    ],
)
def test_bad_feeds_files_are_rejected(tmp_path, payload):
    p = tmp_path / "feeds.json"
    p.write_text(json.dumps(payload))
    with pytest.raises(ValueError):
        m.load_feeds(str(p))


def test_good_feeds_file_parses(tmp_path):
    p = tmp_path / "feeds.json"
    p.write_text(json.dumps({"trusk": "https://example/a.ics", "google-perso": "https://example/b.ics"}))
    assert m.load_feeds(str(p)) == {
        "trusk": "https://example/a.ics",
        "google-perso": "https://example/b.ics",
    }


# ── fetch ──────────────────────────────────────────────────────────────────────


class Resp(io.BytesIO):
    def __init__(self, body, headers=None):
        super().__init__(body)
        self.headers = headers or {}

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def test_fetch_requests_gzip_and_decompresses():
    body = cal(vevent("now", "20260901T090000"))
    calls = []

    def opener(req, timeout=None):
        calls.append(req)
        return Resp(gzip.compress(body.encode()), {"Content-Encoding": "gzip"})

    got = m.fetch("https://example/a.ics", 5, opener=opener)
    assert got == body
    assert calls[0].get_header("Accept-encoding") == "gzip"


def test_fetch_handles_an_uncompressed_reply():
    body = cal(vevent("now", "20260901T090000"))
    got = m.fetch("https://e/a.ics", 5, opener=lambda r, timeout=None: Resp(body.encode()))
    assert got == body


# ── run() ──────────────────────────────────────────────────────────────────────


def feeds_file(tmp_path, **feeds):
    p = tmp_path / "feeds.json"
    p.write_text(json.dumps(feeds))
    return str(p)


def cfg_for(tmp_path, **over):
    base = dict(
        out_dir=str(tmp_path / "out"),
        feeds_file=feeds_file(tmp_path, trusk="https://example/a.ics"),
        state_dir=str(tmp_path / "state"),
    )
    base.update(over)
    return m.Config(**base)


def serve(body):
    return lambda req, timeout=None: Resp(body.encode())


def test_run_writes_a_windowed_file(tmp_path):
    src = cal(vevent("old", "20190401T090000"), vevent("now", "20260901T090000"))
    cfg = cfg_for(tmp_path)
    assert m.run(cfg, opener=serve(src), today=TODAY) == 0
    written = (tmp_path / "out" / "trusk.ics").read_text()
    assert kept_uids(written) == ["now"]


def test_run_is_missing_feeds_file_fatal(tmp_path):
    cfg = m.Config(out_dir=str(tmp_path), feeds_file="")
    assert m.run(cfg, today=TODAY) == 1


def test_dry_run_writes_nothing(tmp_path):
    cfg = cfg_for(tmp_path)
    src = cal(vevent("now", "20260901T090000"))
    assert m.run(cfg, dry_run=True, opener=serve(src), today=TODAY) == 0
    assert not (tmp_path / "out" / "trusk.ics").exists()
    assert not (tmp_path / "state" / "state.json").exists()


def test_unchanged_digest_and_window_skips_the_rewrite(tmp_path):
    src = cal(vevent("now", "20260901T090000"))
    cfg = cfg_for(tmp_path)
    m.run(cfg, opener=serve(src), today=TODAY)
    target = tmp_path / "out" / "trusk.ics"
    target.write_text("SENTINEL")
    m.run(cfg, opener=serve(src), today=TODAY)
    assert target.read_text() == "SENTINEL"


def test_a_dtstamp_only_change_is_not_a_change(tmp_path):
    """Google regenerates DTSTAMP on EVERY export; hashing it would defeat the skip."""
    cfg = cfg_for(tmp_path)
    first = cal(vevent("now", "20260901T090000", extra=["DTSTAMP:20260915T100000Z"]))
    m.run(cfg, opener=serve(first), today=TODAY, now=clock(T1))
    target = tmp_path / "out" / "trusk.ics"
    target.write_text("SENTINEL")
    second = cal(vevent("now", "20260901T090000", extra=["DTSTAMP:20260915T110000Z"]))
    m.run(cfg, opener=serve(second), today=TODAY, now=clock(T2))
    assert target.read_text() == "SENTINEL"
    assert state_of(tmp_path)["last_changed_at"] == T1.isoformat(timespec="seconds")


def digest_of(ics_text):
    header, components = m.parse(ics_text)
    return m.canonical_digest(header, components, range(len(components)))


def test_a_parameterised_volatile_property_is_still_ignored():
    a = cal(vevent("now", "20260901T090000", extra=["DTSTAMP:20260915T100000Z"]))
    b = cal(vevent("now", "20260901T090000", extra=["DTSTAMP;X=1:20260915T110000Z"]))
    assert digest_of(a) == digest_of(b)


def test_sequence_changes_are_not_ignored():
    """Only export-time noise is excluded — a real revision must still register."""
    a = cal(vevent("now", "20260901T090000", extra=["SEQUENCE:1"]))
    b = cal(vevent("now", "20260901T090000", extra=["SEQUENCE:2"]))
    assert digest_of(a) != digest_of(b)


def test_digest_ignores_component_order():
    """Google reshuffles the feed on every fetch; order is not content."""
    one = vevent("a", "20260901T090000")
    two = vevent("b", "20260902T090000")
    assert digest_of(cal(one, two)) == digest_of(cal(two, one))


def test_digest_still_notices_a_removed_event():
    """Order-independence must not degrade into set-equality blindness."""
    one = vevent("a", "20260901T090000")
    two = vevent("b", "20260902T090000")
    assert digest_of(cal(one, two)) != digest_of(cal(one))


def test_digest_notices_content_moving_between_components():
    """The \\x00 block separator is what stops two blocks merging into one string."""
    a = cal(vevent("a", "20260901T090000", extra=["SUMMARY:xy"]))
    b = cal(vevent("a", "20260901T090000", extra=["SUMMARY:x", "LOCATION:y"]))
    assert digest_of(a) != digest_of(b)


def test_reordered_upstream_is_not_a_rewrite(tmp_path):
    """The end-to-end form of the same fact."""
    one = vevent("a", "20260901T090000")
    two = vevent("b", "20260902T090000")
    cfg = cfg_for(tmp_path)
    m.run(cfg, opener=serve(cal(one, two)), today=TODAY, now=clock(T1))
    target = tmp_path / "out" / "trusk.ics"
    target.write_text("SENTINEL")
    m.run(cfg, opener=serve(cal(two, one)), today=TODAY, now=clock(T2))
    assert target.read_text() == "SENTINEL"
    assert state_of(tmp_path)["last_changed_at"] == T1.isoformat(timespec="seconds")


def test_output_order_is_deterministic_regardless_of_input_order():
    one = vevent("b", "20260902T090000")
    two = vevent("a", "20260901T090000")
    first, _ = m.window_ics(cal(one, two), LO, HI)
    second, _ = m.window_ics(cal(two, one), LO, HI)
    assert first == second
    assert kept_uids(first) == ["a", "b"]


def test_a_master_is_rendered_before_its_own_overrides():
    override = vevent("s", "20260902T100000", recurrence_id="20260902T090000")
    master = vevent("s", "20260901T090000", rrule="FREQ=WEEKLY")
    out, _ = m.window_ics(cal(override, master), LO, HI)
    _, comps = m.parse(out)
    assert [m.prop_value(c["logical"], "RECURRENCE-ID") for c in comps] == [
        None,
        "20260902T090000",
    ]


def test_a_window_slide_that_changes_nothing_skips_the_write(tmp_path):
    """The digest is over the OUTPUT, so a no-op slide is correctly a no-op."""
    src = cal(vevent("now", "20260901T090000"))
    cfg = cfg_for(tmp_path)
    m.run(cfg, opener=serve(src), today=TODAY)
    target = tmp_path / "out" / "trusk.ics"
    target.write_text("SENTINEL")
    m.run(cfg, opener=serve(src), today=TODAY + datetime.timedelta(days=1))
    assert target.read_text() == "SENTINEL"


def test_a_window_slide_that_drops_an_event_does_rewrite(tmp_path):
    src = cal(vevent("edge", "20260615T090000"), vevent("now", "20260901T090000"))
    cfg = cfg_for(tmp_path)
    m.run(cfg, opener=serve(src), today=TODAY)
    assert kept_uids((tmp_path / "out" / "trusk.ics").read_text()) == ["edge", "now"]
    # One day on, `edge` falls out of the -92d boundary.
    m.run(cfg, opener=serve(src), today=TODAY + datetime.timedelta(days=1))
    assert kept_uids((tmp_path / "out" / "trusk.ics").read_text()) == ["now"]


def test_a_missing_output_file_is_rewritten_even_when_unchanged(tmp_path):
    src = cal(vevent("now", "20260901T090000"))
    cfg = cfg_for(tmp_path)
    m.run(cfg, opener=serve(src), today=TODAY)
    (tmp_path / "out" / "trusk.ics").unlink()
    m.run(cfg, opener=serve(src), today=TODAY)
    assert kept_uids((tmp_path / "out" / "trusk.ics").read_text()) == ["now"]


def clock(*stamps):
    """A `now` seam returning each stamp in turn — the wall clock is too coarse.

    Both runs in these tests land inside the same second, so a real
    `isoformat(timespec="seconds")` cannot distinguish "re-stamped" from "held".
    """
    it = iter(stamps)
    last = [None]

    def now():
        try:
            last[0] = next(it)
        except StopIteration:
            pass
        return last[0]

    return now


T1 = datetime.datetime(2026, 9, 15, 10, 0, 0)
T2 = datetime.datetime(2026, 9, 15, 10, 30, 0)


def state_of(tmp_path):
    return json.loads((tmp_path / "state" / "state.json").read_text())["trusk"]


def test_changed_upstream_rewrites_and_stamps_last_changed(tmp_path):
    cfg = cfg_for(tmp_path)
    m.run(cfg, opener=serve(cal(vevent("a", "20260901T090000"))), today=TODAY, now=clock(T1))
    first = state_of(tmp_path)
    m.run(cfg, opener=serve(cal(vevent("b", "20260902T090000"))), today=TODAY, now=clock(T2))
    second = state_of(tmp_path)
    assert first["last_changed_at"] == T1.isoformat(timespec="seconds")
    assert second["last_changed_at"] == T2.isoformat(timespec="seconds")
    assert kept_uids((tmp_path / "out" / "trusk.ics").read_text()) == ["b"]


def test_unchanged_upstream_holds_last_changed_steady(tmp_path):
    """Otherwise the stamp measures poll cadence rather than publishing lag."""
    src = cal(vevent("a", "20260901T090000"))
    cfg = cfg_for(tmp_path)
    m.run(cfg, opener=serve(src), today=TODAY, now=clock(T1))
    m.run(cfg, opener=serve(src), today=TODAY, now=clock(T2))
    assert state_of(tmp_path)["last_changed_at"] == T1.isoformat(timespec="seconds")


def test_a_window_slide_alone_does_not_move_last_changed(tmp_path):
    """last_changed_at tracks GOOGLE, not our own boundary crossings."""
    cfg = cfg_for(tmp_path)
    src = cal(vevent("a", "20260615T090000"), vevent("b", "20260901T090000"))
    m.run(cfg, opener=serve(src), today=TODAY, now=clock(T1))
    # One day on, `a` falls out of the window: the served file changes, upstream did not.
    m.run(cfg, opener=serve(src), today=TODAY + datetime.timedelta(days=1), now=clock(T2))
    second = state_of(tmp_path)
    assert kept_uids((tmp_path / "out" / "trusk.ics").read_text()) == ["b"]
    assert second["written_at"] == T2.isoformat(timespec="seconds")
    assert second["last_changed_at"] == T1.isoformat(timespec="seconds")


def test_an_upstream_change_outside_the_window_still_moves_last_changed(tmp_path):
    """The served file is rightly untouched, but Google DID publish."""
    cfg = cfg_for(tmp_path)
    m.run(
        cfg,
        opener=serve(cal(vevent("keep", "20260901T090000"), vevent("old", "20190101T090000"))),
        today=TODAY,
        now=clock(T1),
    )
    target = tmp_path / "out" / "trusk.ics"
    target.write_text("SENTINEL")
    m.run(
        cfg,
        opener=serve(cal(vevent("keep", "20260901T090000"), vevent("old", "20190202T090000"))),
        today=TODAY,
        now=clock(T2),
    )
    second = state_of(tmp_path)
    assert target.read_text() == "SENTINEL"  # nothing in-window changed
    assert second["written_at"] == T1.isoformat(timespec="seconds")
    assert second["last_changed_at"] == T2.isoformat(timespec="seconds")


def test_one_failing_feed_does_not_stop_the_others(tmp_path):
    src = cal(vevent("now", "20260901T090000"))

    def opener(req, timeout=None):
        if "bad" in req.full_url:
            raise OSError("upstream down")
        return Resp(src.encode())

    cfg = m.Config(
        out_dir=str(tmp_path / "out"),
        feeds_file=feeds_file(
            tmp_path, trusk="https://example/a.ics", bad="https://example/bad.ics"
        ),
        state_dir=str(tmp_path / "state"),
    )
    assert m.run(cfg, opener=opener, today=TODAY) == 0
    assert (tmp_path / "out" / "trusk.ics").exists()
    assert not (tmp_path / "out" / "bad.ics").exists()


def test_every_feed_failing_is_an_error(tmp_path):
    def opener(req, timeout=None):
        raise OSError("upstream down")

    assert m.run(cfg_for(tmp_path), opener=opener, today=TODAY) == 1


def test_a_stale_file_survives_an_upstream_failure(tmp_path):
    """A stale calendar beats an empty one when Google is down."""
    cfg = cfg_for(tmp_path)
    m.run(cfg, opener=serve(cal(vevent("a", "20260901T090000"))), today=TODAY)

    def boom(req, timeout=None):
        raise OSError("upstream down")

    m.run(cfg, opener=boom, today=TODAY)
    assert kept_uids((tmp_path / "out" / "trusk.ics").read_text()) == ["a"]


def test_write_is_atomic_leaving_no_tmp_behind(tmp_path):
    cfg = cfg_for(tmp_path)
    m.run(cfg, opener=serve(cal(vevent("a", "20260901T090000"))), today=TODAY)
    assert list((tmp_path / "out").iterdir()) == [tmp_path / "out" / "trusk.ics"]
