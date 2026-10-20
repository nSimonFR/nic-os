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
    assert "userAvatars" not in s0 and s0["bestTop"] == {"boulderId": "b"}
    assert s0["boulders"] == [{"_id": "Bs0", "label": 5, "grade": "2", "sent": True}]
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


def stored_session(sid, start, **lists):
    return {"_id": sid, "startDate": start, "endDate": None, "gymName": "Arkose Saint-Denis",
            "gym": "arkose/saint-denis", "gymLabels": {"4": "vert", "5": "bleu"}, **lists}


def boulder(bid, label, grade, num, **kw):
    return {"_id": bid, "label": label, "grade": grade, "boulderNum": num, **kw}


def test_to_freereps_maps_results_and_sends_a_route_once():
    store = {"sessions": {
        "s2": stored_session("s2", "2026-09-30T10:26:00+00:00",
                             boulders=[boulder("a", 4, "4", 4), boulder("b", 5, "2", 18, flashed=True)],
                             retopBoulders=[boulder("a", 4, "4", 4)],
                             triedBoulders=[boulder("c", 5, "5", 7)]),
        "s1": stored_session("s1", "2026-09-04T15:55:00+00:00"),
    }}
    p = mod.to_freereps(store)
    assert p["source"] == "Arkose+"
    assert [s["id"] for s in p["sessions"]] == ["s1", "s2"]
    assert p["sessions"][0]["ascents"] == []
    got = {a["route_id"]: (a["result"], a["grade"], a["grade_rank"], a["name"]) for a in p["sessions"][1]["ascents"]}
    assert got == {"a": ("repeat", "vert 4", 44, "4"), "b": ("flash", "bleu 2", 52, "18"),
                   "c": ("attempt", "bleu 5", 55, "7")}
    assert p["sessions"][1]["gym"] == "Arkose Saint-Denis" and p["sessions"][1]["end"] is None


class FakeResponse:
    def __init__(self, status, body):
        self.status, self.body = status, body

    def read(self):
        return self.body.encode()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_sync_pushes_to_freereps_when_configured(tmp_path):
    sessions = [session("s0", days_ago=1, tops=5)]
    server = FakeServer({"_users.getUserSessions": paged(sessions),
                         "_users.getUserSessionBoulders": boulders})
    env = {**setup(tmp_path), "ARKOSE_FREEREPS_URL": "http://fr:8370/"}
    sent = []

    def opener(req, timeout):
        sent.append((req.full_url, json.loads(req.data)))
        return FakeResponse(200, '{"climbing_sessions_received":1,"climbing_ascents_inserted":1}')

    assert mod.main(env=env, connect=lambda url: server, clock=lambda: NOW, opener=opener) == 0
    assert sent[0][0] == "http://fr:8370/api/v1/ingest/climbing"
    assert [a["route_id"] for a in sent[0][1]["sessions"][0]["ascents"]] == ["Bs0"]


def test_failed_push_fails_the_run_but_keeps_the_store(tmp_path):
    server = FakeServer({"_users.getUserSessions": paged([session("s0", days_ago=1, tops=5)]),
                         "_users.getUserSessionBoulders": boulders})
    env = {**setup(tmp_path), "ARKOSE_FREEREPS_URL": "http://fr:8370"}
    opener = lambda req, timeout: FakeResponse(500, '{"error":"db down"}')
    assert mod.main(env=env, connect=lambda url: server, clock=lambda: NOW, opener=opener) == 1
    assert json.loads((tmp_path / "sessions.json").read_text())["sessions"]["s0"]["boulders"]
