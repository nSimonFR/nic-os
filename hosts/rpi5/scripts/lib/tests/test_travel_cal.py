"""travel-cal-sync: the parts that decide what lands in your calendar.

Weighted towards the logic that was only observable by reading the resulting
calendar: the stable UID that collapses confirmation + reminder + itinerary mail
into one event, the year-rolling fix for date-without-a-year emails, the
DTEND > DTSTART guarantee sabre-dav requires, and the transient-vs-permanent
failure split that decides whether a message is retried.
"""

import email
from datetime import date, datetime, timezone

import pytest

from nicos_scripts.connectors import travel_cal as tc

NOW = datetime(2026, 8, 6, 12, 0, tzinfo=timezone.utc)


def cfg_for(tmp_path=None, **kw):
    return tc.Config(state_dir=str(tmp_path) if tmp_path else "/tmp", **kw)


# ── Config ────────────────────────────────────────────────────────────────────


def test_the_nextcloud_web_base_is_derived_from_the_caldav_url():
    cfg = tc.Config.from_env(
        {"NEXTCLOUD_CALDAV_URL": "https://h/nextcloud/remote.php/dav/calendars/nsimon"})
    assert cfg.caldav_home == "https://h/nextcloud/remote.php/dav/calendars/nsimon/"
    assert cfg.nc_web == "https://h/nextcloud"


def test_the_gate_url_loses_its_trailing_slash():
    assert tc.Config.from_env({"TINY_LLM_GATE_URL": "http://x:4001/"}).gate == "http://x:4001"


# ── candidate screening ───────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("frm", "subject", "expected"),
    [
        ("noreply@airbnb.com", "Anything at all", True),        # sender domain
        ("someone@example.com", "Your booking is confirmed", True),  # subject net
        ("someone@example.com", "Réservation confirmée", True),
        ("someone@example.com", "Newsletter", False),
        ("someone@example.com", "", False),
    ],
)
def test_candidate_screening(frm, subject, expected):
    assert tc.is_candidate(frm, subject) is expected


@pytest.mark.parametrize("subject", [
    "Inquiry about your place",
    "Request to book: Zen Flat",
    "Pending: Reservation Request",
    "Réservation en attente",
    "Demande de réservation",
    "Saved search: Lisbon",
    "Price alert for CDG→LIS",
])
def test_queries_are_dropped_deterministically(subject):
    # Never an event, whatever the model says — an inquiry is not a booking.
    assert tc.NEGATIVE_SUBJECT_RE.search(subject)


@pytest.mark.parametrize("subject", [
    "Reservation confirmed",
    "Your trip to Lisbon",
    "Booking confirmation AF1234",
])
def test_confirmations_are_not_dropped(subject):
    assert not tc.NEGATIVE_SUBJECT_RE.search(subject)


def test_encoded_subjects_are_decoded_before_matching():
    encoded = "=?utf-8?B?UsOpc2VydmF0aW9uIGNvbmZpcm3DqWU=?="
    assert tc.decode_header(encoded) == "Réservation confirmée"
    assert tc.is_candidate("x@y.com", tc.decode_header(encoded)) is True


def test_a_malformed_header_falls_back_to_the_raw_string():
    assert tc.decode_header("") == ""
    assert tc.decode_header("plain subject") == "plain subject"


@pytest.mark.parametrize(
    ("frm", "platform"),
    [("noreply@airbnb.com", "Airbnb"), ("x@sncf-connect.com", "SNCF Connect"),
     ("x@oui.sncf", "SNCF"), ("x@ba.com", "British Airways"), ("x@unknown.com", "")],
)
def test_the_platform_label_comes_from_the_sender(frm, platform):
    assert tc.source_platform(frm) == platform


# ── model output parsing ──────────────────────────────────────────────────────


def test_a_fenced_json_reply_is_parsed():
    assert tc._parse_json('```json\n{"is_booking": true}\n```') == {"is_booking": True}


def test_json_embedded_in_prose_is_recovered():
    assert tc._parse_json('Sure! {"is_booking": false} hope that helps') == {
        "is_booking": False}
    assert tc._parse_json('here you go: [{"a": 1}]') == [{"a": 1}]


