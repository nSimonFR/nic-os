"""t3-settle-retro: which settles get a review, and that a review stays read-only.

The DB is a real SQLite file with the slice of T3's schema the query reads, so a
column rename upstream fails here rather than silently matching nothing.
"""

import json
import sqlite3
import subprocess

from nicos_scripts.claude import settle_retro as sr


def make_db(path, threads):
    con = sqlite3.connect(path)
    con.executescript("""
        CREATE TABLE projection_projects (project_id TEXT, title TEXT, workspace_root TEXT);
        CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT, project_id TEXT,
            title TEXT, deleted_at TEXT, payload_json TEXT);
        CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT,
            thread_id TEXT, provider TEXT, provider_session_id TEXT, updated_at TEXT,
            payload_json TEXT);
        CREATE TABLE orchestration_v2_projection_provider_sessions (provider_session_id TEXT,
            payload_json TEXT);
        CREATE TABLE orchestration_v2_projection_runs (run_id TEXT, thread_id TEXT);
        INSERT INTO projection_projects VALUES ('p1', 'nic-os', '/repo');
    """)
    for t in threads:
        tid = t["id"]
        con.execute("INSERT INTO orchestration_v2_projection_threads VALUES (?,?,?,?,?)", (
            tid, "p1", t.get("title", "fix it"), t.get("deleted"), json.dumps({
                "branch": "br", "worktreePath": t.get("worktree", "/wt"),
                "settledAt": t.get("settled")})))
        for n, (provider, session) in enumerate(t.get("sessions", [("claudeAgent", "sess-" + tid)])):
            con.execute(
                "INSERT INTO orchestration_v2_projection_provider_threads VALUES (?,?,?,?,?,?)",
                (f"pt-{tid}-{n}", tid, provider, f"ps-{tid}-{n}", f"2026-10-05T0{n}:00:00Z",
                 json.dumps({"nativeThreadRef": {"nativeId": session}})))
            if "cwd" in t:
                con.execute("INSERT INTO orchestration_v2_projection_provider_sessions VALUES (?,?)",
                            (f"ps-{tid}-{n}", json.dumps({"cwd": t["cwd"]})))
        con.executemany("INSERT INTO orchestration_v2_projection_runs VALUES (?,?)",
                        [(f"{tid}-r{i}", tid) for i in range(t.get("turns", 5))])
    con.commit()
    con.close()


def env_for(tmp_path, **extra):
    return {"HOME": str(tmp_path), "RETRO_T3_DB": str(tmp_path / "t3.sqlite"),
            "RETRO_DIR": str(tmp_path / "retros"), **extra}


class FakeClaude:
    def __init__(self, result="1. **Navigation** — add a pointer.", returncode=0):
        self.calls = []
        self.result, self.returncode = result, returncode

    def __call__(self, argv, **kw):
        self.calls.append((argv, kw))
        out = json.dumps({"result": self.result, "is_error": False, "total_cost_usd": 0.31})
        return subprocess.CompletedProcess(argv, self.returncode, out, "")


def seed(tmp_path, ledger):
    d = tmp_path / "retros"
    d.mkdir(exist_ok=True)
    (d / ".state.json").write_text(json.dumps(ledger))


def test_only_settled_live_claude_threads_are_read(tmp_path):
    make_db(tmp_path / "t3.sqlite", [
        {"id": "a", "settled": "2026-10-05T10:00:00Z"},
        {"id": "b"},                                                  # not settled
        {"id": "c", "settled": "2026-10-05T11:00:00Z", "deleted": "x"},
        {"id": "d", "settled": "2026-10-05T12:00:00Z", "sessions": [("codex", "x")]},
        {"id": "e", "settled": "2026-10-05T13:00:00Z", "sessions": []},  # imported, never resumed
    ])
    got = sr.settled_threads(tmp_path / "t3.sqlite")
    assert [t.thread_id for t in got] == ["a"]
    assert got[0].session_id == "sess-a" and got[0].cwd == "/wt" and got[0].project == "nic-os"
    assert got[0].turns == 5


def test_the_latest_claude_session_is_forked_where_it_lives(tmp_path):
    make_db(tmp_path / "t3.sqlite", [{
        "id": "a", "settled": "2026-10-05T10:00:00Z", "cwd": "/other-wt",
        "sessions": [("claudeAgent", "old"), ("codex", "cx"), ("claudeAgent", "new")],
    }])
    [t] = sr.settled_threads(tmp_path / "t3.sqlite")
    assert (t.session_id, t.cwd) == ("new", "/other-wt")


