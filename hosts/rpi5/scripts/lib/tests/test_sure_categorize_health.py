"""The regression under test is an alert that stayed silent for eight days.

So most of these assert on the SILENT direction: the shapes that must page, and
the shapes that must not. See nicos_scripts/sure/categorize_health.py.
"""

import json
from datetime import datetime, timedelta, timezone

from nicos_scripts import pg as pg_mod
from nicos_scripts.sure import categorize_health as ch

NOW = datetime(2026, 9, 10, 8, 0, 0, tzinfo=timezone.utc)


def cfg(**kw):
    base = dict(sure_db="sure_production", runuser="runuser", psql="psql",
                redis_cli="redis-cli", redis_db=2, stale_hours=24,
                queues=("categorize", "medium_priority"))
    base.update(kw)
    return ch.Config(**base)


def job(cls="AutoCategorizeJob", created_at=None, ms=True):
    """One Sidekiq queue entry, shaped like the real ActiveJob wrapper."""
    at = created_at if created_at is not None else NOW
    epoch = at.timestamp() * 1000 if ms else at.timestamp()
    return json.dumps({
        "class": "Sidekiq::ActiveJob::Wrapper",
        "args": [{"job_class": cls}],
        "created_at": epoch,
    })


def fake_run(queues=None, tables=None):
    """Dispatch on the command: redis lrange by queue name, psql by SQL text.

    Matching table reads on the SQL text rather than on call order keeps these
    from silently passing if the module reorders its reads. Rows are joined with
    the same separator `psql_rows` splits on, so a separator change fails here
    instead of quietly returning one wide column.
    """
    queues, tables = queues or {}, tables or {}

    def run(cmd):
        if "lrange" in cmd:
            key = cmd[cmd.index("lrange") + 1]
            return "".join(l + "\n" for l in queues.get(key, []))
        sql = cmd[-1]
        for needle, rows in tables.items():
            if needle in sql:
                return "".join(pg_mod.SEP.join(r) + "\n" for r in rows)
        return ""

    return run


# ── the eight-day stall must page ────────────────────────────────────────────

def test_queued_jobs_older_than_the_threshold_page():
    """The exact 2026-09-02 shape: jobs queued, nothing draining."""
    body = ch.assess(queued=219, oldest=NOW - timedelta(days=8),
                     last_write=NOW - timedelta(days=8), backlog=892,
                     now=NOW, stale_hours=24)
    assert body
    assert "219 AutoCategorizeJob queued" in body
    assert "8.0d ago" in body
    assert "892" in body


def test_the_body_points_at_worker_uptime_as_the_thing_to_check():
    """Uptime, not queue order: that was the actual cause in 2026-09."""
    body = ch.assess(219, NOW - timedelta(days=8), NOW - timedelta(days=8),
                     892, NOW, 24)
    assert "sure-drain-keepalive" in body


# ── and the healthy shapes must not ──────────────────────────────────────────

def test_an_empty_queue_is_healthy_however_stale_the_last_write():
    """The permanent residue of ambiguous transactions is not a fault.

    Nothing queued means there is nothing for the worker to fail at, so a month
    of silence here is 'everything categorizable is categorized'.
    """
    assert ch.assess(0, None, NOW - timedelta(days=30), 892, NOW, 24) == ""


def test_a_freshly_enqueued_backlog_is_healthy():
    """A sync that just pushed work has not failed yet."""
    assert ch.assess(219, NOW - timedelta(hours=2), NOW, 892, NOW, 24) == ""


def test_waiting_just_under_the_threshold_is_healthy():
    """The worker wakes ~daily, so ~20h of waiting is normal idle behaviour."""
    assert ch.assess(5, NOW - timedelta(hours=23, minutes=50), NOW, 100,
                     NOW, 24) == ""


def test_waiting_just_over_the_threshold_pages():
    assert ch.assess(5, NOW - timedelta(hours=24, minutes=10), NOW, 100,
                     NOW, 24) != ""


# ── the ms-vs-seconds trap ───────────────────────────────────────────────────

def test_millisecond_created_at_is_not_read_as_seconds():
    """Sidekiq 8 writes ms. Read as seconds it lands in the year 58000.

    That is not a cosmetic bug: a future timestamp makes `waiting` negative, so
    the oldest job in an eight-day-stalled queue reports as healthy.
    """
    at = ch.job_created_at(job(created_at=NOW, ms=True))
    assert at == NOW


def test_float_second_created_at_still_parses():
    assert ch.job_created_at(job(created_at=NOW, ms=False)) == NOW