def test_unparseable_output_returns_none_and_never_raises():
    # A raise here would reprocess the email on every scan forever (temperature=0
    # means the model returns the same bad output every time).
    for junk in ("", "I cannot help with that", "{not json", "```\n```"):
        assert tc._parse_json(junk) is None


@pytest.mark.parametrize(
    ("data", "expected"),
    [
        ({"is_booking": True}, [{"is_booking": True}]),
        ([{"a": 1}, "junk", {"b": 2}], [{"a": 1}, {"b": 2}]),
        ({"bookings": [{"a": 1}]}, [{"a": 1}]),          # a round-trip, wrapped
        ({"results": [{"a": 1}]}, [{"a": 1}]),
        (None, []),
        ("nonsense", []),
    ],
)
def test_bookings_are_normalised_to_a_list_of_dicts(data, expected):
    assert tc.normalise_bookings(data) == expected


class Boom:
    def __init__(self, exc):
        self.exc = exc

    def __call__(self, req, timeout=None):
        raise self.exc


@pytest.mark.parametrize("code", [502, 503, 504])
def test_a_gate_5xx_is_reported_as_upstream_down(code):
    # beast asleep → the daemon must back off, not skip the message.
    import urllib.error

    err = urllib.error.HTTPError("http://gate", code, "down", {}, None)
    with pytest.raises(tc.UpstreamDown):
        tc.extract_booking(tc.Config(), "text", opener=Boom(err))


def test_a_gate_4xx_is_not_swallowed():
    import urllib.error

    err = urllib.error.HTTPError("http://gate", 401, "nope", {}, None)
    with pytest.raises(urllib.error.HTTPError):
        tc.extract_booking(tc.Config(), "text", opener=Boom(err))


def test_an_unreachable_gate_and_a_timeout_are_both_upstream_down():
    import urllib.error

    for exc in (urllib.error.URLError("refused"), TimeoutError("slow")):
        with pytest.raises(tc.UpstreamDown):
            tc.extract_booking(tc.Config(), "text", opener=Boom(exc))


# ── the year-rolling fix ──────────────────────────────────────────────────────


def test_a_dropped_year_is_rolled_forward_to_the_next_occurrence():
    # "lundi 3 août" with no year → the model guesses last year → the event would
    # be filtered out as a past trip.
    b = {"start": "2025-08-10", "end": "2025-08-17", "all_day": True}
    tc.roll_year_forward(b, date(2026, 7, 1))
    assert (b["start"], b["end"]) == ("2026-08-10", "2026-08-17")


def test_a_same_year_past_date_is_left_alone():
    # It may be a genuinely past trip; the past-filter should drop it, not this.
    b = {"start": "2026-01-10", "all_day": True}
    tc.roll_year_forward(b, date(2026, 7, 1))
    assert b["start"] == "2026-01-10"


def test_a_future_date_is_left_alone():
    b = {"start": "2027-01-10", "all_day": True}
    tc.roll_year_forward(b, date(2026, 7, 1))
    assert b["start"] == "2027-01-10"


def test_february_29th_rolls_to_the_28th_instead_of_crashing():
    b = {"start": "2024-02-29", "all_day": True}
    tc.roll_year_forward(b, date(2026, 7, 1))
    assert b["start"] == "2026-02-28"


def test_timed_values_keep_their_time_when_rolled():
    b = {"start": "2025-08-10T07:30", "all_day": False}
    tc.roll_year_forward(b, date(2026, 7, 1))
    assert b["start"] == "2026-08-10T07:30"


def test_an_unparseable_date_is_left_untouched():
    b = {"start": "sometime in August", "all_day": True}
    tc.roll_year_forward(b, date(2026, 7, 1))
    assert b["start"] == "sometime in August"


# ── the stable UID ────────────────────────────────────────────────────────────


def test_the_confirmation_and_the_reminder_of_one_stay_share_a_uid():
    # This is what makes the CalDAV PUT idempotent: three emails about one trip
    # must not become three events. Confirmation codes are missing from some of
    # them, so they cannot be the identity.
    confirmation = {"type": "stay", "start": "2026-09-01", "end": "2026-09-08",
                    "confirmation_code": "HMABC123"}
    reminder = {"type": "stay", "start": "2026-09-01T00:00", "end": "2026-09-08",
                "confirmation_code": ""}
    assert tc.booking_uid(confirmation) == tc.booking_uid(reminder)


