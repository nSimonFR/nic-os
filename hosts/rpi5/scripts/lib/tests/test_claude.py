"""The two agent-surface units.

notify_aggregator kept its whole debounce state in four module-level globals, so
the behaviour that matters — quiet window, hard cap, dedup, immediate flush — was
only observable by watching Telegram. boot_resume spawns 70-200 MB bridge workers
on a 3.9 GB box, so its caps and its dry-run default are safety properties.
"""

import json
from pathlib import Path

import pytest

from nicos_scripts.claude import boot_resume as br
from nicos_scripts.claude import context_baseline as cb
from nicos_scripts.claude import notify_aggregator as na

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
    cfg = na.Config(quiet_seconds=quiet, max_seconds=cap, max_lines=max_lines,
                    self_host=self_host, chat_id="1")
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
    assert na.telegram_send(
        na.Config(chat_id="", token_path=str(token)), "x",
        opener=lambda *a, **k: calls.append(a)) is False
    # No token file -> likewise.
    assert na.telegram_send(
        na.Config(chat_id="1", token_path=str(tmp_path / "nope")), "x",
        opener=lambda *a, **k: calls.append(a)) is False
    assert calls == []


def test_a_telegram_failure_is_swallowed(tmp_path):
    token = tmp_path / "tok"
    token.write_text("t\n")

    def boom(*a, **k):
        raise OSError("telegram down")

    assert na.telegram_send(
        na.Config(chat_id="1", token_path=str(token)), "x", opener=boom) is False


def test_the_flusher_tick_can_run_a_single_pass():
    agg, sent, clock = agg_for(quiet=0)
    agg.add("rpi5", "a", "x")
    na.flusher(agg, sleep=lambda _s: None, forever=False)
    assert len(sent) == 1


# ── boot_resume ───────────────────────────────────────────────────────────────


def br_cfg(tmp_path, **kw):
    return br.Config(
        home=tmp_path,
        projects_dir=tmp_path / "projects",
        worktrees_dir=tmp_path / "worktrees",
        snapshot_file=tmp_path / "snapshot.json",
        state_file=tmp_path / "handled.json",
        cred_file=tmp_path / "credentials.json",
        config_dir=tmp_path / "config",
        bridge_dir=str(tmp_path / "nic-os"),
        start_delay=0,
        delay=0,
        **kw,
    )


def test_the_default_is_a_dry_run():
    # Each live reconnect spawns a bridge worker; opting in has to be explicit.
    assert br.Config().dry_run is True
    assert br.Config.from_env({}).dry_run is True
    assert br.Config.from_env({"CRC_DRY_RUN": "0"}).dry_run is False
    assert br.Config.from_env({"CRC_DRY_RUN": "1"}).dry_run is True


def test_the_credentials_come_from_the_bridges_own_config_dir():
    # ~/.claude's copy goes stale; ~/.claude-rc's is the one `claude` refreshes.
    cfg = br.Config.from_env({"HOME": "/home/x"})
    assert cfg.cred_file == Path("/home/x/.claude-rc/.credentials.json")


@pytest.mark.parametrize(
    ("name", "expected"),
    [("bridge-cse_01ABC", "cse_01ABC"), ("/a/b/bridge-cse_XYZ9", "cse_XYZ9"),
     ("worktree-nope", None), ("", None), (None, None)],
)
def test_the_session_id_is_recovered_from_the_worktree_name(name, expected):
    assert br.cse_from_cwd(name) == expected


def test_the_project_slug_matches_claude_codes_own():
    assert br.slug("/home/nsimon/nic-os") == "-home-nsimon-nic-os"
    assert br.slug("/a.b/c_d") == "-a-b-c-d"


def test_the_bridge_pointer_path_mirrors_claude_codes(tmp_path):
    cfg = br_cfg(tmp_path)
    assert br.bridge_pointer_path(cfg) == (
        tmp_path / "config" / "projects" / br.slug(cfg.bridge_dir) / "bridge-pointer.json")


def make_worktree(cfg, cse, age_seconds=0, now=1_000_000.0):
    wt = cfg.worktrees_dir / f"bridge-{cse}"
    wt.mkdir(parents=True)
    import os

    os.utime(wt, (now - age_seconds, now - age_seconds))
    return wt


