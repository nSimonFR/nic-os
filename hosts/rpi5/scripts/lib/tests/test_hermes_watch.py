"""Tests for hermes-watch, against an in-memory state.db with the columns it reads."""

import json
import sqlite3

import pytest

from nicos_scripts.hermes import watch

DM, G_ME, G_ALFIE, OLD = "s_dm", "s_g1", "s_g2", "s_old"


def _origin(user, chat_type, chat_name="nSimon"):
    return json.dumps({"user_name": user, "chat_type": chat_type, "chat_name": chat_name})


@pytest.fixture
def db():
    db = sqlite3.connect(":memory:")
    db.executescript(
        """CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, session_key TEXT,
               chat_type TEXT, origin_json TEXT, started_at REAL, ended_at REAL,
               archived INTEGER DEFAULT 0);
           CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT,
               role TEXT, content TEXT, tool_calls TEXT, tool_name TEXT, timestamp REAL,
               display_kind TEXT);"""
    )
    sessions = [
        (OLD, "telegram", "k:dm", "dm", _origin("nSimon", "dm"), 1, 5, 0),
        (DM, "telegram", "k:dm", "dm", _origin("nSimon", "dm"), 10, None, 0),
        (G_ME, "telegram", "k:g:me", "group", _origin("nSimon", "group", "Fam"), 11, None, 0),
        (G_ALFIE, "telegram", "k:g:alf", "group", _origin("Alfie", "group", "Fam"), 12, None, 0),
        ("s_cli", "cli", None, None, None, 13, None, 0),
    ]
    db.executemany("INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?)", sessions)
    return db


def _msg(db, sid, role, content="", tool_calls=None, tool_name=None, kind=None, ts=1_790_000_000):
    db.execute(
        "INSERT INTO messages (session_id, role, content, tool_calls, tool_name, timestamp,"
        " display_kind) VALUES (?,?,?,?,?,?,?)",
        (sid, role, content, tool_calls, tool_name, ts, kind),
    )


def test_resolves_the_newest_open_session_per_key_and_labels_group_senders(db):
    assert watch.current_sessions(db, "dm") == {DM: ("DM", "nSimon")}
    assert watch.current_sessions(db, "group") == {
        G_ME: ("group", "nSimon"),
        G_ALFIE: ("group", "Alfie"),
    }
    assert set(watch.current_sessions(db, "all")) == {DM, G_ME, G_ALFIE}


S = ("DM", "nSimon")


def test_render_hides_noise_and_summarises_tool_calls():
    cfg = watch.Config()
    call = json.dumps([{"function": {"name": "skill_view", "arguments": '{"name":"pdf"}'}}])
    row = lambda role, content="", tc=None, tn=None, kind=None: (  # noqa: E731
        1, DM, role, content, tc, tn, 1_790_000_000, kind
    )
    assert watch.render(row("session_meta", "{}"), S, cfg) == []
    assert watch.render(row("assistant", "interrupted", kind="hidden"), S, cfg) == []
    assert watch.render(row("tool", "{}", tn="skill_view"), S, cfg) == []
    assert watch.render(row("tool", "{}", tn="skill_view"), S, watch.Config(tools=True))
    (line,) = watch.render(row("assistant", "", tc=call), S, cfg)
    assert "⚙ skill_view" in line and '"pdf"' in line
    (line,) = watch.render(row("user", "salut"), S, cfg)
    assert "nSimon ▸ salut" in line and "[DM]" in line
    (line,) = watch.render(row("user", "salut"), S, watch.Config(which="dm"))
    assert "[DM]" not in line


def test_backlog_is_the_last_n_in_order_across_merged_sessions(db):
    for i in range(5):
        _msg(db, G_ME if i % 2 else G_ALFIE, "user", f"m{i}")
    lines = []
    watch.run(watch.Config(which="group", backlog=3, once=True), db, out=lines.append)
    assert [ln.rsplit(" ", 1)[-1] for ln in lines[1:]] == ["m2", "m3", "m4"]


def test_follow_prints_only_new_rows_and_picks_up_a_rotated_session(db):
    _msg(db, DM, "user", "before")
    lines, ticks = [], []

    def sleep(_):
        ticks.append(1)
        if len(ticks) == 1:
            _msg(db, DM, "assistant", "reply")
        elif len(ticks) == 2:
            db.execute("UPDATE sessions SET ended_at = 20 WHERE id = ?", (DM,))
            db.execute(
                "INSERT INTO sessions VALUES ('s_new','telegram','k:dm','dm',?,20,NULL,0)",
                (_origin("nSimon", "dm"),),
            )
            _msg(db, "s_new", "user", "after /new")
        else:
            raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt):
        watch.run(watch.Config(which="dm"), db, out=lines.append, sleep=sleep)
    body = "\n".join(lines)
    assert body.count("before") == 1
    assert "Hermes ▸ reply" in body
    assert "now following DM·nSimon (s_new)" in body
    assert "nSimon ▸ after /new" in body


def test_no_open_session_is_reported_not_crashed(db):
    db.execute("UPDATE sessions SET ended_at = 1")
    lines = []
    assert watch.run(watch.Config(which="dm", once=True), db, out=lines.append) == 1
    assert "no open telegram session" in lines[0]
