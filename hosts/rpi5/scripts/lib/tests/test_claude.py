"""The agent-surface units.

notify_aggregator kept its whole debounce state in four module-level globals, so
the behaviour that matters — quiet window, hard cap, dedup, immediate flush — was
only observable by watching Telegram.
"""

import json
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from conftest import FakeOpener, json_reply

from nicos_scripts.claude import context_baseline as cb
from nicos_scripts.claude import notify_aggregator as na
from nicos_scripts.claude import window_anchor as wa

# ── notify_aggregator ─────────────────────────────────────────────────────────


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds
        return self.t


def agg_for(quiet=300, cap=900, max_lines=40, self_host="rpi5"):
    cfg = na.Config(
        quiet_seconds=quiet,
        max_seconds=cap,
        max_lines=max_lines,
        self_host=self_host,
        chat_id="1",
    )
    sent = []
    clock = Clock()
    return na.Aggregator(cfg, send=sent.append, now=clock), sent, clock


def test_nothing_is_sent_before_the_quiet_window_elapses():
    agg, sent, clock = agg_for(quiet=300)
    agg.add("rpi5", "nic-os", "waiting")
    clock.advance(299)
    assert agg.flush_if_due() is None
    assert sent == []


def test_the_digest_goes_out_once_things_go_quiet():
    agg, sent, clock = agg_for(quiet=300)
    agg.add("rpi5", "nic-os", "waiting")
    clock.advance(300)
    assert agg.flush_if_due() is not None
    assert sent == ["🤖 Claude Code\n📁 nic-os: waiting"]
    # …and the buffer is empty afterwards, so nothing is sent twice.
    assert agg.pending == {}
    assert agg.flush_if_due() is None


def test_each_new_event_resets_the_quiet_timer():
    # A flurry of sessions finishing must collapse into ONE message.
    agg, sent, clock = agg_for(quiet=300)
    agg.add("rpi5", "a", "done")
    clock.advance(299)
    agg.add("rpi5", "b", "done")
    clock.advance(299)
    assert agg.flush_if_due() is None
    clock.advance(1)
    text = agg.flush_if_due()
    assert text.count("📁") == 2
    assert len(sent) == 1


def test_a_never_quiet_fleet_still_gets_a_digest_at_the_hard_cap():
    # Otherwise continuous activity starves the digest forever.
    agg, sent, clock = agg_for(quiet=300, cap=900)
    agg.add("rpi5", "a", "one")
    for _ in range(9):
        clock.advance(100)
        agg.add("rpi5", "a", "one")
        agg.flush_if_due()
    assert len(sent) == 1


def test_repeated_identical_events_are_deduped_with_a_count():
    agg, sent, clock = agg_for(quiet=1)
    for _ in range(3):
        agg.add("rpi5", "nic-os", "waiting")
    clock.advance(1)
    assert agg.flush_if_due() == "🤖 Claude Code\n📁 nic-os: waiting ×3"


def test_an_immediate_event_flushes_the_whole_batch_now():
    # A PushNotification is an explicit "interrupt me now".
    agg, sent, clock = agg_for(quiet=300)
    agg.add("rpi5", "a", "queued")
    agg.add("rpi5", "b", "urgent", immediate=True)
    assert len(sent) == 1
    assert "queued" in sent[0] and "urgent" in sent[0]
    assert agg.pending == {}


def test_a_remote_host_is_named_but_the_local_one_is_not():
    agg, _, _ = agg_for(self_host="rpi5")
    assert agg.format_line("rpi5.tailnet.ts.net", "nic-os", "x") == "📁 nic-os: x"
    assert agg.format_line("BeAsT", "nic-os", "x") == "📁 BeAsT/nic-os: x"


def test_missing_fields_get_readable_placeholders():
    agg, _, _ = agg_for()
    assert agg.format_line("", "", "") == "📁 unknown/unknown: waiting for input"


def test_the_line_count_is_capped_with_an_overflow_marker():
    agg, _, clock = agg_for(quiet=1, max_lines=2)
    for i in range(5):
        agg.add("rpi5", f"p{i}", "done")
    clock.advance(1)
    text = agg.flush_if_due()
    assert text.count("📁") == 2
    assert "… +3 more" in text