def test_the_snapshot_records_recent_worktrees_only(tmp_path):
    now = 1_000_000.0
    cfg = br_cfg(tmp_path, recency=86400)
    make_worktree(cfg, "cse_recent", age_seconds=60, now=now)
    make_worktree(cfg, "cse_ancient", age_seconds=90000, now=now)
    (cfg.worktrees_dir / "not-a-session").mkdir()

    records = br.cmd_snapshot(cfg, now=now)
    assert set(records) == {"cse_recent"}
    saved = json.loads(cfg.snapshot_file.read_text())
    assert [s["cseId"] for s in saved["sessions"]] == ["cse_recent"]


def test_the_transcript_mtime_beats_the_worktree_mtime(tmp_path):
    # A reboot leaves an old dir mtime but the transcript marks real activity.
    import os

    now = 1_000_000.0
    cfg = br_cfg(tmp_path, recency=86400)
    wt = make_worktree(cfg, "cse_x", age_seconds=90000, now=now)
    d = cfg.projects_dir / br.slug(wt)
    d.mkdir(parents=True)
    jsonl = d / "uuid.jsonl"
    jsonl.write_text("{}")
    os.utime(jsonl, (now - 30, now - 30))

    records = br.cmd_snapshot(cfg, now=now)
    assert set(records) == {"cse_x"}
    assert records["cse_x"]["lastActive"] == now - 30


def write_snapshot(cfg, sessions, now=1_000_000):
    cfg.snapshot_file.parent.mkdir(parents=True, exist_ok=True)
    cfg.snapshot_file.write_text(json.dumps(
        {"savedAt": int(now), "sessions": sessions}))


def write_creds(cfg, token="tok"):
    cfg.cred_file.parent.mkdir(parents=True, exist_ok=True)
    cfg.cred_file.write_text(json.dumps({"claudeAiOauth": {"accessToken": token}}))


def write_pointer(cfg, env_id="env_1"):
    p = br.bridge_pointer_path(cfg)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"environmentId": env_id}))


class FakeApi:
    """Records reconnect POSTs and answers with a configurable status."""

    def __init__(self, status=200, statuses=None):
        self.status = status
        self.statuses = list(statuses or [])
        self.posts = []

    def __call__(self, req, timeout=None):
        self.posts.append((req.full_url, json.loads(req.data.decode())))
        code = self.statuses.pop(0) if self.statuses else self.status
        if code >= 400:
            import urllib.error

            raise urllib.error.HTTPError(req.full_url, code, "nope", {}, None)
        self.status_code = code
        return type("R", (), {"status": code, "read": lambda self: b""})()


def session(cse, last_active=1_000_000):
    return {"cseId": cse, "cwd": f"/w/bridge-{cse}", "lastActive": last_active}


def test_a_live_run_reconnects_each_recent_session(tmp_path):
    now = 1_000_000
    cfg = br_cfg(tmp_path, dry_run=False)
    write_snapshot(cfg, [session("cse_a", now), session("cse_b", now - 10)])
    write_creds(cfg)
    write_pointer(cfg, "env_9")
    api = FakeApi(200)

    out = br.cmd_resume(cfg, opener=api, sleep=lambda _s: None, now=now,
                        notify=lambda _m: None)
    assert out == {"revived": 2, "stale": 0, "cooldown": 0, "failed": 0}
    assert [body["session_id"] for _url, body in api.posts] == ["cse_a", "cse_b"]
    assert api.posts[0][0].endswith("/v1/environments/env_9/bridge/reconnect")
    # State remembers them, for the cooldown.
    assert set(json.loads(cfg.state_file.read_text())) == {"cse_a:env_9", "cse_b:env_9"}


def test_a_dry_run_reconnects_nothing(tmp_path):
    now = 1_000_000
    cfg = br_cfg(tmp_path)  # dry_run defaults True
    write_snapshot(cfg, [session("cse_a", now)])
    write_creds(cfg)
    write_pointer(cfg)
    api = FakeApi(200)
    out = br.cmd_resume(cfg, opener=api, sleep=lambda _s: None, now=now,
                        notify=lambda _m: None)
    assert out["revived"] == 1  # counted as "would revive"
    assert api.posts == []
    # …and no cooldown state is written, so the real run is not suppressed.
    assert json.loads(cfg.state_file.read_text()) == {}


