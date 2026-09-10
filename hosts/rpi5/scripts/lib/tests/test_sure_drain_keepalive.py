"""The two failure directions that matter here are opposite mistakes:

waking when there is nothing to do (undoes socket activation, Sure never sleeps)
and NOT waking when there is (the multi-day stall this unit exists to prevent).
See nicos_scripts/sure/drain_keepalive.py.
"""

from nicos_scripts.sure import drain_keepalive as dk


def cfg(**kw):
    base = dict(redis_cli="redis-cli", redis_db=2, curl="curl",
                wake_url="http://127.0.0.1:13334/sure/up", timeout=90,
                queues=("scheduled", "high_priority", "medium_priority",
                        "low_priority", "default"))
    base.update(kw)
    return dk.Config(**base)


def fake_run(depths=None, calls=None):
    """LLEN answers per queue; every command is appended to `calls`."""
    depths = depths or {}

    def run(cmd):
        if calls is not None:
            calls.append(cmd)
        if "llen" in cmd:
            q = cmd[-1].removeprefix("queue:")
            return f"{depths.get(q, 0)}\n"
        return ""

    return run


def wake_urls(calls):
    return [c[-1] for c in calls if c[0] == "curl"]


# ── must wake ────────────────────────────────────────────────────────────────

def test_a_backlog_triggers_exactly_one_wake():
    calls = []
    dk.main(env={}, run=fake_run({"medium_priority": 946}, calls),
            log=lambda m: None)
    assert wake_urls(calls) == ["http://127.0.0.1:13334/sure/up"]


def test_work_on_any_watched_queue_wakes():
    """Not just the enrichment queue — a stuck sync backlog matters too."""
    for q in ("scheduled", "high_priority", "medium_priority",
              "low_priority", "default"):
        calls = []
        dk.main(env={}, run=fake_run({q: 1}, calls), log=lambda m: None)
        assert wake_urls(calls), f"{q} did not wake"


def test_the_wake_hits_the_proxy_not_the_backend():
    """Connecting straight to sure-web bypasses the proxy, so it would not
    reset --exit-idle-time and the worker would still be torn down."""
    assert "13334" in dk.DEFAULT_WAKE_URL


# ── must NOT wake ────────────────────────────────────────────────────────────

def test_empty_queues_do_not_wake():
    calls = []
    dk.main(env={}, run=fake_run({}, calls), log=lambda m: None)
    assert wake_urls(calls) == []


def test_the_dead_set_is_not_watched():
    """`dead` is permanently non-empty here (46 abandoned jobs), so counting it
    would pin Sure awake forever and quietly undo socket activation."""
    assert "dead" not in dk.DEFAULT_QUEUES
    assert "retry" not in dk.DEFAULT_QUEUES
    assert "schedule," not in dk.DEFAULT_QUEUES + ","


def test_only_llen_is_used_so_future_dated_jobs_cannot_pin_it_awake():
    """retry/schedule are zsets; LLEN on a list keeps them out by construction."""
    calls = []
    dk.main(env={}, run=fake_run({}, calls), log=lambda m: None)
    assert all("llen" in c for c in calls if c[0] == "redis-cli")


# ── an unreadable Redis must not read as "empty" ─────────────────────────────

def test_unparseable_llen_is_none_not_zero():
    def run(cmd):
        return "ERR unknown command\n"

    depths = dk.queue_depths(cfg(), run)
    assert set(depths.values()) == {None}


def test_an_unreadable_redis_fails_loudly_and_does_not_wake():
    """Guessing "empty" here is exactly what a silent multi-day stall is."""
    calls, msgs = [], []

    def run(cmd):
        calls.append(cmd)
        return "" if "llen" in cmd else ""

    rc = dk.main(env={}, run=run, log=msgs.append)
    assert rc == 1
    assert wake_urls(calls) == []
    assert "FATAL" in msgs[0]


# ── reporting ────────────────────────────────────────────────────────────────

def test_the_log_line_names_the_busy_queues_biggest_first():
    msgs = []
    dk.main(env={}, run=fake_run({"medium_priority": 946, "high_priority": 15}),
            log=msgs.append)
    assert "961 jobs pending" in msgs[0]
    assert msgs[0].index("medium_priority=946") < msgs[0].index("high_priority=15")


def test_empty_queues_are_left_out_of_the_summary():
    assert dk.summarize({"a": 0, "b": 3, "c": None}) == "b=3"


# ── config ───────────────────────────────────────────────────────────────────

def test_defaults_need_no_env():
    c = dk.Config.from_env({})
    assert c.redis_db == 2
    assert c.queues[0] == "scheduled"
    assert c.timeout == 90


def test_garbage_timeout_falls_back_instead_of_crashing_the_timer():
    assert dk.Config.from_env({"WAKE_TIMEOUT": "soon"}).timeout == 90


def test_the_wake_timeout_covers_a_rails_cold_start():
    """Rails takes ~30s to boot and the readyProbe allows 60s; a shorter
    timeout makes every wake-from-cold report failure."""
    assert dk.DEFAULT_TIMEOUT >= 60
