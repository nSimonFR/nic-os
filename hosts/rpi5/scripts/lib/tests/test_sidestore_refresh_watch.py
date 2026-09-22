import json
from datetime import datetime, timedelta, timezone

from nicos_scripts.sidestore import refresh_watch as rw

NOW = datetime(2026, 9, 22, 12, 0, tzinfo=timezone.utc)


def nft_json(*counters):
    """An `nft -j list table` reply carrying one rule per counter value."""
    rules = [
        {"rule": {"chain": "prerouting", "expr": [
            {"match": {"op": "==", "left": {"meta": {"key": "iifname"}},
                       "right": "tailscale0"}},
            {"counter": {"packets": p, "bytes": p * 60}},
        ]}}
        for p in counters
    ]
    return json.dumps({"nftables": [{"metainfo": {"version": "1.1.5"}},
                                    {"table": {"name": "sidestore"}}] + rules})


def cfg():
    return rw.Config()


def runner(out):
    return lambda cmd: out


# ── read_counter ─────────────────────────────────────────────────────────────

def test_read_counter_sums_every_rule():
    # A reload that appended a duplicate rule splits the count across both.
    assert rw.read_counter(cfg(), runner(nft_json(300, 98))) == 398


def test_read_counter_none_when_table_absent():
    # `nft` writes the error to stderr and leaves stdout empty.
    assert rw.read_counter(cfg(), runner("")) is None


def test_read_counter_none_when_rule_has_no_counter():
    ruleset = json.dumps({"nftables": [
        {"rule": {"chain": "prerouting", "expr": [{"match": {}}]}},
    ]})
    assert rw.read_counter(cfg(), runner(ruleset)) is None


def test_read_counter_zero_is_not_unreadable():
    assert rw.read_counter(cfg(), runner(nft_json(0))) == 0


# ── assess ───────────────────────────────────────────────────────────────────

def test_first_run_is_healthy_and_seeds_state():
    body, state = rw.assess(None, 398, NOW, 120)
    assert body == ""
    assert state == {"packets": 398, "since": NOW.isoformat()}


def test_counter_moved_restarts_the_clock():
    prev = {"packets": 398, "since": (NOW - timedelta(days=9)).isoformat()}
    body, state = rw.assess(prev, 512, NOW, 120)
    assert body == ""
    assert state["since"] == NOW.isoformat()


def test_counter_reset_is_not_a_stall():
    # The table is recreated on every reflector restart and on boot, so the
    # counter drops to 0 — reading that as "no traffic" would page per rebuild.
    prev = {"packets": 900, "since": (NOW - timedelta(days=9)).isoformat()}
    body, state = rw.assess(prev, 12, NOW, 120)
    assert body == ""
    assert state == {"packets": 12, "since": NOW.isoformat()}


def test_flat_under_threshold_is_healthy():
    prev = {"packets": 398, "since": (NOW - timedelta(hours=100)).isoformat()}
    body, state = rw.assess(prev, 398, NOW, 120)
    assert body == ""
    assert state["since"] == prev["since"]


def test_flat_over_threshold_alerts_and_keeps_since():
    prev = {"packets": 398, "since": (NOW - timedelta(days=6)).isoformat()}
    body, state = rw.assess(prev, 398, NOW, 120)
    assert "no SideStore refresh traffic for 6.0d" in body
    assert "398 packets" in body
    assert "RemotePair Port" in body
    # Not reset on alert, or the next run would report a fresh 1h stall.
    assert state["since"] == prev["since"]


def test_unreadable_counter_alerts_without_clobbering_state():
    prev = {"packets": 398, "since": (NOW - timedelta(hours=1)).isoformat()}
    body, state = rw.assess(prev, None, NOW, 120)
    assert "no readable counter" in body
    assert state == prev


def test_corrupt_since_restarts_the_clock_instead_of_crashing():
    prev = {"packets": 398, "since": "not-a-date"}
    body, state = rw.assess(prev, 398, NOW, 120)
    assert body == ""
    assert state["since"] == NOW.isoformat()


# ── main ─────────────────────────────────────────────────────────────────────

def test_main_writes_state_and_stays_quiet(tmp_path, capsys):
    env = {"STATE_DIR": str(tmp_path)}
    rw.main(env=env, run=runner(nft_json(398)), now=NOW, log=lambda m: None)
    assert capsys.readouterr().out == ""
    saved = json.loads((tmp_path / rw.STATE_FILE).read_text())
    assert saved == {"packets": 398, "since": NOW.isoformat()}


def test_main_prints_body_when_stale(tmp_path, capsys):
    env = {"STATE_DIR": str(tmp_path), "STALE_HOURS": "24"}
    (tmp_path / rw.STATE_FILE).write_text(json.dumps(
        {"packets": 398, "since": (NOW - timedelta(days=3)).isoformat()}))
    rw.main(env=env, run=runner(nft_json(398)), now=NOW, log=lambda m: None)
    assert "no SideStore refresh traffic" in capsys.readouterr().out


def test_main_reads_config_from_env_not_import(tmp_path):
    seen = []

    def run(cmd):
        seen.append(cmd)
        return nft_json(1)

    rw.main(env={"STATE_DIR": str(tmp_path), "NFT_BIN": "/run/x/nft",
                 "SIDESTORE_NFT_TABLE": "other"},
            run=run, now=NOW, log=lambda m: None)
    assert seen[0] == ["/run/x/nft", "-j", "list", "table", "ip", "other"]