def test_the_revive_cap_leaves_headroom_under_bridge_capacity(tmp_path):
    now = 1_000_000
    cfg = br_cfg(tmp_path, dry_run=False, max_revive=2)
    write_snapshot(cfg, [session(f"cse_{i}", now - i) for i in range(6)])
    write_creds(cfg)
    write_pointer(cfg)
    api = FakeApi(200)
    out = br.cmd_resume(cfg, opener=api, sleep=lambda _s: None, now=now,
                        notify=lambda _m: None)
    assert out["revived"] == 2
    assert len(api.posts) == 2


def test_the_most_recently_active_sessions_are_revived_first(tmp_path):
    now = 1_000_000
    cfg = br_cfg(tmp_path, dry_run=False, max_revive=1)
    write_snapshot(cfg, [session("cse_old", now - 5000), session("cse_new", now - 5)])
    write_creds(cfg)
    write_pointer(cfg)
    api = FakeApi(200)
    br.cmd_resume(cfg, opener=api, sleep=lambda _s: None, now=now, notify=lambda _m: None)
    assert api.posts[0][1]["session_id"] == "cse_new"


def test_a_stale_session_is_skipped(tmp_path):
    now = 1_000_000
    cfg = br_cfg(tmp_path, dry_run=False, recency=3600)
    write_snapshot(cfg, [session("cse_old", now - 7200)])
    write_creds(cfg)
    write_pointer(cfg)
    api = FakeApi(200)
    out = br.cmd_resume(cfg, opener=api, sleep=lambda _s: None, now=now,
                        notify=lambda _m: None)
    assert (out["revived"], out["stale"]) == (0, 1)
    assert api.posts == []


def test_a_session_revived_moments_ago_is_not_revived_again(tmp_path):
    # Rapid restart loops must not re-spawn the same worker over and over.
    now = 1_000_000
    cfg = br_cfg(tmp_path, dry_run=False, cooldown=600)
    write_snapshot(cfg, [session("cse_a", now)])
    write_creds(cfg)
    write_pointer(cfg, "env_9")
    cfg.state_file.parent.mkdir(parents=True, exist_ok=True)
    cfg.state_file.write_text(json.dumps(
        {"cse_a:env_9": {"cseId": "cse_a", "revivedAt": now - 60}}))
    api = FakeApi(200)
    out = br.cmd_resume(cfg, opener=api, sleep=lambda _s: None, now=now,
                        notify=lambda _m: None)
    assert (out["revived"], out["cooldown"]) == (0, 1)
    assert api.posts == []


def test_the_cooldown_is_scoped_to_the_environment(tmp_path):
    # A new environment means a new bridge; the session genuinely needs re-queuing.
    now = 1_000_000
    cfg = br_cfg(tmp_path, dry_run=False, cooldown=600)
    write_snapshot(cfg, [session("cse_a", now)])
    write_creds(cfg)
    write_pointer(cfg, "env_NEW")
    cfg.state_file.parent.mkdir(parents=True, exist_ok=True)
    cfg.state_file.write_text(json.dumps(
        {"cse_a:env_OLD": {"cseId": "cse_a", "revivedAt": now - 60}}))
    api = FakeApi(200)
    out = br.cmd_resume(cfg, opener=api, sleep=lambda _s: None, now=now,
                        notify=lambda _m: None)
    assert out["revived"] == 1


def test_a_failed_reconnect_is_counted_and_not_remembered(tmp_path):
    now = 1_000_000
    cfg = br_cfg(tmp_path, dry_run=False)
    write_snapshot(cfg, [session("cse_a", now)])
    write_creds(cfg)
    write_pointer(cfg, "env_9")
    api = FakeApi(400)  # "Session does not belong to this environment"
    out = br.cmd_resume(cfg, opener=api, sleep=lambda _s: None, now=now,
                        notify=lambda _m: None)
    assert (out["revived"], out["failed"]) == (0, 1)
    assert json.loads(cfg.state_file.read_text()) == {}


