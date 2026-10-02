"""Tests for hermes-airbnb-pricing.

Delivery contract: the last stdout line `{"wakeAgent": false}` skips the model, so
"silent when nothing changed" is a correctness property.
"""

import json
from datetime import date

from conftest import FakeOpener, FakeResponse
from nicos_scripts.hermes import airbnb_pricing as ap

RULES = {
    "season_end": "2026-12-31",
    "cap_nights": 90,
    "min_stay": 2,
    "host_fee_pct": 15.5,
    "vat_pct": 20,
    "default_base_price": 139,
    "base_price": {"2026-10": 128, "2026-11": 139, "2026-12": 150},
    "weekend_pct": 10,
    "floor": {"cap_binding": 128, "cap_free": 105},
    "lead_time_ladder": [
        {"max_lead_days": 3, "discount_pct": 15},
        {"max_lead_days": 7, "discount_pct": 10},
        {"max_lead_days": 14, "discount_pct": 5},
    ],
    "orphan_premium_pct": 10,
    "urgent_lead_days": 7,
    "weekly_weekday": 0,
}
TODAY = date(2026, 10, 2)  # a Friday


def ev(start, end, summary=ap.RESERVED):
    return {"start": date.fromisoformat(start), "end": date.fromisoformat(end), "summary": summary}


def booking(start, end, guest="G"):
    return {**ev(start, end, f"Airbnb · {guest} — Zen"), "guest": guest}


def rules(**over):
    return {**RULES, **over}


# ── pricing ──────────────────────────────────────────────────────────────────


def test_host_net_is_the_fee_plus_vat_measured_on_marcello():
    # 479 € gross → −89.10 € fee on the real payout.
    assert round(479 - ap.host_net(RULES, 479), 2) == 89.09


def test_weekend_pct_applies_to_friday_and_saturday_nights_only():
    far = 60
    assert ap.nightly_price(RULES, date(2026, 11, 6), far, False) == 153  # Fri
    assert ap.nightly_price(RULES, date(2026, 11, 7), far, False) == 153  # Sat
    assert ap.nightly_price(RULES, date(2026, 11, 8), far, False) == 139  # Sun


def test_ladder_then_floor_and_the_floor_depends_on_the_cap():
    night = date(2026, 10, 5)
    assert ap.nightly_price(RULES, night, 20, False) == 128
    assert ap.nightly_price(RULES, night, 10, False) == 122  # −5 %
    assert ap.nightly_price(RULES, night, 2, False) == 109  # −15 %
    assert ap.nightly_price(RULES, night, 2, True) == 128  # scarce nights hold


def test_unknown_month_falls_back_to_the_default_base():
    assert ap.nightly_price(RULES, date(2027, 1, 4), 60, False) == 139


def test_price_runs_merge_only_consecutive_equal_prices():
    nights = [date(2026, 11, d) for d in (5, 6, 7, 8)]
    runs = ap.price_runs(RULES, nights, [139, 153, 153, 139])
    assert [(r["first_night"], r["last_night"], r["price"]) for r in runs] == [
        ("2026-11-05", "2026-11-05", 139),
        ("2026-11-06", "2026-11-07", 153),
        ("2026-11-08", "2026-11-08", 139),
    ]


# ── facts ────────────────────────────────────────────────────────────────────


def test_cap_counts_past_perso_nights_and_future_feed_nights_once():
    feed = [ev("2026-10-09", "2026-10-11")]
    perso = [booking("2026-09-08", "2026-09-12"), booking("2026-10-09", "2026-10-11")]
    facts = ap.build_facts(rules(season_end="2026-10-15"), feed, perso, TODAY)
    assert facts["cap"]["used"] == 6  # 4 past + 2 future, the overlap counted once


def test_cap_is_binding_only_when_open_nights_exceed_what_is_left():
    perso = [booking("2026-01-01", "2026-03-31")]  # 89 nights
    facts = ap.build_facts(rules(season_end="2026-10-10"), [], perso, TODAY)
    assert facts["cap"]["remaining"] == 1
    assert facts["cap"]["binding"] is True
    facts = ap.build_facts(rules(season_end="2026-10-02"), [], perso, TODAY)
    assert facts["cap"]["binding"] is False


