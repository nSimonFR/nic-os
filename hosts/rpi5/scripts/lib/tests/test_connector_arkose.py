import json

from nicos_scripts.connectors import arkose as mod

DAY = 86400
NOW = 1_800_000_000.0


def session(sid, days_ago, tops=0, closed=True):
    return {"_id": sid, "startDate": {"$date": (NOW - days_ago * DAY) * 1000}, "endDate": None,
            "isClosed": closed, "isEmpty": tops == 0, "tops": tops, "flashs": 0, "tried": 0,
            "retops": 0, "gym": "arkose/chevaleret", "userAvatars": {"url": None},
            "bestTop": {"boulderId": "b", "picture": {"id": "p"}}}


class FakeServer:
    """Scripted DDP peer: answers each method from `handlers`, pings once."""

    def __init__(self, handlers, user="U1"):
        self.handlers = {"login": lambda p: {"id": user, "token": "T", "type": "resume"}, **handlers}
        self.queue = []
        self.calls = []
        self.closed = False

    def send(self, text):
        m = json.loads(text)
        if m["msg"] == "connect":
            self.queue += [{"msg": "ping"}, {"msg": "connected", "session": "s"}]
        elif m["msg"] == "method":
            self.calls.append((m["method"], m["params"][0]))
            out = self.handlers[m["method"]](m["params"][0])
            reply = {"msg": "result", "id": m["id"]}
            reply.update({"error": out.args[0]} if isinstance(out, Exception) else {"result": out})
            self.queue += [{"msg": "updated", "methods": [m["id"]]}, reply]

    def recv(self):
        return json.dumps(self.queue.pop(0))

    def close(self):
        self.closed = True


def paged(sessions):
    return lambda p: sessions[p["skip"]:p["skip"] + mod.PAGE]


def boulders(p):
    return {"boulders": [{"_id": "B" + p["sessionId"], "label": 5, "grade": "2", "sent": True,
                          "picture": {"id": "x"}, "setterProfile": {"name": "n"}}],
            "triedBoulders": [], "retopBoulders": [], "gym": "arkose/chevaleret"}


def setup(tmp_path, token=None, store=None):
    if token is not False:
        (tmp_path / "token.json").write_text(json.dumps(token or {"userId": "U1", "token": "T", "capturedAt": NOW - 60}))
    if store is not None:
        (tmp_path / "sessions.json").write_text(json.dumps(store))
    return {"ARKOSE_DIR": str(tmp_path)}


def run(env, server):
    return mod.main(env=env, connect=lambda url: server, clock=lambda: NOW)


def test_should_sync():
    cfg = mod.Config()
    tok = {"token": "T", "capturedAt": NOW - 5 * 3600}
    assert mod.should_sync(tok, NOW - 6 * 3600, NOW, cfg)          # captured since last sync
    assert not mod.should_sync(tok, NOW - 4 * 3600, NOW, cfg)      # synced since, follow-up over
    assert mod.should_sync({"token": "T", "capturedAt": NOW - 3600}, NOW - 600, NOW, cfg)  # follow-up
    assert mod.should_sync({"token": "T", "capturedAt": NOW - 30 * 3600}, NOW - 25 * 3600, NOW, cfg)  # daily
    assert not mod.should_sync({}, 0, NOW, cfg)


def test_first_sync_pages_through_and_fetches_non_empty(tmp_path):
    sessions = [session(f"s{i}", days_ago=i * 3, tops=(5 if i < 22 else 0)) for i in range(25)]
    server = FakeServer({"_users.getUserSessions": paged(sessions),
                         "_users.getUserSessionBoulders": boulders})
    env = setup(tmp_path)
    assert run(env, server) == 0
    skips = [p["skip"] for m, p in server.calls if m == "_users.getUserSessions"]
    assert skips == [0, 20]
    assert sum(m == "_users.getUserSessionBoulders" for m, _ in server.calls) == 22
    store = json.loads((tmp_path / "sessions.json").read_text())
    assert store["userId"] == "U1" and store["lastSyncAt"] == NOW and len(store["sessions"]) == 25
    s0 = store["sessions"]["s0"]
    assert s0["startDate"] == "2027-01-15T08:00:00+00:00"
    assert "userAvatars" not in s0 and s0["bestTop"] == {"boulderId": "b", "picture": {"id": "p"}}
    assert s0["boulders"] == [{"_id": "Bs0", "label": 5, "grade": "2", "sent": True,
                               "picture": {"id": "x"}}]
    assert s0["detailVersion"] == mod.DETAIL_VERSION
    assert "boulders" not in store["sessions"]["s24"]
    assert server.closed