def test_due_skips_short_threads_and_reviews_a_resettle_only_after_more_turns():
    t = lambda tid, turns: sr.Thread(tid, "x", "", "/wt", "2026", "p", "s", turns)  # noqa: E731
    ledger = {"old": {"turns": 5}, "grown": {"turns": 5}}
    picked = sr.due([t("short", 2), t("old", 5), t("grown", 8), t("new", 3)], ledger, 3)
    assert [x.thread_id for x in picked] == ["grown", "new"]


def test_the_first_run_records_existing_settles_without_reviewing(tmp_path):
    make_db(tmp_path / "t3.sqlite", [{"id": "a", "settled": "2026-10-05T10:00:00Z"}])
    claude = FakeClaude()
    assert sr.main(env_for(tmp_path, RETRO_DRY_RUN="0"), run=claude, log=lambda m: None) == 0
    assert claude.calls == []
    assert json.loads((tmp_path / "retros/.state.json").read_text())["a"]["turns"] == 5


def test_dry_run_is_the_default_and_spends_nothing(tmp_path):
    make_db(tmp_path / "t3.sqlite", [{"id": "a", "settled": "2026-10-05T10:00:00Z"}])
    seed(tmp_path, {})
    claude = FakeClaude()
    sr.main(env_for(tmp_path), run=claude, isdir=lambda p: True, log=lambda m: None)
    assert claude.calls == []
    assert json.loads((tmp_path / "retros/.state.json").read_text()) == {}


def test_a_review_forks_read_only_in_the_thread_cwd_and_writes_markdown(tmp_path):
    make_db(tmp_path / "t3.sqlite", [{"id": "a1b2c3d4e5", "title": "Fix: sync!",
                                      "settled": "2026-10-05T10:00:00Z"}])
    seed(tmp_path, {})
    claude = FakeClaude()
    rc = sr.main(env_for(tmp_path, RETRO_DRY_RUN="0"), run=claude,
                 isdir=lambda p: True, log=lambda m: None)
    assert rc == 0
    argv, kw = claude.calls[0]
    assert kw["cwd"] == "/wt" and kw["input"].startswith("/mattpocock-skills:retro")
    for flag in ("--fork-session", "--no-session-persistence"):
        assert flag in argv
    assert argv[argv.index("--resume") + 1] == "sess-a1b2c3d4e5"
    assert argv[argv.index("--permission-mode") + 1] == "plan"
    assert argv[argv.index("--tools") + 1] == "Read,Grep,Glob,Skill"
    md = (tmp_path / "retros/2026-10-05-nic-os-fix-sync-a1b2c3d4.md").read_text()
    assert md.startswith("# Retro — Fix: sync!") and "$0.31" in md and "add a pointer" in md


def test_a_failed_review_is_recorded_so_it_is_not_retried_every_tick(tmp_path):
    make_db(tmp_path / "t3.sqlite", [{"id": "a", "settled": "2026-10-05T10:00:00Z"}])
    seed(tmp_path, {})
    claude = FakeClaude(returncode=1)
    env = env_for(tmp_path, RETRO_DRY_RUN="0")
    assert sr.main(env, run=claude, isdir=lambda p: True, log=lambda m: None) == 1
    assert sr.main(env, run=claude, isdir=lambda p: True, log=lambda m: None) == 0
    assert len(claude.calls) == 1
    assert json.loads((tmp_path / "retros/.state.json").read_text())["a"]["ok"] is False


def test_a_vanished_worktree_is_skipped_without_calling_claude(tmp_path):
    make_db(tmp_path / "t3.sqlite", [{"id": "a", "settled": "2026-10-05T10:00:00Z"}])
    seed(tmp_path, {})
    claude = FakeClaude()
    sr.main(env_for(tmp_path, RETRO_DRY_RUN="0"), run=claude,
            isdir=lambda p: False, log=lambda m: None)
    assert claude.calls == []


def test_max_per_run_bounds_the_spend(tmp_path):
    make_db(tmp_path / "t3.sqlite", [
        {"id": i, "settled": f"2026-10-05T1{i}:00:00Z"} for i in "123"])
    seed(tmp_path, {})
    claude = FakeClaude()
    sr.main(env_for(tmp_path, RETRO_DRY_RUN="0", RETRO_MAX_PER_RUN="2"), run=claude,
            isdir=lambda p: True, log=lambda m: None)
    assert len(claude.calls) == 2