def test_gaps_skip_booked_and_blocked_nights_and_flag_orphans():
    feed = [
        ev("2026-10-05", "2026-10-08", "Airbnb (Not available)"),
        ev("2026-10-09", "2026-10-11"),
        ev("2026-10-13", "2026-10-31"),
    ]
    facts = ap.build_facts(rules(season_end="2026-10-30"), feed, [], TODAY)
    got = [(g["check_in"], g["check_out"], g["bookable_at_min_stay"]) for g in facts["gaps"]]
    assert got == [
        ("2026-10-02", "2026-10-05", True),
        ("2026-10-08", "2026-10-09", False),
        ("2026-10-11", "2026-10-13", True),
    ]
    orphan = facts["gaps"][1]
    # 128 −10 % (J-6) = 115, then the orphan premium.
    assert orphan["prices"][0]["price"] == 127


def test_months_exclude_blocked_nights_from_sellable():
    feed = [ev("2026-12-21", "2027-01-01", "Airbnb (Not available)"), ev("2026-12-01", "2026-12-06")]
    facts = ap.build_facts(rules(), feed, [], date(2026, 12, 1))
    assert facts["months"]["2026-12"] == {"sellable": 20, "booked": 5, "occupancy_pct": 25}


def test_mismatch_reports_future_nights_on_one_side_only():
    feed = [ev("2026-10-20", "2026-10-22")]
    perso = [booking("2026-10-25", "2026-10-26"), booking("2026-09-01", "2026-09-03")]
    facts = ap.build_facts(rules(season_end="2026-10-30"), feed, perso, TODAY)
    assert facts["mismatch"] == {
        "in_airbnb_not_in_perso": ["2026-10-20", "2026-10-21"],
        "in_perso_not_in_airbnb": ["2026-10-25"],
    }


# ── triggers ─────────────────────────────────────────────────────────────────


def _facts(feed, today=TODAY, **over):
    return ap.build_facts(rules(**over), feed, [], today)


def test_first_run_does_not_report_every_booking_as_new():
    facts = _facts([ev("2026-10-09", "2026-10-31")], season_end="2026-10-30")
    reasons, state = ap.triggers(RULES, facts, {}, TODAY)
    assert not any(r.startswith("new_booking") for r in reasons)
    assert state["reserved"] == [["2026-10-09", "2026-10-31"]]


def test_new_and_cancelled_bookings_are_diffed_against_state():
    facts = _facts([ev("2026-10-20", "2026-10-31")], season_end="2026-10-30")
    prev = {"reserved": [["2026-10-09", "2026-10-11"], ["2026-09-01", "2026-09-03"]],
            "last_weekly": None}
    reasons, _ = ap.triggers(RULES, facts, prev, TODAY)
    assert "new_booking 2026-10-20→2026-10-31" in reasons
    assert "cancelled 2026-10-09→2026-10-11" in reasons
    assert not any("2026-09-01" in r for r in reasons)  # past stays just age out


def test_urgent_gap_fires_once_per_ladder_step():
    feed = [ev("2026-10-07", "2026-10-31")]  # gap Oct 2–6
    facts = _facts(feed, season_end="2026-10-30")
    reasons, state = ap.triggers(RULES, facts, {"reserved": [["2026-10-07", "2026-10-31"]]}, TODAY)
    assert reasons == ["urgent_gap 2026-10-02 (5n, J-0)"]
    again, _ = ap.triggers(RULES, facts, state, TODAY)
    assert again == []


def test_weekly_summary_fires_on_monday_once():
    monday = date(2026, 10, 5)
    feed = [ev("2026-10-05", "2026-10-31")]
    facts = _facts(feed, today=monday, season_end="2026-10-30")
    base = {"reserved": [["2026-10-05", "2026-10-31"]]}
    reasons, state = ap.triggers(RULES, facts, base, monday)
    assert reasons == ["weekly_summary"]
    assert ap.triggers(RULES, facts, state, monday)[0] == []


def test_season_over_is_reported_once():
    after = date(2027, 1, 2)
    facts = ap.build_facts(rules(), [], [], after)
    reasons, state = ap.triggers(RULES, facts, {"reserved": []}, after)
    assert reasons == ["season_over"]
    assert ap.triggers(RULES, facts, state, after)[0] == []