def test_a_session_whose_worktree_is_gone_is_still_reconnected(tmp_path):
    # A graceful bridge stop deletes the worktree but keeps the session resumable;
    # the bridge recreates it from the branch on the reconnected work poll.
    now = 1_000_000
    cfg = br_cfg(tmp_path, dry_run=False)
    write_snapshot(cfg, [{"cseId": "cse_a", "cwd": "/gone/bridge-cse_a",
                          "lastActive": now}])
    write_creds(cfg)
    write_pointer(cfg)
    api = FakeApi(200)
    out = br.cmd_resume(cfg, opener=api, sleep=lambda _s: None, now=now,
                        notify=lambda _m: None)
    assert out["revived"] == 1


def test_an_empty_snapshot_does_nothing(tmp_path, capsys):
    cfg = br_cfg(tmp_path)
    write_snapshot(cfg, [])
    out = br.cmd_resume(cfg, sleep=lambda _s: None, now=1, notify=lambda _m: None)
    assert out == {"revived": 0, "stale": 0, "cooldown": 0, "failed": 0}
    assert "empty snapshot" in capsys.readouterr().out


def test_a_missing_oauth_token_reports_and_stops(tmp_path):
    cfg = br_cfg(tmp_path, dry_run=False)
    write_snapshot(cfg, [session("cse_a")])
    notes = []
    assert br.cmd_resume(cfg, sleep=lambda _s: None, now=1, notify=notes.append) is None
    assert "no OAuth token" in notes[0]


def test_the_environment_falls_back_to_the_listing_when_the_pointer_is_missing(tmp_path):
    cfg = br_cfg(tmp_path)
    write_creds(cfg)
    listing = json.dumps({"data": [
        {"id": "env_old", "name": "rpi5:nic-os:aaa", "created_at": "2026-01-01"},
        {"id": "env_new", "name": "rpi5:nic-os:bbb", "created_at": "2026-06-01"},
        {"id": "env_other", "name": "beast:nic-os:ccc", "created_at": "2026-07-01"},
    ]}).encode()

    def opener(req, timeout=None):
        assert req.get_header("Anthropic-beta") == "environments-2025-11-01"
        assert req.get_header("Authorization") == "Bearer tok"
        return type("R", (), {"read": lambda self: listing})()

    assert br.current_env_id(cfg, "tok", opener=opener) == "env_new"


def test_no_matching_environment_yields_none(tmp_path):
    cfg = br_cfg(tmp_path)
    listing = json.dumps({"data": [{"id": "e", "name": "beast:x:1"}]}).encode()
    assert br.current_env_id(
        cfg, "tok", opener=lambda req, timeout=None: type(
            "R", (), {"read": lambda self: listing})()) is None


def test_the_pointer_wins_over_the_listing(tmp_path):
    cfg = br_cfg(tmp_path)
    write_pointer(cfg, "env_from_pointer")

    def must_not_call(req, timeout=None):
        raise AssertionError("should not hit the API")

    assert br.current_env_id(cfg, "tok", opener=must_not_call) == "env_from_pointer"


def test_the_summary_goes_through_the_shared_sender_in_plain_mode():
    # Session names and worktree paths are not HTML-escaped; asking Telegram to
    # parse them as HTML is how a stray "<" 400s the whole notification.
    calls = []
    br.telegram(br.Config(telegram_send="/nix/store/x/bin/send"), "revived <cse_1>",
                run=lambda argv, **kw: calls.append((argv, kw)))
    argv, kw = calls[0]
    assert argv == ["/nix/store/x/bin/send", "--mode", "plain", "revived <cse_1>"]
    assert kw["check"] is False


def test_no_telegram_when_the_seam_is_not_wired():
    sent = []
    br.telegram(br.Config(telegram_send=""), "hi", run=lambda *a, **k: sent.append(a))
    assert sent == []


def test_an_unknown_subcommand_prints_the_manual(tmp_path, capsys):
    assert br.main(argv=["nonsense"], env={"HOME": str(tmp_path)}) == 2
    assert "boot-resume" in capsys.readouterr().out


# ── memory_sync ───────────────────────────────────────────────────────────────

from nicos_scripts.claude import memory_sync as ms  # noqa: E402


def ms_cfg(tmp_path):
    return ms.Config(
        projects_dir=tmp_path / "projects",
        map_path=tmp_path / "map.json",
        log_path=tmp_path / "log.txt",
        token_path=tmp_path / "token",
    )