def test_a_payload_with_no_created_at_is_none_not_a_crash():
    assert ch.job_created_at(json.dumps({"args": [{}]})) is None


# ── queue scanning ───────────────────────────────────────────────────────────

def test_only_categorize_jobs_are_counted():
    """691 merchant jobs in the same queue must not read as categorize work."""
    q = {"queue:medium_priority": [job(cls="AutoDetectMerchantsJob")] * 691
                                  + [job()] * 219}
    count, _ = ch.queued_categorize(cfg(), fake_run(queues=q))
    assert count == 219


def test_every_configured_queue_is_scanned():
    """Overridable so a queue rename cannot silently report 'nothing queued',
    which this check would read as healthy."""
    q = {"queue:categorize": [job()] * 3,
         "queue:medium_priority": [job()] * 4}
    count, _ = ch.queued_categorize(cfg(), fake_run(queues=q))
    assert count == 7


def test_the_default_queue_is_where_sure_actually_enqueues():
    assert ch.Config.from_env({}).queues == ("medium_priority",)


def test_the_oldest_job_across_queues_wins():
    old = NOW - timedelta(days=8)
    q = {"queue:categorize": [job(created_at=NOW)],
         "queue:medium_priority": [job(created_at=old)]}
    _, oldest = ch.queued_categorize(cfg(), fake_run(queues=q))
    assert oldest == old


def test_a_malformed_payload_does_not_hide_the_jobs_around_it():
    q = {"queue:categorize": ["{not json at all AutoCategorizeJob", job()]}
    count, oldest = ch.queued_categorize(cfg(), fake_run(queues=q))
    assert count == 2          # still counted — the class name was there
    assert oldest == NOW       # and the readable one still set the age


def test_an_empty_queue_reads_as_zero_not_a_crash():
    count, oldest = ch.queued_categorize(cfg(), fake_run(queues={}))
    assert (count, oldest) == (0, None)


# ── reading the DB ───────────────────────────────────────────────────────────

def test_last_category_write_parses_postgres_microseconds():
    run = fake_run(tables={"data_enrichments": [["2026-09-02 11:57:38.96252"]]})
    got = ch.last_category_write(cfg(), run)
    assert got == datetime(2026, 9, 2, 11, 57, 38, 962520, tzinfo=timezone.utc)


def test_last_category_write_parses_a_whole_second():
    run = fake_run(tables={"data_enrichments": [["2026-09-02 11:57:38"]]})
    assert ch.last_category_write(cfg(), run).second == 38


def test_no_enrichments_yet_is_none_not_a_crash():
    """max() over zero rows returns one empty column, not zero rows."""
    run = fake_run(tables={"data_enrichments": [[""]]})
    assert ch.last_category_write(cfg(), run) is None


def test_backlog_excludes_transfers():
    """funds_movement is correctly never categorized; counting it would report
    a permanent several-hundred backlog as a fault."""
    seen = {}

    def run(cmd):
        seen["sql"] = cmd[-1]
        return "892\n"

    assert ch.uncategorized_standard(cfg(), run) == 892
    assert "kind = 'standard'" in seen["sql"]


# ── wiring ───────────────────────────────────────────────────────────────────

def test_main_prints_the_body_on_stdout_and_nothing_when_healthy(capsys):
    """stdout IS the alert body — the unit pipes it to telegram-alert."""
    q = {"queue:medium_priority": [job(created_at=NOW - timedelta(days=8))] * 3}
    tables = {"data_enrichments": [["2026-09-02 11:57:38"]],
              "transactions": [["892"]]}
    ch.main(env={}, run=fake_run(queues=q, tables=tables), now=NOW,
            log=lambda m: None)
    assert "AutoCategorizeJob queued" in capsys.readouterr().out

    ch.main(env={}, run=fake_run(queues={}, tables=tables), now=NOW,
            log=lambda m: None)
    assert capsys.readouterr().out == ""


def test_a_healthy_run_logs_to_stderr_never_stdout(capsys):
    """A log line on stdout would page as its own alert body."""
    tables = {"data_enrichments": [["2026-09-10 07:00:00"]],
              "transactions": [["12"]]}
    ch.main(env={}, run=fake_run(queues={}, tables=tables), now=NOW)
    out = capsys.readouterr()
    assert out.out == ""
    assert "ok" in out.err


def test_config_defaults_are_safe_with_no_env():
    c = ch.Config.from_env({})
    assert c.stale_hours == 24
    assert c.redis_db == 2


def test_garbage_stale_hours_falls_back_instead_of_crashing_the_timer():
    assert ch.Config.from_env({"STALE_HOURS": "soon"}).stale_hours == 24
