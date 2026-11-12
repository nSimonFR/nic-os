from nicos_scripts.monitoring.psi_oom import (
    Cgroup,
    Config,
    Guard,
    Proc,
    full_avg10,
    parse_started,
    parse_status,
    parse_unit,
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
    Proc(10, "ryot-sandboxd", 1000, 1 * MIB, "ryot.service", 0.0),
    Proc(20, ".claude-wrapped", 800, 90 * MIB, "t3code.service", 0.0),
    Proc(30, "immich", 0, 400 * MIB, "immich-server.service", 0.0),
    Proc(40, "sshd", -1000, 900 * MIB, "sshd.service", 0.0),
]


def test_parse_status():
    text = "Name:\tbun\nVmRSS:\t 300 kB\nRssAnon:\t 200 kB\nVmSwap:\t 50 kB\n"
    assert parse_status(text) == ("bun", 250)
    assert parse_status("Name:\tkthreadd\n") is None


def test_parse_unit():
    assert parse_unit("0::/system.slice/sure-web.service\n") == "sure-web.service"
    user = "0::/user.slice/user-1001.slice/user@1001.service/app.slice/hermes.service"
    assert parse_unit(user) == "hermes.service"
    assert parse_unit("0::/system.slice/session-4.scope/x") == "session-4.scope"
    assert parse_unit("0::/\n") == "-"


def test_parse_started():
    stat = "42 (a) b (c) S " + " ".join(["1"] * 18) + " 1234 99\n"
    assert parse_started(stat, 100) == 12.34


def test_pick_victim_by_size_not_adj():
    assert pick_victim(PROCS, 64 * MIB, 99) == (PROCS[2], False)


def test_pick_victim_skips_self_and_small():
    assert pick_victim(PROCS, 64 * MIB, 30) == (PROCS[1], False)
    assert pick_victim(PROCS, 500 * MIB, 99) is None


def test_respawn_is_skipped_for_another_unit():
    respawned = PROCS[2]._replace(started=150.0)
    procs = [PROCS[1], respawned]
    assert pick_victim(procs, 64 * MIB, 99, {"immich-server.service": 100.0}) == (
        PROCS[1],
        False,
    )


def test_process_older_than_its_units_kill_is_no_respawn():
    # Two agent sessions share t3code.service; killing one spares the other no less.
    assert pick_victim(PROCS, 64 * MIB, 99, {"immich-server.service": 100.0}) == (
        PROCS[2],
        False,
    )


def test_respawn_taken_when_nothing_else_qualifies():
    respawned = PROCS[2]._replace(started=150.0)
    assert pick_victim([respawned], 64 * MIB, 99, {"immich-server.service": 100.0}) == (
        respawned,
        True,
    )


def test_scan_procs(tmp_path):
    stat = "7 (bun) S " + " ".join(["1"] * 18) + " 500 0\n"
    for pid, status, adj in [
        ("7", "Name:\tbun\nRssAnon:\t 100 kB\nVmSwap:\t 5 kB\n", "800"),
        ("2", "Name:\tkthreadd\n", "0"),
    ]:
        (tmp_path / pid).mkdir()
        (tmp_path / pid / "status").write_text(status)
        (tmp_path / pid / "oom_score_adj").write_text(adj)
        (tmp_path / pid / "cgroup").write_text("0::/system.slice/bun.service\n")
        (tmp_path / pid / "stat").write_text(stat)
    (tmp_path / "8").mkdir()  # exited mid-scan
    (tmp_path / "self").mkdir()
    assert list(scan_procs(str(tmp_path), ticks=100)) == [
        Proc(7, "bun", 800, 105, "bun.service", 5.0)
    ]


class FakeCgroup:
    def __init__(self, busy=False):
        self.is_busy, self.writes = busy, []

    def busy(self):
        return self.is_busy

    def freeze(self, on):
        self.writes.append(on)


def guard(logged, procs=PROCS, busy=False, **cfg):
    kills = []
    cg = FakeCgroup(busy)
    g = Guard(
        Config(**{"dry_run": False, "cooldown_sec": 10, **cfg}),
        read=lambda: PRESSURE,
        procs=lambda: procs,
        kill=kills.append,
        deferrable=cg,
        log=logged,
    )
    return g, kills, cg