class FakeMcp:
    """An in-memory AFFiNE: docs by id, searchable by exact title."""

    def __init__(self, docs=None):
        self.docs = dict(docs or {})  # id -> {title, markdown}
        self.calls = []
        self._next = 0

    def call(self, name, args):
        self.calls.append((name, args))
        if name == "list_workspaces":
            return [{"id": "ws1"}]
        if name == "search_docs":
            return {"results": [
                {"id": did, "title": d["title"]} for did, d in self.docs.items()
                if d["title"] == args["query"]
            ]}
        if name == "create_doc_from_markdown":
            self._next += 1
            did = f"doc{self._next}"
            self.docs[did] = {"title": args["title"], "markdown": args["markdown"],
                              "parent": args.get("parentDocId")}
            return {"docId": did}
        if name == "replace_doc_with_markdown":
            self.docs[args["docId"]]["markdown"] = args["markdown"]
            return {"ok": True}
        raise AssertionError(f"unexpected tool {name}")

    def init(self):
        pass

    def tools(self):
        return [c[0] for c in self.calls]


def memory_file(cfg, project, name, content="body"):
    p = cfg.projects_dir / project / "memory" / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content)
    return p


@pytest.mark.parametrize(
    ("rel", "expected"),
    [
        ("proj/memory/note.md", ("proj", "note.md")),
        ("proj/memory/MEMORY.md", ("proj", "MEMORY.md")),
        ("proj/memory/sub/deep.md", ("proj", "deep.md")),
        ("proj/notes/note.md", None),          # not the memory dir
        ("proj/memory/note.txt", None),        # not markdown
        ("proj/memory", None),                 # too shallow
    ],
)
def test_only_memory_markdown_is_mirrored(tmp_path, rel, expected):
    cfg = ms_cfg(tmp_path)
    assert ms.project_and_file(cfg, cfg.projects_dir / rel) == expected


def test_a_path_outside_the_projects_dir_is_ignored(tmp_path):
    cfg = ms_cfg(tmp_path)
    assert ms.project_and_file(cfg, "/etc/passwd") is None
    assert ms.project_and_file(cfg, tmp_path / "elsewhere/memory/x.md") is None


def test_the_title_comes_from_the_frontmatter_name(tmp_path):
    cfg = ms_cfg(tmp_path)
    p = memory_file(cfg, "proj", "known_issue_x.md",
                    "---\nname: known-issue-x\ndescription: y\n---\n\nbody")
    assert ms.title_for(p, p.read_text()) == "known-issue-x"


def test_the_index_gets_a_readable_title(tmp_path):
    cfg = ms_cfg(tmp_path)
    p = memory_file(cfg, "proj", "MEMORY.md", "# index")
    assert ms.title_for(p, p.read_text()) == "MEMORY (index)"


def test_a_file_without_frontmatter_falls_back_to_its_stem(tmp_path):
    cfg = ms_cfg(tmp_path)
    p = memory_file(cfg, "proj", "loose-note.md", "just text")
    assert ms.title_for(p, p.read_text()) == "loose-note"


def test_a_first_sync_creates_a_child_doc_under_the_parent(tmp_path):
    cfg = ms_cfg(tmp_path)
    p = memory_file(cfg, "proj", "note.md", "---\nname: note\n---\nbody")
    mcp = FakeMcp()
    mapping = ms.sync(cfg, p, "proj", "note.md", client=mcp, log=lambda _m: None)
    parent_id = mapping["parent_doc_id"]
    assert mcp.docs[parent_id]["title"] == "Claude Memory"
    doc_id = mapping["files"]["proj/note.md"]
    assert mcp.docs[doc_id]["parent"] == parent_id
    assert mcp.docs[doc_id]["markdown"] == "---\nname: note\n---\nbody"


def test_a_second_sync_replaces_in_place(tmp_path):
    cfg = ms_cfg(tmp_path)
    p = memory_file(cfg, "proj", "note.md", "v1")
    mcp = FakeMcp()
    first = ms.sync(cfg, p, "proj", "note.md", client=mcp, log=lambda _m: None)
    p.write_text("v2")
    second = ms.sync(cfg, p, "proj", "note.md", client=mcp, log=lambda _m: None)
    assert first["files"] == second["files"]  # same doc, not a new one
    assert mcp.docs[second["files"]["proj/note.md"]]["markdown"] == "v2"
    assert mcp.tools().count("create_doc_from_markdown") == 2  # parent + the doc


