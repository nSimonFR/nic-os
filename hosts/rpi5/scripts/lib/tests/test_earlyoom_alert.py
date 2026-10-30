"""See nicos_scripts/monitoring/earlyoom_alert.py. Journal lines are copied from rpi5."""

import json

from nicos_scripts.monitoring import earlyoom_alert as ea

T0 = 1_793_340_000.0

MEM = "mem avail:   208 of  2423 MiB ( 8.62%), swap free: 5187 of 8049 MiB (64.44%)"
SANDBOX = ('sending SIGTERM to process 378266 uid 1002 "ryot-sandboxd": oom_score 1332, '
           'oom_score_adj 1000, VmRSS 2 MiB, cmdline "/home/ryot/sandboxd/ryot-sandboxd --tier core"')
HERMES = ('sending SIGTERM to process 376981 uid 1001 "hermes": oom_score 816, '
          'oom_score_adj 200, VmRSS 289 MiB, cmdline "/nix/store/x-hermes-agent-env/bin/python3.14 hermes"')
IMMICH = ('sending SIGTERM to process 381147 uid 988 "immich": oom_score 984, '
          'oom_score_adj 0, VmRSS 185 MiB, cmdline "immich      "')
HERMES_KILL = HERMES.replace("SIGTERM", "SIGKILL")


def entry(msg, ts, cursor):
    return json.dumps({"MESSAGE": msg, "__REALTIME_TIMESTAMP": str(int(ts * 1e6)),
                       "__CURSOR": cursor})


class Host:
    """Fakes journalctl and systemctl: a queue of earlyoom batches, unit states."""

    def __init__(self, batches, units=None, active=()):
        self.batches = list(batches)
        self.units = units or {}
        self.active = set(active)
        self.cmds = []

    def __call__(self, cmd):
        self.cmds.append(cmd)
        if cmd[-2:] and cmd[-2] == "is-active":
            return "active\n" if cmd[-1] in self.active else "inactive\n"
        if any(c.startswith("_PID=") for c in cmd):
            pid = int(next(c for c in cmd if c.startswith("_PID="))[5:])
            return json.dumps(self.units[pid]) + "\n" if pid in self.units else ""
        return "\n".join(self.batches.pop(0)) if self.batches else ""


class FakeTG:
    def __init__(self):
        self.sent, self.edits = [], []

    def send(self, text, silent=False, reply_to=None):
        self.sent.append({"text": text, "silent": silent, "reply_to": reply_to})
        return 100 + len(self.sent)

    def edit(self, mid, text):
        self.edits.append((mid, text))
        return True


UNITS = {
    376981: {"_SYSTEMD_UNIT": "user@1001.service", "_SYSTEMD_USER_UNIT": "hermes.service",
             "_UID": "1001"},
    381147: {"_SYSTEMD_UNIT": "immich-server.service", "_UID": "988"},
}


def run_ticks(host, times, state=None, cfg=None):
    cfg = cfg or ea.Config()
    tg = FakeTG()
    state = state if state is not None else {}
    for now in times:
        state = ea.tick(cfg, state, now, host, tg, lambda: [("immich-server.service", 610)],
                        lambda uid: "nsimon", lambda m: None)
    return state, tg


def test_parse_kills_keeps_the_fields_and_the_last_mem_reading():
    entries = [json.loads(entry(MEM, T0, "c1")), json.loads(entry(SANDBOX, T0, "c2")),
               json.loads(entry(HERMES, T0 + 1, "c3"))]
    kills, mem = ea.parse_kills(entries)
    assert [(k["name"], k["pid"], k["adj"], k["rss"]) for k in kills] == [
        ("ryot-sandboxd", 378266, 1000, 2), ("hermes", 376981, 200, 289)]
    assert mem == {"avail": 208, "total": 2423, "pct": 8.62}


def test_unit_of_prefers_the_user_unit_and_skips_scopes():
    cfg = ea.Config()
    host = Host([], units={**UNITS, 5: {"_SYSTEMD_UNIT": "session-3.scope"}})
    k = {"pid": 376981, "uid": 1001, "ts": T0}
    assert ea.unit_of(cfg, k, host) == ("hermes.service", 1001)
    assert ea.unit_of(cfg, {**k, "pid": 381147}, host) == ("immich-server.service", None)
    assert ea.unit_of(cfg, {**k, "pid": 5}, host) == (None, None)
    assert ea.unit_of(cfg, {**k, "pid": 6}, host) == (None, None)