def test_two_legs_of_one_journey_get_different_uids():
    # One day can hold A→B then B→C; dates alone are not unique for transit.
    out = {"type": "train", "start": "2026-09-01T08:00", "end": "2026-09-01T11:00"}
    back = {"type": "train", "start": "2026-09-01T18:00", "end": "2026-09-01T21:00"}
    assert tc.booking_uid(out) != tc.booking_uid(back)


def test_the_uid_is_stable_and_well_formed():
    b = {"type": "flight", "start": "2026-09-01T08:00", "end": "2026-09-01T11:00"}
    uid = tc.booking_uid(b)
    assert uid == tc.booking_uid(dict(b))
    assert uid.startswith("travelcal-flight-") and uid.endswith("@nic-os")


# ── the iCalendar body ────────────────────────────────────────────────────────


def ics_lines(b, uid="uid@nic-os"):
    return tc.build_ics(b, uid, now=NOW).split("\r\n")


def test_a_stay_becomes_an_all_day_event():
    lines = ics_lines({"type": "stay", "start": "2026-09-01", "end": "2026-09-08",
                       "all_day": True, "title": "Airbnb — Lisbon"})
    assert "DTSTART;VALUE=DATE:20260901" in lines
    assert "DTEND;VALUE=DATE:20260908" in lines


def test_a_stay_with_both_times_becomes_a_timed_event():
    lines = ics_lines({"type": "stay", "start": "2026-09-01", "end": "2026-09-08",
                       "all_day": True, "checkin_time": "16:00",
                       "checkout_time": "10:30", "title": "Hotel"})
    assert "DTSTART:20260901T160000" in lines
    assert "DTEND:20260908T103000" in lines


def test_a_stay_with_only_one_time_stays_all_day():
    lines = ics_lines({"type": "stay", "start": "2026-09-01", "end": "2026-09-08",
                       "all_day": True, "checkin_time": "16:00", "title": "Hotel"})
    assert "DTSTART;VALUE=DATE:20260901" in lines


def test_a_missing_end_gets_a_default_duration():
    # sabre-dav rejects a zero-length event.
    assert "DTEND:20260901T100000" in ics_lines(
        {"type": "train", "start": "2026-09-01T08:00", "title": "OUIGO"})
    assert "DTEND;VALUE=DATE:20260902" in ics_lines(
        {"type": "stay", "start": "2026-09-01", "all_day": True, "title": "Hotel"})


def test_a_reversed_span_is_corrected_rather_than_rejected():
    lines = ics_lines({"type": "flight", "start": "2026-09-01T20:00",
                       "end": "2026-09-01T08:00", "title": "AF1234"})
    assert "DTEND:20260901T220000" in lines


def test_a_mixed_timezone_span_does_not_crash():
    # One side aware, the other naive → TypeError on comparison; must fall back.
    lines = ics_lines({"type": "flight", "start": "2026-09-01T08:00+02:00",
                       "end": "2026-09-01T11:00", "title": "AF1234"})
    assert any(line.startswith("DTEND:") for line in lines)


def test_an_aware_datetime_is_converted_to_utc():
    lines = ics_lines({"type": "flight", "start": "2026-09-01T08:00+02:00",
                       "end": "2026-09-01T11:00+02:00", "title": "AF1234"})
    assert "DTSTART:20260901T060000Z" in lines
    assert "DTEND:20260901T090000Z" in lines


def test_an_unparseable_start_raises_so_the_caller_can_skip_permanently():
    with pytest.raises(ValueError):
        tc.build_ics({"type": "stay", "start": "next tuesday", "all_day": True}, "u")


def test_the_platform_prefixes_the_summary_unless_already_present():
    assert "SUMMARY:Airbnb · Zen Flat" in ics_lines(
        {"type": "stay", "start": "2026-09-01", "all_day": True,
         "title": "Zen Flat", "_platform": "Airbnb"})
    assert "SUMMARY:Airbnb — Lisbon" in ics_lines(
        {"type": "stay", "start": "2026-09-01", "all_day": True,
         "title": "Airbnb — Lisbon", "_platform": "Airbnb"})