def test_two_projects_with_the_same_filename_get_separate_docs(tmp_path):
    # Both projects have a MEMORY.md; namespacing the key is what stops one
    # stomping on the other.
    cfg = ms_cfg(tmp_path)
    a = memory_file(cfg, "proj-a", "MEMORY.md", "a")
    b = memory_file(cfg, "proj-b", "MEMORY.md", "b")
    mcp = FakeMcp()
    ms.sync(cfg, a, "proj-a", "MEMORY.md", client=mcp, log=lambda _m: None)
    mapping = ms.sync(cfg, b, "proj-b", "MEMORY.md", client=mcp, log=lambda _m: None)
    ids = mapping["files"]
    assert ids["proj-a/MEMORY.md"] != ids["proj-b/MEMORY.md"]
    assert mcp.docs[ids["proj-a/MEMORY.md"]]["markdown"] == "a"
    assert mcp.docs[ids["proj-b/MEMORY.md"]]["markdown"] == "b"


def test_a_lost_map_rebinds_to_the_existing_doc_instead_of_duplicating(tmp_path):
    cfg = ms_cfg(tmp_path)
    p = memory_file(cfg, "proj", "note.md", "v1")
    mcp = FakeMcp()
    first = ms.sync(cfg, p, "proj", "note.md", client=mcp, log=lambda _m: None)
    doc_id = first["files"]["proj/note.md"]
    cfg.map_path.unlink()  # lose the map
    again = ms.sync(cfg, p, "proj", "note.md", client=mcp, log=lambda _m: None)
    assert again["files"]["proj/note.md"] == doc_id
    assert len([d for d in mcp.docs.values() if d["title"] == "note"]) == 1


def test_a_title_already_claimed_by_another_project_is_not_reused(tmp_path):
    # Otherwise proj-b's sync would overwrite proj-a's page.
    cfg = ms_cfg(tmp_path)
    a = memory_file(cfg, "proj-a", "note.md", "a")
    b = memory_file(cfg, "proj-b", "note.md", "b")
    mcp = FakeMcp()
    ms.sync(cfg, a, "proj-a", "note.md", client=mcp, log=lambda _m: None)
    mapping = ms.sync(cfg, b, "proj-b", "note.md", client=mcp, log=lambda _m: None)
    assert mapping["files"]["proj-a/note.md"] != mapping["files"]["proj-b/note.md"]
    assert mcp.docs[mapping["files"]["proj-a/note.md"]]["markdown"] == "a"


def test_a_legacy_unnamespaced_key_is_migrated(tmp_path):
    cfg = ms_cfg(tmp_path)
    p = memory_file(cfg, "proj", "note.md", "v2")
    cfg.map_path.write_text(json.dumps({
        "workspace_id": "ws1", "parent_doc_id": "parent",
        "files": {"note.md": "legacy-doc"},
    }))
    mcp = FakeMcp({"legacy-doc": {"title": "note", "markdown": "v1"},
                   "parent": {"title": "Claude Memory", "markdown": ""}})
    mapping = ms.sync(cfg, p, "proj", "note.md", client=mcp, log=lambda _m: None)
    assert mapping["files"] == {"proj/note.md": "legacy-doc"}
    assert mcp.docs["legacy-doc"]["markdown"] == "v2"


def test_the_workspace_and_parent_are_cached_after_the_first_run(tmp_path):
    cfg = ms_cfg(tmp_path)
    p = memory_file(cfg, "proj", "note.md", "v1")
    mcp = FakeMcp()
    ms.sync(cfg, p, "proj", "note.md", client=mcp, log=lambda _m: None)
    mcp.calls.clear()
    ms.sync(cfg, p, "proj", "note.md", client=mcp, log=lambda _m: None)
    assert "list_workspaces" not in mcp.tools()