def test_an_oversized_digest_is_truncated_to_telegrams_limit():
    agg, _, clock = agg_for(quiet=1, max_lines=1000)
    for i in range(500):
        agg.add("rpi5", f"project-{i}", "x" * 40)
    clock.advance(1)
    text = agg.flush_if_due()
    assert len(text) <= na.TELEGRAM_LIMIT + len("\n… (truncated)")
    assert text.endswith("… (truncated)")


def test_an_empty_buffer_is_never_due():
    agg, sent, clock = agg_for(quiet=0)
    assert agg.due() is False
    assert agg.flush_if_due() is None
    assert sent == []


def test_no_send_without_a_token_or_a_chat_id(tmp_path):
    token = tmp_path / "tok"
    token.write_text("t\n")
    calls = []
    # No chat id configured -> nothing leaves the box.
    assert (
        na.telegram_send(
            na.Config(chat_id="", token_path=str(token)),
            "x",
            opener=lambda *a, **k: calls.append(a),
        )
        is None
    )
    # No token file -> likewise.
    assert (
        na.telegram_send(
            na.Config(chat_id="1", token_path=str(tmp_path / "nope")),
            "x",
            opener=lambda *a, **k: calls.append(a),
        )
        is None
    )
    assert calls == []


def test_a_telegram_failure_is_swallowed(tmp_path):
    token = tmp_path / "tok"
    token.write_text("t\n")

    def boom(*a, **k):
        raise OSError("telegram down")

    assert (
        na.telegram_send(
            na.Config(chat_id="1", token_path=str(token)), "x", opener=boom
        )
        is None
    )


def test_the_flusher_tick_can_run_a_single_pass():
    agg, sent, clock = agg_for(quiet=0)
    agg.add("rpi5", "a", "x")
    na.flusher(agg, sleep=lambda _s: None, forever=False)
    assert len(sent) == 1


class Poster:
    """send/edit recorders: message ids from 100, edits can be made to fail."""

    def __init__(self):
        self.sent, self.edits, self.edit_ok = [], [], True

    def send(self, text):
        self.sent.append(text)
        return 100 + len(self.sent)

    def edit(self, mid, text):
        self.edits.append((mid, text))
        return self.edit_ok


def rolling_agg(roll=3600):
    cfg = na.Config(
        quiet_seconds=1,
        max_seconds=900,
        self_host="rpi5",
        chat_id="1",
        roll_seconds=roll,
    )
    tg, clock = Poster(), Clock()
    return na.Aggregator(cfg, send=tg.send, edit=tg.edit, now=clock), tg, clock


def test_a_digest_within_the_roll_window_edits_the_previous_message():
    agg, tg, clock = rolling_agg()
    agg.add("rpi5", "a", "done")
    clock.advance(1)
    agg.flush_if_due()
    clock.advance(600)
    agg.add("rpi5", "a", "done")
    agg.add("rpi5", "b", "waiting")
    clock.advance(1)
    agg.flush_if_due()
    assert len(tg.sent) == 1
    mid, text = tg.edits[-1]
    assert mid == 101
    assert "📁 a: done ×2" in text and "📁 b: waiting" in text and "↻ updated" in text


def test_after_the_roll_window_a_new_message_is_sent():
    agg, tg, clock = rolling_agg(roll=3600)
    agg.add("rpi5", "a", "done")
    clock.advance(1)
    agg.flush_if_due()
    clock.advance(3600)
    agg.add("rpi5", "b", "done")
    clock.advance(1)
    agg.flush_if_due()
    assert len(tg.sent) == 2 and tg.edits == []
    assert "📁 a" not in tg.sent[1]


def test_an_immediate_event_always_sends_a_new_message():
    agg, tg, clock = rolling_agg()
    agg.add("rpi5", "a", "done")
    clock.advance(1)
    agg.flush_if_due()
    agg.add("rpi5", "b", "look at this", immediate=True)
    assert len(tg.sent) == 2 and tg.edits == []


