from nicos_scripts.monitoring.psi_oom import (
    Config,
    full_avg10,
    on_stall,
    parse_status,
    pick_victim,
    scan_procs,
)

PRESSURE = (
    "some avg10=61.20 avg60=40.00 avg300=12.00 total=123\n"
    "full avg10=45.50 avg60=30.00 avg300=9.00 total=99\n"
)


def test_config_defaults_to_dry_run():
    assert Config.from_env({}).dry_run is True
    assert Config.from_env({"PSI_OOM_DRY_RUN": "0"}).dry_run is False


def test_trigger_is_in_microseconds():
    cfg = Config.from_env({"PSI_OOM_STALL_MS": "3000", "PSI_OOM_WINDOW_MS": "8000"})
    assert cfg.trigger == "full 3000000 8000000\0"


def test_full_avg10():
    assert full_avg10(PRESSURE) == 45.5
    assert full_avg10("") is None


MIB = 1024

# The 2026-11-11 shape: a tiny adj-1000 sidecar and an adj-800 agent outrank
# the real consumer under sysrq f.
PROCS = [
    (10, "ryot-sandboxd", 1000, 1 * MIB),
    (20, ".claude-wrapped", 800, 90 * MIB),
    (30, "immich", 0, 400 * MIB),
    (40, "sshd", -1000, 900 * MIB),
]


def test_parse_status():
    text = "Name:\tbun\nVmRSS:\t 300 kB\nRssAnon:\t 200 kB\nVmSwap:\t 50 kB\n"
    assert parse_status(text) == ("bun", 250)
    assert parse_status("Name:\tkthreadd\n") is None


def test_pick_victim_by_size_not_adj():
    assert pick_victim(PROCS, 64 * MIB, 99) == (30, "immich", 400 * MIB)


def test_pick_victim_skips_self_and_small():
    assert pick_victim(PROCS, 64 * MIB, 30) == (20, ".claude-wrapped", 90 * MIB)
    assert pick_victim(PROCS, 500 * MIB, 99) is None


def test_scan_procs(tmp_path):
    for pid, status, adj in [
        ("7", "Name:\tbun\nRssAnon:\t 100 kB\nVmSwap:\t 5 kB\n", "800"),
        ("2", "Name:\tkthreadd\n", "0"),
    ]:
        (tmp_path / pid).mkdir()
        (tmp_path / pid / "status").write_text(status)
        (tmp_path / pid / "oom_score_adj").write_text(adj)
    (tmp_path / "8").mkdir()  # exited mid-scan
    (tmp_path / "self").mkdir()
    assert list(scan_procs(str(tmp_path))) == [(7, "bun", 800, 105)]


def run(cfg, last, now, logged, procs=PROCS):
    kills = []
    out = on_stall(
        cfg,
        last,
        now,
        read=lambda: PRESSURE,
        procs=lambda: procs,
        kill=kills.append,
        log=logged,
    )
    return out, kills


def test_stall_kills_largest(logged):
    lines, log = logged
    cfg = Config(dry_run=False, cooldown_sec=10)
    last, kills = run(cfg, float("-inf"), 100.0, log)
    assert (last, kills) == (100.0, [30])
    assert "full avg10=45.5" in lines[0]
    assert "immich (pid 30, 400 MiB" in lines[0]


def test_no_large_victim_kills_nothing(logged):
    lines, log = logged
    cfg = Config(dry_run=False, cooldown_sec=10)
    last, kills = run(cfg, float("-inf"), 100.0, log, procs=PROCS[:1])
    assert (last, kills) == (100.0, [])
    assert "no process" in lines[0]


def test_cooldown_skips_second_kill(logged):
    _, log = logged
    cfg = Config(dry_run=False, cooldown_sec=10)
    last, kills = run(cfg, 100.0, 105.0, log)
    assert (last, kills) == (100.0, [])
    last, kills = run(cfg, 100.0, 110.0, log)
    assert (last, kills) == (110.0, [30])


def test_dry_run_never_kills(logged):
    lines, log = logged
    last, kills = run(Config(), float("-inf"), 1.0, log)
    assert (last, kills) == (1.0, [])
    assert "dry run" in lines[0]