def test_the_hook_ignores_everything_that_is_not_a_memory_write(tmp_path):
    import io

    cfg_env = {"MEMORY_SYNC_PROJECTS_DIR": str(tmp_path / "projects"),
               "MEMORY_SYNC_MAP_PATH": str(tmp_path / "map.json"),
               "MEMORY_SYNC_LOG_PATH": str(tmp_path / "log.txt")}
    mcp = FakeMcp()
    for payload in (
        {"tool_name": "Bash", "tool_input": {"file_path": "x"}},
        {"tool_name": "Write", "tool_input": {}},
        {"tool_name": "Write", "tool_input": {"file_path": "/etc/hosts"}},
        {"tool_name": "Write"},
        {},
    ):
        assert ms.main(env=cfg_env, stdin=io.StringIO(json.dumps(payload)),
                       client=mcp) == 0
    assert mcp.calls == []


def test_the_hook_never_fails_on_bad_stdin_or_a_broken_mcp(tmp_path):
    import io

    cfg = ms_cfg(tmp_path)
    p = memory_file(cfg, "proj", "note.md", "v1")
    env = {"MEMORY_SYNC_PROJECTS_DIR": str(cfg.projects_dir),
           "MEMORY_SYNC_MAP_PATH": str(cfg.map_path),
           "MEMORY_SYNC_LOG_PATH": str(cfg.log_path)}
    # Garbage on stdin.
    assert ms.main(env=env, stdin=io.StringIO("not json")) == 0

    class Broken:
        def init(self):
            pass

        def call(self, name, args):
            raise RuntimeError("affine down")

    payload = json.dumps({"tool_name": "Write", "tool_input": {"file_path": str(p)}})
    # A dead AFFiNE must not block Claude Code.
    assert ms.main(env=env, stdin=io.StringIO(payload), client=Broken()) == 0
    assert "FAIL" in cfg.log_path.read_text()


def test_the_mcp_client_parses_sse_frames_and_raises_on_errors():
    class Resp:
        def __init__(self, body):
            self.body = body
            self.headers = {"Mcp-Session-Id": "sess1"}

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def read(self):
            return self.body

    frames = [
        b'event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"content":'
        b'[{"text":"[{\\"id\\":\\"ws1\\"}]"}]}}\n\n',
    ]
    seen = []

    def opener(req, timeout=None):
        seen.append(req)
        return Resp(frames[min(len(seen) - 1, len(frames) - 1)])

    client = ms.MCP("http://mcp", "tok", opener=opener)
    assert client.call("list_workspaces", {}) == [{"id": "ws1"}]
    assert seen[0].get_header("Authorization") == "Bearer tok"
    # The session id from the first response is echoed on the next request.
    client.call("list_workspaces", {})
    assert seen[1].get_header("Mcp-session-id") == "sess1"


def test_an_mcp_error_frame_becomes_an_exception():
    class Resp:
        headers = {}

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def read(self):
            return b'data: {"jsonrpc":"2.0","id":1,"error":{"message":"nope"}}\n'

    client = ms.MCP("http://mcp", "tok", opener=lambda req, timeout=None: Resp())
    with pytest.raises(RuntimeError):
        client.call("list_workspaces", {})


def test_a_tool_level_error_surfaces_its_message_not_a_json_parse_error():
    # affine-mcp reports a failed tool as isError with the message in PLAIN TEXT.
    # json.loads() on that raised "Expecting value: line 1 column 1 (char 0)", so for
    # two days the log blamed a parse bug while AFFiNE was really saying the token
    # 0.27.3 had removed no longer authenticated anything.
    class Resp:
        headers = {}

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def read(self):
            return (b'data: {"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":'
                    b'[{"type":"text","text":"You must sign in first to access this '
                    b'resource."}]}}\n')

    client = ms.MCP("http://mcp", "tok", opener=lambda req, timeout=None: Resp())
    with pytest.raises(RuntimeError, match="must sign in first"):
        client.call("search_docs", {})


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
        "message": {"usage": {
            "input_tokens": inp,
            "cache_creation_input_tokens": creation,
            "cache_read_input_tokens": read,
        }},
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
    p = write_session(tmp_path, "proj", "aaaaaaaa-1111", transcript(
        usage_msg(inp=2, creation=134_000, read=190),
    ))
    assert cb.baseline_of(p) == 134_192