def test_a_failed_edit_falls_back_to_a_new_message():
    agg, tg, clock = rolling_agg()
    agg.add("rpi5", "a", "done")
    clock.advance(1)
    agg.flush_if_due()
    tg.edit_ok = False
    agg.add("rpi5", "b", "done")
    clock.advance(1)
    agg.flush_if_due()
    assert len(tg.sent) == 2 and "📁 b: done" in tg.sent[1]


def test_send_returns_the_message_id(tmp_path):
    token = tmp_path / "tok"
    token.write_text("t\n")

    class Resp:
        def read(self):
            return b'{"ok": true, "result": {"message_id": 42}}'

    cfg = na.Config(chat_id="1", token_path=str(token))
    assert na.telegram_send(cfg, "x", opener=lambda *a, **k: Resp()) == 42


# ── context_baseline ──────────────────────────────────────────────────────────
#
# The regression this guards against was invisible: no unit failed, nothing in
# the repo changed, and the only symptom was sessions compacting. So the tests
# that matter are the ones pinning the *measurement* (which counters, which
# message) and the alert contract (empty body = resolved, and never resolving on
# no evidence).


def cb_cfg(tmp_path, **kw):
    return cb.Config(projects_dir=tmp_path, **kw)


def transcript(*objs):
    return "\n".join(json.dumps(o) for o in objs) + "\n"


def usage_msg(inp=0, creation=0, read=0):
    return {
        "type": "assistant",
        "message": {
            "usage": {
                "input_tokens": inp,
                "cache_creation_input_tokens": creation,
                "cache_read_input_tokens": read,
            }
        },
    }


def write_session(tmp_path, project, uuid, text):
    d = tmp_path / project
    d.mkdir(parents=True, exist_ok=True)
    p = d / f"{uuid}.jsonl"
    p.write_text(text)
    return p


def test_the_baseline_sums_all_three_input_counters(tmp_path):
    # 134k bridge sessions were ~2 input + ~134k cache_creation: reading
    # input_tokens alone reports "2" and the alarm never fires.
    p = write_session(
        tmp_path,
        "proj",
        "aaaaaaaa-1111",
        transcript(
            usage_msg(inp=2, creation=134_000, read=190),
        ),
    )
    assert cb.baseline_of(p) == 134_192


def test_the_first_request_wins_not_the_largest(tmp_path):
    # Baseline is a startup property. Later turns are work, and compaction
    # rewrites them — measuring anything but the first request measures usage.
    p = write_session(
        tmp_path,
        "proj",
        "aaaaaaaa-1111",
        transcript(
            {"type": "user", "message": {"content": "hi"}},
            usage_msg(inp=1, creation=50_000),
            usage_msg(inp=1, read=168_000),
        ),
    )
    assert cb.baseline_of(p) == 50_001


def test_a_half_written_last_line_is_skipped_not_fatal(tmp_path):
    # Transcripts are appended to live, so a partially-flushed final line is
    # normal, not corruption.
    p = tmp_path / "proj" / "aaaaaaaa-1111.jsonl"
    p.parent.mkdir(parents=True)
    p.write_text('{"type":"user"}\n{"type":"assist')
    assert cb.baseline_of(p) is None


def test_a_session_with_no_request_yet_is_not_a_row(tmp_path):
    p = write_session(
        tmp_path,
        "proj",
        "aaaaaaaa-1111",
        transcript(
            {"type": "user", "message": {"content": "hi"}},
        ),
    )
    assert cb.baseline_of(p) is None


def test_an_unreadable_transcript_is_skipped(tmp_path):
    assert cb.baseline_of(tmp_path / "nope.jsonl") is None


def test_only_sessions_inside_the_lookback_are_judged(tmp_path):
    write_session(tmp_path, "proj", "aaaaaaaa-1111", transcript(usage_msg(creation=9)))
    write_session(tmp_path, "proj", "bbbbbbbb-2222", transcript(usage_msg(creation=8)))
    cfg = cb_cfg(tmp_path, lookback=100)
    ages = {"aaaaaaaa-1111": 50, "bbbbbbbb-2222": 5000}
    rows = cb.scan(cfg, now=10_000, mtime=lambda p: 10_000 - ages[Path(p).stem])
    assert [r[1] for r in rows] == ["proj/aaaaaaaa"]


