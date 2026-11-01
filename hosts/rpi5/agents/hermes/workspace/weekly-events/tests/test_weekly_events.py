import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from weekly_events.changes import ChangeDetector
from weekly_events.ics import parse_ics
from weekly_events.model import Event
from weekly_events.normalize import normalize, stable_id
from weekly_events.notify import render_digest
from weekly_events.store import EventStore
from weekly_events.parsers import json_events, parse_source


class NormalizationTests(unittest.TestCase):
    def test_json_source_extracts_date_from_configured_text_field(self):
        import weekly_events.parsers as parsers
        source = {"id":"robin", "base_url":"https://robindesjeux.com", "timezone":"Europe/Paris", "config": {
            "url":"https://example.test/products", "fields":{"external_id":"id", "title":"title.rendered", "event_url":"link", "description":"content.rendered"},
            "extract":{"start_at":{"from":"title.rendered", "regex":"(Lundi)\\s+(\\d{1,2})\\s+(août)", "template":"{0} {1} {2} {year} · 19:30"}}
        }}
        old = parsers.fetch
        parsers.fetch = lambda _: json.dumps([{"id":7,"title":{"rendered":"Lundi 24 août – Tournament"},"link":"/event/7","content":{"rendered":"19h30"}}])
        try: event = json_events(source)[0]
        finally: parsers.fetch = old
        self.assertEqual(event.external_id, "7")
        self.assertEqual(event.start_at[:10], "2026-08-24")
    def test_derives_stable_id_and_hash_ignores_cosmetic_whitespace(self):
        raw = {
            "title": "  Commander   Night ",
            "event_url": "https://shop.test/event/7?utm_source=x",
            "start_at": "2026-08-12T19:30:00+02:00",
            "description": "Hello   world\n\n",
            "status": "scheduled",
        }
        event = normalize("shop", raw, "Europe/Paris")
        self.assertEqual(event.external_id, stable_id(raw["event_url"], raw["start_at"]))
        self.assertEqual(event.title, "Commander Night")
        equivalent = normalize("shop", {**raw, "description": "Hello world"}, "Europe/Paris")
        self.assertEqual(event.content_hash, equivalent.content_hash)

    def test_ics_expands_event_and_reads_cancelled_status(self):
        events = parse_ics("""BEGIN:VCALENDAR
VERSION:2.0
BEGIN:VEVENT
UID:abc@example.test
SUMMARY:Draft Night
DTSTART;TZID=Europe/Paris:20260812T193000
DTEND;TZID=Europe/Paris:20260812T223000
LOCATION:Game Shop, Paris
STATUS:CANCELLED
URL:https://example.test/register
END:VEVENT
END:VCALENDAR
""", "ics-source", "Europe/Paris")
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].external_id, "abc@example.test")
        self.assertEqual(events[0].status, "cancelled")
        self.assertEqual(events[0].city, "Paris")

    def test_ics_utc_stamps_convert_instead_of_relabelling(self):
        events = parse_ics("""BEGIN:VEVENT
UID:utc@example.test
SUMMARY:Draft Night
DTSTART:20260812T173000Z
END:VEVENT
""", "ics-source", "Europe/Paris")
        self.assertEqual(events[0].start_at, "2026-08-12T19:30:00+02:00")


class SourceMethodTests(unittest.TestCase):
    def source(self, *methods):
        return {"id": "s", "base_url": "https://example.test", "methods": list(methods), "config": {"url": "https://example.test/f"}}

    def test_successful_empty_source_is_not_a_failure(self):
        import weekly_events.parsers as parsers
        old = parsers.fetch
        parsers.fetch = lambda _: "BEGIN:VCALENDAR\nEND:VCALENDAR\n"
        try: events, method = parse_source(self.source("ics"))
        finally: parsers.fetch = old
        self.assertEqual((events, method), ([], "ics"))

    def test_all_methods_failing_still_raises(self):
        import weekly_events.parsers as parsers
        old = parsers.fetch
        parsers.fetch = lambda _: (_ for _ in ()).throw(OSError("boom"))
        try: self.assertRaises(RuntimeError, parse_source, self.source("ics"))
        finally: parsers.fetch = old


class ChangeAndStoreTests(unittest.TestCase):
    def event(self, **changes):
        base = dict(source_id="source", external_id="one", title="Modern Tournament", start_at="2026-08-12T19:30:00+02:00", timezone="Europe/Paris", event_url="https://example.test/one", capacity=20, remaining_seats=10)
        return normalize("source", {**base, **changes}, "Europe/Paris")

    def test_detects_new_updated_cancelled_and_removed(self):
        old = self.event()
        now = self.event(remaining_seats=4)
        cancelled = self.event(external_id="two", status="cancelled")
        removed_old = self.event(external_id="gone")
        result = ChangeDetector().compare({old.key: old, removed_old.key: removed_old}, {now.key: now, cancelled.key: cancelled})
        self.assertEqual([x.external_id for x in result.cancelled], ["two"])
        self.assertEqual(result.updated[0].fields["remaining_seats"], (10, 4))
        self.assertEqual([x.external_id for x in result.removed], ["gone"])

    def test_store_persists_events_between_runs(self):
        with tempfile.TemporaryDirectory() as d:
            store = EventStore(Path(d) / "state.sqlite3")
            event = self.event()
            store.replace_snapshot({event.key: event}, {"source": "ok"})
            events, runs = store.load_snapshot()
            self.assertEqual(events[event.key].title, event.title)
            self.assertEqual(runs["source"], "ok")


class DeliveryTests(unittest.TestCase):
    def test_failed_telegram_send_leaves_changes_pending_for_the_next_run(self):
        import os
        import weekly_events.app as app
        event = normalize("source", {"external_id": "one", "title": "Modern Tournament", "start_at": "2999-08-12T19:30:00+02:00", "event_url": "https://example.test/one"}, "Europe/Paris")
        sent = []
        original = app.parse_source, app.telegram_send
        app.parse_source = lambda source: ([event], "json")
        with tempfile.TemporaryDirectory() as d:
            config = Path(d) / "sources.json"
            config.write_text(json.dumps({"sources": [{"id": "source"}]}))
            state = Path(d) / "state.sqlite3"
            os.environ["TELEGRAM_BOT_TOKEN"] = "t"; os.environ["TELEGRAM_CHAT_ID"] = "c"
            try:
                app.telegram_send = lambda *a: (_ for _ in ()).throw(OSError("429"))
                self.assertRaises(OSError, app.run, config, state, True)
                app.telegram_send = lambda token, chat, text: sent.append(text)
                app.run(config, state, True)
            finally:
                app.parse_source, app.telegram_send = original
        self.assertIn("Modern Tournament", sent[0])


class DigestTests(unittest.TestCase):
    def test_renders_compact_markdown(self):
        event = normalize("s", {"external_id":"a", "title":"Modern Tournament", "start_at":"2026-08-12T19:30:00+02:00", "timezone":"Europe/Paris", "venue":"Magic Corporation", "price":"10€", "remaining_seats":6, "event_url":"https://example.test/a"}, "Europe/Paris")
        result = ChangeDetector().compare({}, {event.key:event})
        text = render_digest(result, now=datetime(2026, 8, 1, tzinfo=timezone.utc))
        self.assertIn("🎲 Weekly Events", text)
        self.assertIn("🆕 New", text)
        self.assertIn("6 seats left", text)


if __name__ == "__main__":
    unittest.main()