def test_the_first_request_wins_not_the_largest(tmp_path):
    # Baseline is a startup property. Later turns are work, and compaction
    # rewrites them — measuring anything but the first request measures usage.
    p = write_session(tmp_path, "proj", "aaaaaaaa-1111", transcript(
        {"type": "user", "message": {"content": "hi"}},
        usage_msg(inp=1, creation=50_000),
        usage_msg(inp=1, read=168_000),
    ))
    assert cb.baseline_of(p) == 50_001


def test_a_half_written_last_line_is_skipped_not_fatal(tmp_path):
    # Transcripts are appended to live, so a partially-flushed final line is
    # normal, not corruption.
    p = tmp_path / "proj" / "aaaaaaaa-1111.jsonl"
    p.parent.mkdir(parents=True)
    p.write_text('{"type":"user"}\n{"type":"assist')
    assert cb.baseline_of(p) is None


def test_a_session_with_no_request_yet_is_not_a_row(tmp_path):
    p = write_session(tmp_path, "proj", "aaaaaaaa-1111", transcript(
        {"type": "user", "message": {"content": "hi"}},
    ))
    assert cb.baseline_of(p) is None


def test_an_unreadable_transcript_is_skipped(tmp_path):
    assert cb.baseline_of(tmp_path / "nope.jsonl") is None


def test_only_sessions_inside_the_lookback_are_judged(tmp_path):
    write_session(tmp_path, "proj", "aaaaaaaa-1111", transcript(usage_msg(creation=9)))
    write_session(tmp_path, "proj", "bbbbbbbb-2222", transcript(usage_msg(creation=8)))
    cfg = cb_cfg(tmp_path, lookback=100)
    ages = {"aaaaaaaa-1111": 50, "bbbbbbbb-2222": 5000}
    rows = cb.scan(cfg, now=10_000,
                   mtime=lambda p: 10_000 - ages[Path(p).stem])
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
    assert "proj/bbbb" not in body          # under threshold, not an offender
    assert "BOTH name forms" in body        # the fix that actually applies


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
    cfg = cb_cfg(tmp_path, alert_cmd="/nix/store/x-telegram-alert", dry_run=False,
                 alert_key="claude-context-baseline", alert_title="T")
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
    cfg_env = {"CTXB_PROJECTS_DIR": str(tmp_path), "CTXB_ALERT": "/x",
               "CTXB_DRY_RUN": "0"}
    calls = []
    lines = []
    assert cb.main(env=cfg_env, now=10_000, mtime=lambda p: 0,
                   run=lambda *a, **k: calls.append(a), log=lines.append) == 0
    assert calls == []
    assert "nothing to judge" in lines[0]


def test_main_reports_the_worst_baseline_either_way(tmp_path):
    write_session(tmp_path, "proj", "aaaaaaaa-1111", transcript(usage_msg(creation=54_000)))
    lines = []
    cb.main(env={"CTXB_PROJECTS_DIR": str(tmp_path)}, now=10_000,
            mtime=lambda p: 10_000, log=lines.append)
    assert lines[0].startswith("OK 1 session(s), worst 54,000")


def test_main_alerts_when_a_session_is_over_the_threshold(tmp_path):
    write_session(tmp_path, "proj", "aaaaaaaa-1111",
                  transcript(usage_msg(inp=2, creation=134_000)))
    calls = []
    lines = []
    cb.main(env={"CTXB_PROJECTS_DIR": str(tmp_path), "CTXB_ALERT": "/x",
                 "CTXB_DRY_RUN": "0"},
            now=10_000, mtime=lambda p: 10_000,
            run=lambda argv, **kw: calls.append(kw["input"]), log=lines.append)
    assert lines[0].startswith("ALERT 1 session(s), worst 134,002")
    assert b"134,002" in calls[0]


def test_the_threshold_and_lookback_come_from_the_environment(tmp_path):
    cfg = cb.Config.from_env({"CTXB_THRESHOLD": "50000", "CTXB_LOOKBACK": "60",
                              "HOME": "/home/x"})
    assert (cfg.threshold, cfg.lookback) == (50_000, 60)
    assert cfg.projects_dir == Path("/home/x/.claude/projects")
    assert cfg.dry_run is True


def test_a_garbage_threshold_falls_back_instead_of_crashing_the_timer():
    assert cb.Config.from_env({"CTXB_THRESHOLD": "lots"}).threshold == cb.DEFAULT_THRESHOLD