def test_rows_come_back_worst_first(tmp_path):
    write_session(tmp_path, "proj", "aaaaaaaa-1111", transcript(usage_msg(creation=10)))
    write_session(tmp_path, "proj", "bbbbbbbb-2222", transcript(usage_msg(creation=90)))
    rows = cb.scan(cb_cfg(tmp_path), now=10_000, mtime=lambda p: 10_000)
    assert [r[0] for r in rows] == [90, 10]


def test_the_label_names_the_project_dir_and_the_session(tmp_path):
    p = write_session(tmp_path, "-home-nsimon-nic-os", "6dc4d848-efbf", "")
    assert cb.label_of(p, tmp_path) == "-home-nsimon-nic-os/6dc4d848"


def test_a_body_is_empty_when_every_session_is_under_the_threshold(tmp_path):
    cfg = cb_cfg(tmp_path, threshold=100_000)
    assert cb.build_body(cfg, [(54_000, "proj/aaaa", "p")]) == ""


def test_the_body_lists_the_offenders_and_says_what_to_do(tmp_path):
    cfg = cb_cfg(tmp_path, threshold=100_000)
    body = cb.build_body(cfg, [(134_198, "proj/aaaa", "p"), (50_000, "proj/bbbb", "q")])
    assert "134,198" in body and "proj/aaaa" in body
    assert "proj/bbbb" not in body  # under threshold, not an offender
    assert "BOTH name forms" in body  # the fix that actually applies


def test_the_threshold_is_inclusive(tmp_path):
    cfg = cb_cfg(tmp_path, threshold=100_000)
    assert cb.build_body(cfg, [(100_000, "proj/aaaa", "p")]) != ""


def test_the_offender_list_is_capped_with_an_overflow_marker(tmp_path):
    cfg = cb_cfg(tmp_path, threshold=10, max_lines=2)
    rows = [(100 - i, f"proj/{i}", "p") for i in range(5)]
    body = cb.build_body(cfg, rows)
    assert "… +3 more" in body


def test_the_default_is_a_dry_run_so_nothing_is_ever_sent_by_accident(tmp_path):
    cfg = cb_cfg(tmp_path, alert_cmd="/bin/true")
    calls = []
    assert cb.send_alert(cfg, "body", run=lambda *a, **k: calls.append(a)) is False
    assert calls == []


def test_an_armed_run_pipes_the_body_to_the_keyed_alerter(tmp_path):
    cfg = cb_cfg(
        tmp_path,
        alert_cmd="/nix/store/x-telegram-alert",
        dry_run=False,
        alert_key="claude-context-baseline",
        alert_title="T",
    )
    calls = []

    def run(argv, **kw):
        calls.append((argv, kw["input"]))

    assert cb.send_alert(cfg, "over budget", run=run) is True
    argv, stdin = calls[0]
    assert argv == ["/nix/store/x-telegram-alert", "claude-context-baseline", "T"]
    assert stdin == b"over budget"


def test_an_empty_body_still_reaches_the_alerter_to_resolve_it(tmp_path):
    # The alerter's resolve path IS the empty body. Short-circuiting on "nothing
    # to report" would leave every alert stuck open forever.
    cfg = cb_cfg(tmp_path, alert_cmd="/x", dry_run=False)
    calls = []
    cb.send_alert(cfg, "", run=lambda argv, **kw: calls.append(kw["input"]))
    assert calls == [b""]


def test_no_alert_command_means_journal_only(tmp_path):
    cfg = cb_cfg(tmp_path, dry_run=False)
    calls = []
    assert cb.send_alert(cfg, "x", run=lambda *a, **k: calls.append(a)) is False
    assert calls == []