def test_the_platform_becomes_a_category():
    assert "CATEGORIES:Airbnb" in ics_lines(
        {"type": "stay", "start": "2026-09-01", "all_day": True,
         "title": "x", "_platform": "Airbnb"})


def test_the_description_names_the_source_email():
    body = "\r\n".join(ics_lines({
        "type": "stay", "start": "2026-09-01", "all_day": True, "title": "x",
        "confirmation_code": "REF1", "notes": "2 guests",
        "_source_from": "noreply@airbnb.com", "_source_subject": "Reservation confirmed",
        "_source_date": "2026-08-01",
    }))
    assert "Ref: REF1" in body
    assert "2 guests" in body
    assert "Reservation confirmed" in body
    assert "added by travel-cal-sync" in body


@pytest.mark.parametrize(
    ("raw", "expected"),
    [("a;b", "a\\;b"), ("a,b", "a\\,b"), ("a\\b", "a\\\\b"), ("a\nb", "a\\nb"),
     ("a\r\nb", "a\\nb"), (None, "")],
)
def test_ical_special_characters_are_escaped(raw, expected):
    assert tc.esc(raw) == expected


def test_long_lines_are_folded_to_75_octets():
    folded = tc._fold("SUMMARY:" + "x" * 200)
    for line in folded.split("\r\n"):
        assert len(line.encode()) <= 75
    assert folded.split("\r\n")[1].startswith(" ")


def test_folding_never_splits_a_multibyte_character():
    folded = tc._fold("SUMMARY:" + "é" * 100)
    for line in folded.split("\r\n"):
        assert len(line.encode()) <= 75
    # Round-trips back to the original once unfolded.
    assert folded.replace("\r\n ", "") == "SUMMARY:" + "é" * 100


def test_a_short_line_is_left_alone():
    assert tc._fold("SUMMARY:short") == "SUMMARY:short"


# ── CalDAV ────────────────────────────────────────────────────────────────────


class FakeHttp:
    def __init__(self, status=201, body=b""):
        self.status = status
        self.body = body
        self.requests = []

    def __call__(self, req, timeout=None, data=None):
        self.requests.append(req)
        return self

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return self.body


def test_a_put_targets_the_uid_named_resource(tmp_path):
    pw = tmp_path / "pw"
    pw.write_text("secret\n")
    cfg = tc.Config(nc_cal="travel", nc_pass_file=str(pw),
                    caldav_home="https://h/dav/calendars/nsimon/")
    http = FakeHttp(204)
    assert tc.caldav_put(cfg, "uid@nic-os", "BEGIN:VCALENDAR", opener=http) == 204
    req = http.requests[0]
    # The UID in the path is what makes the write idempotent.
    assert req.full_url == "https://h/dav/calendars/nsimon/travel/uid@nic-os.ics"
    assert req.get_method() == "PUT"
    assert req.get_header("Content-type").startswith("text/calendar")
    assert req.get_header("Authorization").startswith("Basic ")


def test_a_put_without_a_configured_calendar_refuses(tmp_path):
    with pytest.raises(RuntimeError, match="NEXTCLOUD_CAL"):
        tc.caldav_put(tc.Config(nc_cal=""), "uid", "ics", opener=FakeHttp())


def test_the_calendar_list_is_parsed_from_the_propfind_response():
    xml = """<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/dav/calendars/nsimon/</d:href>
        <d:displayname>home</d:displayname></d:response>
      <d:response><d:href>/dav/calendars/nsimon/travel/</d:href>
        <d:displayname>Travel &amp; trips</d:displayname>
        <d:resourcetype><cal:calendar/></d:resourcetype></d:response>
    </d:multistatus>"""
    entries = tc.parse_calendar_list(xml)
    assert ("travel", "Travel & trips") in entries
    # The calendar HOME also matches, because its own href contains "calendars".
    # Harmless — this list is printed for a human to pick from.
    assert entries[0] == ("nsimon", "home")


def test_the_event_link_points_at_the_trip_month():
    cfg = tc.Config(caldav_home="https://h/nextcloud/remote.php/dav/calendars/nsimon/")
    assert tc.event_link(cfg, {"start": "2026-09-01"}) == (
        "https://h/nextcloud/apps/calendar/dayGridMonth/2026-09-01")


# ── body extraction ───────────────────────────────────────────────────────────