def test_stall_kills_largest(logged):
    lines, log = logged
    g, kills, _ = guard(log)
    g.on_stall(100.0)
    assert kills == [30]
    assert "full avg10=45.5" in lines[0]
    assert "immich-server.service immich (pid 30, 400 MiB" in lines[0]


def test_respawned_unit_is_passed_over(logged):
    lines, log = logged
    procs = list(PROCS)
    g, kills, _ = guard(log, procs=procs)
    g.on_stall(100.0)
    assert kills == [30]
    procs[2] = PROCS[2]._replace(pid=31, started=105.0)  # systemd restarted it
    g.on_stall(110.0)
    assert kills == [30, 20]
    assert "t3code.service" in lines[1]


def test_respawn_window_expires(logged):
    _, log = logged
    procs = list(PROCS)
    g, kills, _ = guard(log, procs=procs, respawn_sec=600)
    g.on_stall(100.0)
    procs[2] = PROCS[2]._replace(pid=31, started=105.0)
    g.on_stall(700.0)
    assert kills == [30, 31]


def test_no_large_victim_kills_nothing(logged):
    lines, log = logged
    g, kills, _ = guard(log, procs=PROCS[:1])
    g.on_stall(100.0)
    assert kills == []
    assert "no process" in lines[0]


def test_cooldown_skips_second_kill(logged):
    _, log = logged
    g, kills, _ = guard(log)
    g.on_stall(100.0)
    g.on_stall(105.0)
    assert kills == [30]
    g.on_stall(110.0)
    assert kills == [30, 30]


def test_dry_run_never_kills_or_freezes(logged):
    lines, log = logged
    g, kills, cg = guard(log, dry_run=True)
    g.on_stall(1.0)
    assert (kills, cg.writes) == ([], [])
    assert "dry run" in lines[0]
    g, kills, cg = guard(log, dry_run=True, busy=True)
    g.on_stall(1.0)
    assert (kills, cg.writes) == ([], [])
    assert "would freeze" in lines[1]


def test_busy_daemon_is_frozen_before_anything_is_killed(logged):
    lines, log = logged
    g, kills, cg = guard(log, busy=True)
    g.on_stall(100.0)
    assert (kills, cg.writes, g.frozen) == ([], [True], True)
    assert "froze nix-daemon" in lines[0]


def test_stall_that_outlasts_the_freeze_kills(logged):
    _, log = logged
    g, kills, cg = guard(log, busy=True)
    g.on_stall(100.0)
    g.on_stall(105.0)  # cooldown
    assert kills == []
    g.on_stall(110.0)
    assert (kills, cg.writes) == ([30], [True])


def test_thaw_after_two_quiet_windows(logged):
    lines, log = logged
    g, _, cg = guard(log, busy=True, window_ms=10000)
    g.on_stall(100.0)
    g.on_quiet(119.0)
    assert cg.writes == [True]
    g.on_quiet(120.0)
    assert (cg.writes, g.frozen) == ([True, False], False)
    assert "thawed" in lines[-1]


def test_idle_daemon_is_not_frozen(logged):
    _, log = logged
    g, kills, cg = guard(log, busy=False)
    g.on_stall(100.0)
    assert (kills, cg.writes) == ([30], [])


def test_cgroup_busy_and_freeze(tmp_path):
    cg = Cgroup(str(tmp_path))
    assert cg.busy() is False  # no cgroup: socket-activated and idle
    (tmp_path / "cgroup.procs").write_text("100\n")
    assert cg.busy() is False  # the daemon alone
    (tmp_path / "cgroup.procs").write_text("100\n200\n")
    assert cg.busy() is True
    cg.freeze(True)
    assert (tmp_path / "cgroup.freeze").read_text() == "1"
    cg.freeze(False)
    assert (tmp_path / "cgroup.freeze").read_text() == "0"
    Cgroup(str(tmp_path / "missing")).freeze(True)  # no error