def test_an_alerter_failure_is_swallowed(tmp_path):
    cfg = cb_cfg(tmp_path, alert_cmd="/x", dry_run=False)
    lines = []

    def boom(*a, **k):
        raise OSError("no such file")

    assert cb.send_alert(cfg, "x", run=boom, log=lines.append) is False
    assert "alert failed" in lines[0]


def test_a_quiet_window_does_not_resolve_an_open_alert(tmp_path):
    # No sessions started is no evidence. Sending an empty body here would clear
    # a real alert overnight and re-open it every morning.
    cfg_env = {
        "CTXB_PROJECTS_DIR": str(tmp_path),
        "CTXB_ALERT": "/x",
        "CTXB_DRY_RUN": "0",
    }
    calls = []
    lines = []
    assert (
        cb.main(
            env=cfg_env,
            now=10_000,
            mtime=lambda p: 0,
            run=lambda *a, **k: calls.append(a),
            log=lines.append,
        )
        == 0
    )
    assert calls == []
    assert "nothing to judge" in lines[0]


def test_main_reports_the_worst_baseline_either_way(tmp_path):
    write_session(
        tmp_path, "proj", "aaaaaaaa-1111", transcript(usage_msg(creation=54_000))
    )
    lines = []
    cb.main(
        env={"CTXB_PROJECTS_DIR": str(tmp_path)},
        now=10_000,
        mtime=lambda p: 10_000,
        log=lines.append,
    )
    assert lines[0].startswith("OK 1 session(s), worst 54,000")


def test_main_alerts_when_a_session_is_over_the_threshold(tmp_path):
    write_session(
        tmp_path,
        "proj",
        "aaaaaaaa-1111",
        transcript(usage_msg(inp=2, creation=134_000)),
    )
    calls = []
    lines = []
    cb.main(
        env={
            "CTXB_PROJECTS_DIR": str(tmp_path),
            "CTXB_ALERT": "/x",
            "CTXB_DRY_RUN": "0",
        },
        now=10_000,
        mtime=lambda p: 10_000,
        run=lambda argv, **kw: calls.append(kw["input"]),
        log=lines.append,
    )
    assert lines[0].startswith("ALERT 1 session(s), worst 134,002")
    assert b"134,002" in calls[0]


def test_the_threshold_and_lookback_come_from_the_environment(tmp_path):
    cfg = cb.Config.from_env(
        {"CTXB_THRESHOLD": "50000", "CTXB_LOOKBACK": "60", "HOME": "/home/x"}
    )
    assert (cfg.threshold, cfg.lookback) == (50_000, 60)
    assert cfg.projects_dir == Path("/home/x/.claude/projects")
    assert cfg.dry_run is True


def test_a_garbage_threshold_falls_back_instead_of_crashing_the_timer():
    assert (
        cb.Config.from_env({"CTXB_THRESHOLD": "lots"}).threshold == cb.DEFAULT_THRESHOLD
    )


# ── window_anchor ─────────────────────────────────────────────────────────────

PARIS = timezone(timedelta(hours=2))


def at(hh, mm=0):
    return datetime(2026, 10, 1, hh, mm, tzinfo=PARIS)


def usage(reset=None):
    return json_reply(
        {
            "five_hour": {
                "utilization": 18.0,
                "resets_at": reset.isoformat() if reset else None,
            }
        }
    )


def anchor_env(tmp_path, **extra):
    tok = tmp_path / "token"
    tok.write_text("tok\n")
    return {"ANCHOR_TOKEN_FILE": str(tok), "ANCHOR_DRY_RUN": "0", **extra}


def claude_result(models=("claude-sonnet-5",), is_error=False):
    return json.dumps({"is_error": is_error, "modelUsage": {m: {} for m in models}})


class Ran:
    def __init__(self, code=0, stdout=None):
        self.argvs, self.code = [], code
        self.stdout = claude_result() if stdout is None else stdout

    def __call__(self, argv, **kw):
        self.argvs.append(argv)
        return subprocess.CompletedProcess(argv, self.code, self.stdout, "")