def message(parts, headers=()):
    lines = ["From: sender@airbnb.com", "Subject: Reservation confirmed"]
    lines += list(headers)
    lines += ["MIME-Version: 1.0",
              'Content-Type: multipart/alternative; boundary="B"', ""]
    for ct, payload in parts:
        lines += ["--B", f"Content-Type: {ct}; charset=utf-8", "", payload]
    lines.append("--B--")
    return email.message_from_string("\r\n".join(lines))


def test_the_plain_text_part_is_preferred():
    msg = message([("text/plain", "plain body"), ("text/html", "<p>html body</p>")])
    assert tc.body_text(msg) == "plain body"


def test_html_is_stripped_when_it_is_all_there_is():
    msg = message([("text/html", "<style>x{}</style><p>Hello</p><br>W&amp;orld")])
    assert tc.body_text(msg) == "Hello\n\nW&orld"


def test_the_body_is_capped():
    msg = message([("text/plain", "x" * 20000)])
    assert len(tc.body_text(msg)) == 12000


# ── scan: what reaches the calendar, and what gets retried ────────────────────


class FakeImap:
    """Answers SEARCH/FETCH the way imaplib does, for whatever messages it holds."""

    def __init__(self, messages):
        self.messages = messages  # [(num, email.Message)]
        self.searched = None

    def search(self, charset, *criteria):
        self.searched = criteria
        return "OK", [b" ".join(n for n, _ in self.messages)]

    def fetch(self, spec, what):
        if b"HEADER.FIELDS" in what.encode() if isinstance(what, str) else False:
            pass
        if "HEADER.FIELDS" in what:
            data = []
            for num, msg in self.messages:
                head = "\r\n".join(
                    f"{k}: {msg.get(k)}" for k in ("From", "Subject", "Message-ID")
                    if msg.get(k)
                ).encode() + b"\r\n\r\n"
                data.append((num + b" (BODY[HEADER.FIELDS", head))
            return "OK", data
        for num, msg in self.messages:
            if num == spec:
                return "OK", [(b"1 (RFC822 {})", msg.as_bytes())]
        return "NO", []

    def logout(self):
        pass


def booking_mail(num, mid, subject="Reservation confirmed", frm="noreply@airbnb.com"):
    msg = message([("text/plain", "your stay is confirmed")],
                  headers=[f"Message-ID: {mid}", "Date: Sat, 01 Aug 2026 10:00:00 +0000"])
    del msg["From"], msg["Subject"]
    msg["From"] = frm
    msg["Subject"] = subject
    return (num, msg)


STAY = {"is_booking": True, "type": "stay", "start": "2026-09-01",
        "end": "2026-09-08", "all_day": True, "title": "Airbnb — Lisbon"}


def fresh_state():
    return {"seen": [], "last_scan": 0}


def test_a_confirmed_booking_is_written_and_the_message_marked_seen():
    imap = FakeImap([booking_mail(b"1", "<m1@x>")])
    state = fresh_state()
    puts = []
    results = tc.scan(
        cfg_for(nc_cal="travel"), imap, state, dry_run=False,
        extract=lambda text: [dict(STAY)],
        put=lambda uid, ics: puts.append((uid, ics)),
        now=NOW,
    )
    assert len(results) == 1 and results[0][2] is True
    assert len(puts) == 1
    assert state["seen"] == ["<m1@x>"]
    assert state["last_scan"] > 0


def test_a_caldav_failure_leaves_the_message_unseen_for_retry():
    # The one transient failure: a booking must not be lost to a Nextcloud blip.
    imap = FakeImap([booking_mail(b"1", "<m1@x>")])
    state = fresh_state()

    def failing_put(uid, ics):
        raise OSError("nextcloud down")

    results = tc.scan(cfg_for(nc_cal="travel"), imap, state, dry_run=False,
                      extract=lambda text: [dict(STAY)], put=failing_put, now=NOW)
    assert results[0][2] is False
    assert state["seen"] == []


def test_a_malformed_booking_is_a_permanent_skip():
    # Unparseable dates will never parse; the message is marked seen so the model
    # is not asked about it again on every scan.
    imap = FakeImap([booking_mail(b"1", "<m1@x>")])
    state = fresh_state()
    puts = []
    results = tc.scan(
        cfg_for(nc_cal="travel"), imap, state, dry_run=False,
        extract=lambda text: [{**STAY, "start": "next tuesday"}],
        put=lambda uid, ics: puts.append(uid), now=NOW,
    )
    assert results == []
    assert puts == []
    assert state["seen"] == ["<m1@x>"]


