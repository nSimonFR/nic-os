from nicos_scripts.monitoring.psi_oom import Config, full_avg10, on_stall

PRESSURE = (
    "some avg10=61.20 avg60=40.00 avg300=12.00 total=123\n"
    "full avg10=45.50 avg60=30.00 avg300=9.00 total=99\n"
)


def test_config_defaults_to_dry_run():
    assert Config.from_env({}).dry_run is True
    assert Config.from_env({"PSI_OOM_DRY_RUN": "0"}).dry_run is False


def test_trigger_is_in_microseconds():
    cfg = Config.from_env({"PSI_OOM_STALL_MS": "3000", "PSI_OOM_WINDOW_MS": "8000"})
    assert cfg.trigger == "full 3000000 8000000"


def test_full_avg10():
    assert full_avg10(PRESSURE) == 45.5
    assert full_avg10("") is None


def run(cfg, last, now, logged):
    kills = []
    out = on_stall(
        cfg, last, now, read=lambda: PRESSURE, kill=lambda: kills.append(1), log=logged
    )
    return out, kills


def test_stall_kills(logged):
    lines, log = logged
    cfg = Config(dry_run=False, cooldown_sec=10)
    last, kills = run(cfg, float("-inf"), 100.0, log)
    assert (last, kills) == (100.0, [1])
    assert "full avg10=45.5" in lines[0]


def test_cooldown_skips_second_kill(logged):
    _, log = logged
    cfg = Config(dry_run=False, cooldown_sec=10)
    last, kills = run(cfg, 100.0, 105.0, log)
    assert (last, kills) == (100.0, [])
    last, kills = run(cfg, 100.0, 110.0, log)
    assert (last, kills) == (110.0, [1])


def test_dry_run_never_kills(logged):
    lines, log = logged
    last, kills = run(Config(), float("-inf"), 1.0, log)
    assert (last, kills) == (1.0, [])
    assert "dry run" in lines[0]