# ── I/O + main ───────────────────────────────────────────────────────────────

PROPFIND = (
    b'<d:multistatus xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/"><d:response>'
    b"<d:href>/nextcloud/remote.php/dav/calendars/nsimon/wwwairbnbcom/</d:href>"
    b"<d:propstat><d:prop><cs:source><d:href>https://www.airbnb.com/calendar/ical/1.ics?s=x"
    b"</d:href></cs:source></d:prop></d:propstat></d:response></d:multistatus>"
)
ICS = (
    b"BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART;VALUE=DATE:20261009\r\n"
    b"DTEND;VALUE=DATE:20261011\r\nSUMMARY:Reserved\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
)
REPORT = (
    '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:response>'
    "<d:propstat><d:prop><c:calendar-data>BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:a\n"
    "DTSTART;VALUE=DATE:20261009\nDTEND;VALUE=DATE:20261011\n"
    "SUMMARY:Airbnb · Salomé — Zen\n"
    "END:VEVENT\nEND:VCALENDAR</c:calendar-data></d:prop></d:propstat></d:response>"
    "</d:multistatus>"
).encode()


def test_run_reads_the_subscription_source_then_the_feed_then_perso():
    fake = FakeOpener([lambda: FakeResponse(PROPFIND), lambda: FakeResponse(ICS),
                       lambda: FakeResponse(REPORT)])
    cfg = ap.Config(password="p", today=TODAY)
    facts, _, _ = ap.run(cfg, rules(season_end="2026-10-15"), {}, opener=fake)
    assert fake.requests[0].get_method() == "PROPFIND"
    assert fake.requests[1].full_url == "https://www.airbnb.com/calendar/ical/1.ics?s=x"
    assert fake.requests[2].full_url.endswith("/personal/")
    assert facts["upcoming_guests"][0]["guest"] == "Salomé"
    assert facts["mismatch"]["in_airbnb_not_in_perso"] == []


def test_subscription_source_rejects_a_plain_calendar(opener):
    plain = b'<d:multistatus xmlns:d="DAV:"><d:response><d:href>/x/</d:href></d:response></d:multistatus>'
    fake = opener([lambda: FakeResponse(plain)])
    try:
        ap.subscription_source(ap.Config(password="p"), opener=fake)
    except ValueError as e:
        assert "not a subscription" in str(e)
    else:
        raise AssertionError("expected ValueError")


def test_main_is_silent_and_writes_state_when_nothing_triggers(tmp_path, capsys, monkeypatch):
    rules_file = tmp_path / "rules.json"
    rules_file.write_text(json.dumps(rules(season_end="2026-10-30")))
    state_file = tmp_path / "s" / "state.json"
    monkeypatch.setattr(ap, "run", lambda cfg, r, s: ({"gaps": [], "cap": {}}, [], {"x": 1}))
    env = {"CALDAV_PASSWORD": "p", "AIRBNB_RULES": str(rules_file),
           "AIRBNB_STATE": str(state_file)}
    assert ap.main([], env) == 0
    assert capsys.readouterr().out.strip().splitlines()[-1] == ap.SILENT
    assert json.loads(state_file.read_text()) == {"x": 1}


def test_main_no_state_never_writes(tmp_path, capsys, monkeypatch):
    rules_file = tmp_path / "rules.json"
    rules_file.write_text("{}")
    state_file = tmp_path / "state.json"
    monkeypatch.setattr(ap, "run", lambda cfg, r, s: ({"gaps": [], "cap": {}}, ["x"], {"x": 1}))
    env = {"CALDAV_PASSWORD": "p", "AIRBNB_RULES": str(rules_file),
           "AIRBNB_STATE": str(state_file)}
    assert ap.main(["--no-state"], env) == 0
    assert not state_file.exists()
    assert json.loads(capsys.readouterr().out)["triggers"] == ["x"]


def test_main_fails_loudly_without_a_password(capsys):
    assert ap.main([], {"CALDAV_PASSWORD_FILE": "/nonexistent"}) == 1
    assert capsys.readouterr().out == ""