def test_incremental_sync_refetches_only_recent_or_changed(tmp_path):
    sessions = [session(f"s{i}", days_ago=i * 3 + 1, tops=5) for i in range(25)]
    server = FakeServer({"_users.getUserSessions": paged(sessions),
                         "_users.getUserSessionBoulders": boulders})
    env = setup(tmp_path, token={"userId": "U1", "token": "T", "capturedAt": NOW - 60})
    run(env, server)

    sessions[3] = {**sessions[3], "tops": 6}
    server2 = FakeServer({"_users.getUserSessions": paged(sessions),
                          "_users.getUserSessionBoulders": boulders})
    store = json.loads((tmp_path / "sessions.json").read_text())
    store["lastSyncAt"] = NOW - 120
    (tmp_path / "sessions.json").write_text(json.dumps(store))
    assert run(env, server2) == 0
    assert [p["skip"] for m, p in server2.calls if m == "_users.getUserSessions"] == [0]
    # s0 is 1 day old (still open to new tops), s3 gained a top.
    assert [p["sessionId"] for m, p in server2.calls if m == "_users.getUserSessionBoulders"] == ["s0", "s3"]
    store = json.loads((tmp_path / "sessions.json").read_text())
    assert store["sessions"]["s5"]["boulders"]  # kept from the first run


def test_idle_run_touches_nothing(tmp_path):
    env = setup(tmp_path, token={"userId": "U1", "token": "T", "capturedAt": NOW - 10 * 3600},
                store={"userId": "U1", "lastSyncAt": NOW - 5 * 3600, "sessions": {}})
    assert mod.main(env=env, connect=lambda url: 1 / 0, clock=lambda: NOW) == 0


def test_no_token_does_nothing(tmp_path):
    assert mod.main(env=setup(tmp_path, token=False), connect=lambda url: 1 / 0, clock=lambda: NOW) == 0


def test_logged_out_token_fails_without_writing(tmp_path):
    server = FakeServer({"login": lambda p: Exception({"error": 403, "reason": "You've been logged out by the server."})})
    env = setup(tmp_path)
    assert run(env, server) == 1
    assert not (tmp_path / "sessions.json").exists()
    assert server.closed


def test_token_for_another_account_is_refused(tmp_path):
    server = FakeServer({}, user="U2")
    assert run(setup(tmp_path), server) == 1
    assert [m for m, _ in server.calls] == ["login"]


def test_detail_from_an_older_version_is_refetched_once(tmp_path):
    old = {"_id": "s9", "startDate": "2026-01-01T00:00:00+00:00", "isClosed": True, "isEmpty": False,
           "tops": 5, "flashs": 0, "tried": 0, "retops": 0, "boulders": [{"_id": "B"}]}
    sessions = [session("s9", days_ago=30, tops=5)]
    env = setup(tmp_path, store={"userId": "U1", "lastSyncAt": NOW - 120, "sessions": {"s9": old}})
    server = FakeServer({"_users.getUserSessions": paged(sessions),
                         "_users.getUserSessionBoulders": boulders})
    run(env, server)
    assert [p["sessionId"] for m, p in server.calls if m == "_users.getUserSessionBoulders"] == ["s9"]
    store = json.loads((tmp_path / "sessions.json").read_text())
    assert store["sessions"]["s9"]["boulders"][0]["picture"] == {"id": "x"}
    server2 = FakeServer({"_users.getUserSessions": paged(sessions),
                          "_users.getUserSessionBoulders": boulders})
    run(env, server2)
    assert not any(m == "_users.getUserSessionBoulders" for m, _ in server2.calls)