def test_no_open_window_pings_right_away(tmp_path):
    ran, slept = Ran(), []
    opener = FakeOpener([usage(None), usage(at(12))])
    assert (
        wa.main(
            env=anchor_env(tmp_path),
            clock=lambda: at(7),
            opener=opener,
            run=ran,
            sleep=slept.append,
            log=lambda m: None,
        )
        == 0
    )
    assert slept == [] and len(ran.argvs) == 1
    assert ran.argvs[0][ran.argvs[0].index("--model") + 1] == "sonnet"


def test_an_open_window_is_chained_one_slack_after_its_reset(tmp_path):
    ran, slept = Ran(), []
    opener = FakeOpener([usage(at(8, 10)), usage(at(13, 11))])
    wa.main(
        env=anchor_env(tmp_path),
        clock=lambda: at(7),
        opener=opener,
        run=ran,
        sleep=slept.append,
        log=lambda m: None,
    )
    assert slept == [70 * 60 + 60] and len(ran.argvs) == 1


def test_a_reset_after_day_end_is_not_chained(tmp_path):
    ran, lines = Ran(), []
    opener = FakeOpener([usage(at(21, 52))])
    assert (
        wa.main(
            env=anchor_env(tmp_path),
            clock=lambda: at(17),
            opener=opener,
            run=ran,
            sleep=lambda s: None,
            log=lines.append,
        )
        == 0
    )
    assert ran.argvs == [] and lines[0].startswith("skip:")


def test_a_night_catch_up_run_does_not_ping():
    cfg = wa.Config()
    assert wa.plan(cfg, at(3), None)[0] is None


def test_unreadable_usage_still_pings(tmp_path):
    ran = Ran()
    env = anchor_env(tmp_path, ANCHOR_TOKEN_FILE=str(tmp_path / "missing"))
    assert (
        wa.main(
            env=env,
            clock=lambda: at(12),
            opener=FakeOpener(),
            run=ran,
            sleep=lambda s: None,
            log=lambda m: None,
        )
        == 0
    )
    assert len(ran.argvs) == 1


def test_the_ping_is_confirmed_without_rereading_usage(tmp_path):
    opener = FakeOpener([usage(None)])
    assert (
        wa.main(
            env=anchor_env(tmp_path),
            clock=lambda: at(7),
            opener=opener,
            run=Ran(),
            sleep=lambda s: None,
            log=lambda m: None,
        )
        == 0
    )
    assert len(opener.requests) == 1


@pytest.mark.parametrize(
    "stdout",
    [
        claude_result(models=("asale-codex",)),
        claude_result(is_error=True),
        claude_result(models=()),
        "not json",
    ],
)
def test_a_ping_that_does_not_reach_anthropic_fails_the_unit(tmp_path, stdout):
    assert (
        wa.main(
            env=anchor_env(tmp_path),
            clock=lambda: at(7),
            opener=FakeOpener([usage(None)]),
            run=Ran(stdout=stdout),
            sleep=lambda s: None,
            log=lambda m: None,
        )
        == 1
    )


def test_the_usage_request_carries_the_oauth_beta_header(tmp_path):
    opener = FakeOpener([usage(None)])
    wa.fetch_reset(wa.Config.from_env(anchor_env(tmp_path)), opener=opener)
    assert opener.last.get_header("Authorization") == "Bearer tok"
    assert opener.last.get_header("Anthropic-beta") == "oauth-2025-04-20"


def test_the_anchor_defaults_to_a_dry_run(tmp_path):
    ran = Ran()
    env = anchor_env(tmp_path)
    del env["ANCHOR_DRY_RUN"]
    wa.main(
        env=env,
        clock=lambda: at(7),
        opener=FakeOpener([usage(None)]),
        run=ran,
        sleep=lambda s: None,
        log=lambda m: None,
    )
    assert ran.argvs == []


def test_a_dry_run_never_sleeps_until_the_reset(tmp_path):
    slept = []
    env = anchor_env(tmp_path, ANCHOR_DRY_RUN="1")
    wa.main(
        env=env,
        clock=lambda: at(14),
        opener=FakeOpener([usage(at(18, 40))]),
        run=Ran(),
        sleep=slept.append,
        log=lambda m: None,
    )
    assert slept == []