def test_an_episode_is_one_silent_message_that_ends_with_a_recap():
    host = Host([[entry(MEM, T0, "c1"), entry(SANDBOX, T0, "c2"), entry(HERMES, T0 + 1, "c3")],
                 [], []],
                units=UNITS, active={"hermes.service"})
    state, tg = run_ticks(host, [T0 + 60, T0 + 180, T0 + 1 + ea.QUIET_SEC])
    assert len(tg.sent) == 1 and tg.sent[0]["silent"]
    first = tg.sent[0]["text"]
    assert "<code>hermes</code> 289 MiB · hermes.service ↻ back" in first
    assert "<code>ryot-sandboxd</code> ×1, 2 MiB" in first
    assert "mem avail at last kill: 208 of 2423 MiB (8.6%)" in first
    assert "immich-server 610" in first
    assert "✅ ended" in tg.edits[-1][1] and "2 kills" in tg.edits[-1][1]
    assert state["episode"] is None and state["cursor"] == "c3"
    assert ["--after-cursor=c3"] == [c for c in host.cmds[-1] if c.startswith("--after")]


def test_a_victim_still_down_after_the_grace_pings_once():
    host = Host([[entry(HERMES, T0, "c1")], [], [], []], units=UNITS)
    _, tg = run_ticks(host, [T0 + 60, T0 + ea.GRACE_SEC + 1, T0 + ea.GRACE_SEC + 120])
    assert "… restarting" in tg.sent[0]["text"]
    pings = [s for s in tg.sent if s["reply_to"]]
    assert len(pings) == 1 and not pings[0]["silent"]
    assert "hermes.service</code> still down" in pings[0]["text"]
    assert "✗ still down" in tg.edits[-1][1]


def test_a_unit_that_comes_back_late_flips_to_back():
    host = Host([[entry(HERMES, T0, "c1")], []], units=UNITS)
    state, tg = run_ticks(host, [T0 + ea.GRACE_SEC + 1])
    host.active.add("hermes.service")
    run_ticks(host, [T0 + ea.GRACE_SEC + 120], state=state)
    assert state["episode"]["kills"][0]["status"] == "back"


def test_expendable_kills_alone_never_ping():
    batch = [entry(SANDBOX.replace("378266", str(p)), T0 + p % 10, f"c{p}")
             for p in range(10, 20)]
    _, tg = run_ticks(Host([batch, []]), [T0 + 60, T0 + 1000])
    assert len(tg.sent) == 1 and tg.sent[0]["silent"]
    assert "×10" in tg.sent[0]["text"]


def test_a_storm_of_real_kills_pings_once():
    batch = [entry(IMMICH.replace("381147", str(p)), T0 + p, f"c{p}") for p in range(1, 5)]
    _, tg = run_ticks(Host([batch, [], []], active={"immich-server.service"}),
                      [T0 + 60, T0 + 180, T0 + 300])
    storms = [s for s in tg.sent if "storm" in s["text"]]
    assert len(storms) == 1 and storms[0]["reply_to"] == 101


def test_a_sigkill_after_a_sigterm_is_one_kill():
    host = Host([[entry(HERMES, T0, "c1"), entry(HERMES_KILL, T0 + 2, "c2")]],
                units=UNITS, active={"hermes.service"})
    state, _ = run_ticks(host, [T0 + 60])
    assert len(state["episode"]["kills"]) == 1


def test_no_kills_no_message():
    _, tg = run_ticks(Host([[entry(MEM, T0, "c1")]]), [T0 + 60])
    assert tg.sent == [] and tg.edits == []


def test_unchanged_text_is_not_re_edited():
    host = Host([[entry(HERMES, T0, "c1")], [], []], units=UNITS, active={"hermes.service"})
    _, tg = run_ticks(host, [T0 + 60, T0 + 60, T0 + 60])
    assert tg.edits == []


def test_top_units_sums_by_cgroup_leaf(tmp_path):
    for pid, cg, pss in [("1", "0::/system.slice/immich-server.service", 400_000),
                         ("2", "0::/system.slice/immich-server.service", 300_000),
                         ("3", "0::/user.slice/user-1001.slice/user@1001.service/app.slice/hermes.service", 290_000),
                         ("4", "0::/", 0)]:
        d = tmp_path / pid
        d.mkdir()
        (d / "cgroup").write_text(cg + "\n")
        (d / "smaps_rollup").write_text(f"Rss: 1 kB\nPss:   {pss} kB\n")
    (tmp_path / "self").mkdir()
    assert ea.top_units(str(tmp_path)) == [("immich-server.service", 683),
                                           ("hermes.service", 283)]


def test_main_without_telegram_env_only_logs(tmp_path, logged):
    lines, log = logged
    host = Host([[entry(HERMES, T0, "c1")]], units=UNITS, active={"hermes.service"})
    ea.main(env={"STATE_DIRECTORY": str(tmp_path)}, run=host, now=T0 + 60, log=log)
    assert any("hermes" in line for line in lines)
    assert json.loads((tmp_path / "state.json").read_text())["cursor"] == "c1"