def test_a_trip_that_already_ended_is_dropped():
    # Review requests, receipts and re-sent itineraries about past trips.
    imap = FakeImap([booking_mail(b"1", "<m1@x>")])
    state = fresh_state()
    puts = []
    tc.scan(cfg_for(nc_cal="travel"), imap, state, dry_run=False,
            extract=lambda text: [{**STAY, "start": "2026-01-01", "end": "2026-01-08"}],
            put=lambda uid, ics: puts.append(uid), now=NOW)
    assert puts == []
    assert state["seen"] == ["<m1@x>"]


def test_a_trip_ending_within_the_grace_window_is_kept():
    imap = FakeImap([booking_mail(b"1", "<m1@x>")])
    puts = []
    tc.scan(cfg_for(nc_cal="travel"), imap, fresh_state(), dry_run=False,
            extract=lambda text: [{**STAY, "start": "2026-08-01", "end": "2026-08-05"}],
            put=lambda uid, ics: puts.append(uid), now=NOW)
    assert len(puts) == 1


def test_a_non_booking_answer_writes_nothing():
    imap = FakeImap([booking_mail(b"1", "<m1@x>")])
    puts = []
    tc.scan(cfg_for(nc_cal="travel"), imap, fresh_state(), dry_run=False,
            extract=lambda text: [{"is_booking": False}], put=lambda u, i: puts.append(u),
            now=NOW)
    assert puts == []


def test_a_non_travel_type_writes_nothing():
    # Concerts, restaurants and laser tag are not travel.
    imap = FakeImap([booking_mail(b"1", "<m1@x>")])
    puts = []
    tc.scan(cfg_for(nc_cal="travel"), imap, fresh_state(), dry_run=False,
            extract=lambda text: [{**STAY, "type": "concert"}],
            put=lambda u, i: puts.append(u), now=NOW)
    assert puts == []


def test_two_emails_about_one_booking_write_once_per_scan():
    imap = FakeImap([booking_mail(b"1", "<m1@x>"), booking_mail(b"2", "<m2@x>")])
    puts = []
    tc.scan(cfg_for(nc_cal="travel"), imap, fresh_state(), dry_run=False,
            extract=lambda text: [dict(STAY)], put=lambda uid, i: puts.append(uid),
            now=NOW)
    assert len(puts) == 1


def test_a_query_email_is_screened_out_before_the_model_is_asked():
    imap = FakeImap([booking_mail(b"1", "<m1@x>", subject="Pending: Reservation Request")])
    state = fresh_state()
    asked = []
    tc.scan(cfg_for(), imap, state, dry_run=False,
            extract=lambda text: asked.append(text) or [], put=lambda u, i: None, now=NOW)
    assert asked == []
    assert state["seen"] == ["<m1@x>"]  # and never asked again


def test_an_already_seen_message_is_skipped():
    imap = FakeImap([booking_mail(b"1", "<m1@x>")])
    state = {"seen": ["<m1@x>"], "last_scan": 0}
    asked = []
    tc.scan(cfg_for(), imap, state, dry_run=False,
            extract=lambda text: asked.append(text) or [], put=lambda u, i: None, now=NOW)
    assert asked == []


def test_dry_run_never_writes():
    imap = FakeImap([booking_mail(b"1", "<m1@x>")])
    puts = []
    results = tc.scan(cfg_for(nc_cal="travel"), imap, fresh_state(), dry_run=True,
                      extract=lambda text: [dict(STAY)],
                      put=lambda uid, ics: puts.append(uid), now=NOW)
    assert puts == []
    assert results[0][2] is False


def test_an_upstream_outage_stops_the_scan_and_propagates():
    # The daemon catches this to back off; the message must stay unseen.
    imap = FakeImap([booking_mail(b"1", "<m1@x>")])
    state = fresh_state()

    def down(text):
        raise tc.UpstreamDown("beast asleep")

    with pytest.raises(tc.UpstreamDown):
        tc.scan(cfg_for(), imap, state, dry_run=False, extract=down,
                put=lambda u, i: None, now=NOW)
    assert state["seen"] == []


def test_an_extract_error_that_is_not_an_outage_skips_only_that_message():
    imap = FakeImap([booking_mail(b"1", "<m1@x>")])
    state = fresh_state()
    tc.scan(cfg_for(), imap, state, dry_run=False,
            extract=lambda text: (_ for _ in ()).throw(ValueError("weird")),
            put=lambda u, i: None, now=NOW)
    # Not marked seen: the message is retried, but the scan continued.
    assert state["seen"] == []


def test_the_first_scan_searches_back_over_the_lookback_window():
    imap = FakeImap([])
    tc.scan(cfg_for(lookback_days=365), imap, fresh_state(), dry_run=True,
            extract=lambda t: [], put=lambda u, i: None, now=NOW)
    assert imap.searched == ("SINCE", "06-Aug-2025")


def test_a_later_scan_searches_from_two_days_before_the_last_one():
    imap = FakeImap([])
    last = int(datetime(2026, 8, 5, tzinfo=timezone.utc).timestamp())
    tc.scan(cfg_for(), imap, {"seen": [], "last_scan": last}, dry_run=True,
            extract=lambda t: [], put=lambda u, i: None, now=NOW)
    assert imap.searched == ("SINCE", "03-Aug-2026")


# ── state ─────────────────────────────────────────────────────────────────────


def test_state_round_trips_and_is_capped(tmp_path):
    cfg = cfg_for(tmp_path)
    state = {"seen": [f"<m{i}@x>" for i in range(tc.SEEN_CAP + 50)], "last_scan": 7}
    tc.save_state(cfg, state)
    back = tc.load_state(cfg)
    assert len(back["seen"]) == tc.SEEN_CAP
    assert back["seen"][-1] == f"<m{tc.SEEN_CAP + 49}@x>"  # newest kept
    assert back["last_scan"] == 7


def test_a_missing_or_corrupt_state_file_starts_clean(tmp_path):
    cfg = cfg_for(tmp_path)
    assert tc.load_state(cfg) == {"seen": [], "last_scan": 0}
    (tmp_path / "state.json").write_text("{truncated")
    assert tc.load_state(cfg) == {"seen": [], "last_scan": 0}


# ── reporting ─────────────────────────────────────────────────────────────────


def test_a_booking_line_reads_as_a_summary():
    line = tc.fmt_booking({"type": "stay", "start": "2026-09-01", "end": "2026-09-08",
                           "title": "Airbnb — Lisbon", "location": "Lisbon",
                           "confirmation_code": "REF1"})
    assert line == "stay  2026-09-01 → 2026-09-08  Airbnb — Lisbon @ Lisbon [REF1]"


def test_the_telegram_summary_escapes_html_and_links_each_event():
    cfg = tc.Config(caldav_home="https://h/nextcloud/remote.php/dav/calendars/n/")
    msg = tc.telegram_summary(cfg, [({"type": "stay", "start": "2026-09-01",
                                      "title": "A & B"}, "uid", True)])
    assert "A &amp; B" in msg
    assert "apps/calendar/dayGridMonth/2026-09-01" in msg


def test_no_telegram_when_the_seam_is_not_wired():
    # Running by hand (no TELEGRAM_SEND) must not try to send anything.
    sent = []
    tc.telegram(tc.Config(telegram_send=""), "hi", run=lambda *a, **k: sent.append(a))
    assert sent == []


def test_the_summary_goes_through_the_shared_one_shot_sender():
    # Not hand-rolled here: shared/notify.nix `send` owns parse mode, urlencoding
    # and timeouts for every one-shot sender.
    calls = []
    tc.telegram(tc.Config(telegram_send="/nix/store/x/bin/send"), "hi",
                run=lambda argv, **kw: calls.append((argv, kw)))
    argv, kw = calls[0]
    assert argv == ["/nix/store/x/bin/send", "hi"]
    assert kw["check"] is False and kw["timeout"] == 30


def test_a_telegram_failure_never_propagates(capsys):
    def boom(*a, **k):
        raise OSError("telegram down")

    tc.telegram(tc.Config(telegram_send="/bin/send"), "hi", run=boom)  # must not raise
    assert "telegram error" in capsys.readouterr().err
