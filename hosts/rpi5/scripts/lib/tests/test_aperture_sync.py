import io
import json

from nicos_scripts.llm import aperture_sync as ap


class Resp(io.BytesIO):
    def __init__(self, data=b"", content_type="application/json"):
        super().__init__(data)
        self.headers = {"Content-Type": content_type}

    def read1(self, n=-1):
        return super().read1(n)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


BASE = {
    "providers": {
        "rpi5-gate": {"models": ["gemma4:e4b", "openai/gpt-6-luna"]},
        "rpi5-gate-anthropic": {"models": ["claude-opus-5-5"]},
    },
    "exporters": {"s3": {"access_key_id": "__X__", "access_secret": "__X__"}},
}
GATE = {
    "data": [
        {"id": "gpt-6.1-terra"},
        {"id": "gemma4:e4b"},
        {"id": "codex/gpt-6.1-terra"},
    ]
}


INIT_OK = (
    b'{"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "x",'
    b' "capabilities": {}, "serverInfo": {"name": "s", "version": "1"}}}'
)


class Aperture:
    """Fake gate + Aperture API, recording PUTs."""

    def __init__(self, held=None, gate=GATE, put_result=None, claude=None):
        self.held = held
        self.claude = claude or {"data": [{"id": "claude-opus-6"}]}
        self.gate = gate
        self.puts = []
        self.put_result = put_result or {"success": True, "hash": "h2"}

    def __call__(self, req, timeout=None):
        url = req.full_url
        if "api.anthropic.com" in url:
            self.anthropic_auth = req.get_header("Authorization")
            if isinstance(self.claude, Exception):
                raise self.claude
            return Resp(json.dumps(self.claude).encode())
        if url.endswith("/v1/models"):
            if isinstance(self.gate, Exception):
                raise self.gate
            return Resp(json.dumps(self.gate).encode())
        if req.get_method() == "POST" and url.endswith("/mcp"):
            return Resp(INIT_OK)
        if req.get_method() == "PUT":
            self.puts.append(json.loads(req.data))
            return Resp(json.dumps(self.put_result).encode())
        body = {"config": json.dumps(self.held) if self.held else "", "hash": "h1"}
        return Resp(json.dumps(body).encode())


def cfg_for(tmp_path, apply=True):
    p = tmp_path / "base.json"
    p.write_text(json.dumps(BASE))
    return ap.Config(
        aperture_url="http://ap",
        base_config=str(p),
        s3_key="K",
        s3_secret="S",
        apply=apply,
    )


def test_merges_gate_ids_and_pushes_with_hash(tmp_path):
    fake = Aperture(held={"old": True})
    assert ap.run(cfg_for(tmp_path), opener=fake, sleep=lambda s: None) == 0
    (put,) = fake.puts
    assert put["hash"] == "h1"
    sent = json.loads(put["config"])
    assert sent["providers"]["rpi5-gate"]["models"] == [
        "gemma4:e4b",
        "gpt-6.1-terra",
        "openai/gpt-6-luna",
    ]
    assert sent["providers"]["rpi5-gate-anthropic"]["models"] == ["claude-opus-5-5"]
    assert sent["exporters"]["s3"] == {"access_key_id": "K", "access_secret": "S"}


def test_no_put_when_aperture_already_matches(tmp_path):
    cfg = cfg_for(tmp_path)
    want = ap.desired(BASE, ap.gate_ids(GATE), cfg)
    fake = Aperture(held=want)
    assert ap.run(cfg, opener=fake) == 0
    assert fake.puts == []


def test_gate_down_leaves_aperture_alone(tmp_path):
    fake = Aperture(held={"old": True}, gate=OSError("refused"))
    assert ap.run(cfg_for(tmp_path), opener=fake) == 0
    assert fake.puts == []


def test_dry_run_never_writes(tmp_path):
    fake = Aperture(held={"old": True})
    assert ap.run(cfg_for(tmp_path, apply=False), opener=fake) == 0
    assert fake.puts == []


def test_rejection_retries_then_fails(tmp_path):
    fake = Aperture(
        held={"old": True}, put_result={"success": False, "error": {"message": "no"}}
    )
    assert ap.run(cfg_for(tmp_path), opener=fake, sleep=lambda s: None, attempts=3) == 1
    assert len(fake.puts) == 3


def test_apply_is_off_without_env():
    assert ap.Config.from_env({}).apply is False
    assert ap.Config.from_env({"APERTURE_APPLY": "1"}).apply is True


def test_aperture_rewritten_apikey_still_counts_as_unchanged(tmp_path):
    cfg = cfg_for(tmp_path)
    base = json.loads(json.dumps(BASE))
    base["providers"]["rpi5-gate"]["apikey"] = "unused"
    (tmp_path / "base.json").write_text(json.dumps(base))
    held = ap.desired(base, ap.gate_ids(GATE), cfg)
    held["providers"]["rpi5-gate"]["apikey"] = "keyid:p:rpi5-gate:unused"
    held["providers"]["rpi5-gate"]["models"].reverse()
    held["exporters"]["s3"]["access_secret"] = "keyid:s3:access_secret"
    fake = Aperture(held=held)
    assert ap.run(cfg, opener=fake) == 0
    assert fake.puts == []


def test_merges_anthropic_ids_read_with_the_oauth_token(tmp_path):
    tok = tmp_path / "token"
    tok.write_text("oauth-tok\n")
    cfg = ap.Config(**{**cfg_for(tmp_path).__dict__, "anthropic_token_file": str(tok)})
    fake = Aperture(held={"old": True})
    assert ap.run(cfg, opener=fake) == 0
    sent = json.loads(fake.puts[0]["config"])
    assert sent["providers"]["rpi5-gate-anthropic"]["models"] == [
        "claude-opus-5-5",
        "claude-opus-6",
    ]
    assert fake.anthropic_auth == "Bearer oauth-tok"


def test_anthropic_down_leaves_aperture_alone(tmp_path):
    tok = tmp_path / "token"
    tok.write_text("t")
    cfg = ap.Config(**{**cfg_for(tmp_path).__dict__, "anthropic_token_file": str(tok)})
    fake = Aperture(held={"old": True}, claude=OSError("401"))
    assert ap.run(cfg, opener=fake) == 0
    assert fake.puts == []


CONNECTORS = {
    "servers": {
        "notes": {"protocol": "mcp", "url": "https://h:3980/mcp"},
        "sure": {
            "protocol": "mcp",
            "url": "https://h:3850/sure/mcp",
            "auth": {"type": "bearer_token", "secret": "env:MCP_API_TOKEN"},
            "send_caller_identity": True,
        },
    }
}


def connector_cfg(tmp_path, secrets):
    cfg = ap.Config(**{**cfg_for(tmp_path).__dict__, "connector_secrets": secrets})
    base = {**BASE, "connectors": CONNECTORS}
    (tmp_path / "base.json").write_text(json.dumps(base))
    return base, cfg


def test_connector_secret_filled_from_env(tmp_path):
    base, cfg = connector_cfg(tmp_path, {"MCP_API_TOKEN": "tok"})
    fake = Aperture(held={"old": True})
    assert ap.run(cfg, opener=fake, sleep=lambda s: None) == 0
    servers = json.loads(fake.puts[0]["config"])["connectors"]["servers"]
    assert servers["sure"]["auth"]["secret"] == "tok"
    assert (
        base["connectors"]["servers"]["sure"]["auth"]["secret"] == "env:MCP_API_TOKEN"
    )


def test_connector_without_its_secret_is_left_out(tmp_path):
    _, cfg = connector_cfg(tmp_path, {"MCP_API_TOKEN": ""})
    fake = Aperture(held={"old": True})
    assert ap.run(cfg, opener=fake) == 0
    servers = json.loads(fake.puts[0]["config"])["connectors"]["servers"]
    assert sorted(servers) == ["notes"]


def test_aperture_rewritten_connector_still_counts_as_unchanged(tmp_path):
    base, cfg = connector_cfg(tmp_path, {"MCP_API_TOKEN": "tok"})
    held = ap.desired(base, ap.gate_ids(GATE), cfg)
    for server in held["connectors"]["servers"].values():
        server["provider"] = "Custom"
    held["connectors"]["servers"]["sure"]["auth"]["secret"] = "keyid:c:sure"
    fake = Aperture(held=held)
    assert ap.run(cfg, opener=fake) == 0
    assert fake.puts == []


def test_connector_secrets_read_only_by_name():
    env = {"APERTURE_CONNECTOR_SECRETS": "A B", "A": "1", "C": "3"}
    assert ap.Config.from_env(env).connector_secrets == {"A": "1", "B": ""}


def test_connector_secret_falls_back_to_the_systemd_credential(tmp_path):
    (tmp_path / "B").write_text("from-cred\n")
    env = {
        "APERTURE_CONNECTOR_SECRETS": "A B C",
        "A": "from-env",
        "CREDENTIALS_DIRECTORY": str(tmp_path),
    }
    assert ap.Config.from_env(env).connector_secrets == {
        "A": "from-env",
        "B": "from-cred",
        "C": "",
    }


def test_wakes_sleepy_connectors_before_a_push_only(tmp_path):
    base = {
        **BASE,
        "connectors": {
            "servers": {
                "sure": {"url": "http://sure/mcp", "send_caller_identity": True},
                "openaidocs": {"url": "http://docs/mcp"},
            }
        },
    }
    p = tmp_path / "base.json"
    p.write_text(json.dumps(base))
    cfg = ap.Config(aperture_url="http://ap", base_config=str(p), apply=True)
    fake = Aperture(held={"old": True})
    calls = []

    def opener(req, timeout=None):
        calls.append((req.get_method(), req.full_url))
        if req.full_url == "http://sure/mcp":
            raise OSError("405")
        return fake(req, timeout)

    assert ap.run(cfg, opener=opener, sleep=lambda s: None) == 0
    assert calls.index(("POST", "http://sure/mcp")) < calls.index(
        ("PUT", "http://ap/api/config")
    )
    assert "http://docs/mcp" not in [url for _, url in calls]
    assert len(fake.puts) == 1

    calls.clear()
    fake.held = json.loads(fake.puts[0]["config"])
    assert ap.run(cfg, opener=opener) == 0
    assert ("POST", "http://sure/mcp") not in calls


def test_wakes_before_the_first_put_even_when_the_first_read_fails(tmp_path):
    base = {
        **BASE,
        "connectors": {
            "servers": {
                "sure": {"url": "http://sure/mcp", "send_caller_identity": True}
            }
        },
    }
    p = tmp_path / "base.json"
    p.write_text(json.dumps(base))
    cfg = ap.Config(aperture_url="http://ap", base_config=str(p), apply=True)
    fake = Aperture(held={"old": True})
    calls, reads = [], []

    def opener(req, timeout=None):
        calls.append((req.get_method(), req.full_url))
        if req.full_url == "http://ap/api/config" and req.get_method() == "GET":
            reads.append(1)
            if len(reads) == 1:
                raise OSError("aperture restarting")
        return fake(req, timeout)

    assert ap.run(cfg, opener=opener, sleep=lambda s: None) == 0
    assert len(fake.puts) == 1
    assert calls.index(("POST", "http://sure/mcp")) < calls.index(
        ("PUT", "http://ap/api/config")
    )


def test_wake_initializes_with_the_connector_token_until_a_result():
    config = {
        "connectors": {
            "servers": {
                "immich": {
                    "url": "http://immich/mcp",
                    "send_caller_identity": True,
                    "auth": {"type": "bearer_token", "secret": "tok"},
                },
                "rx": {
                    "url": "http://rx/mcp",
                    "send_caller_identity": True,
                    "auth": {
                        "type": "api_key",
                        "in": "header",
                        "name": "x-api-key",
                        "secret": "k",
                    },
                },
                "docs": {"url": "http://docs/mcp"},
            }
        }
    }
    seen, answers = [], {"http://immich/mcp": [OSError("502"), b'{"error": {}}']}

    def opener(req, timeout=None):
        seen.append((req.full_url, req.get_method(), dict(req.header_items())))
        pending = answers.get(req.full_url) or []
        if pending:
            nxt = pending.pop(0)
            if isinstance(nxt, Exception):
                raise nxt
            return Resp(nxt)
        return Resp(
            # One SSE event, its JSON split over two data lines.
            b'event: message\ndata: {"jsonrpc": "2.0", "id": 1,\n'
            b'data: "result": {"protocolVersion": "2025-03-26", "capabilities": {},\n'
            b'data: "serverInfo": {"name": "s", "version": "1"}}}\n\n',
            content_type="text/event-stream",
        )

    assert ap.wake(config, opener=opener, sleep=lambda s: None) == []
    immich = [h for u, m, h in seen if u == "http://immich/mcp"]
    assert len(immich) == 3 and immich[0]["Authorization"] == "Bearer tok"
    assert [h["X-api-key"] for u, m, h in seen if u == "http://rx/mcp"] == ["k"]
    assert all(m == "POST" for _, m, _ in seen)
    assert "http://docs/mcp" not in [u for u, _, _ in seen]


def test_wake_reports_a_connector_that_never_initializes():
    config = {
        "connectors": {
            "servers": {
                "sure": {"url": "http://sure/mcp", "send_caller_identity": True}
            }
        }
    }

    def opener(req, timeout=None):
        raise OSError("cold")

    assert ap.wake(config, opener=opener, sleep=lambda s: None, deadline=30) == [
        "http://sure/mcp"
    ]


def test_a_rotated_secret_alone_forces_one_push(tmp_path):
    base, cfg = connector_cfg(tmp_path, {"MCP_API_TOKEN": "tok"})
    state = tmp_path / "secrets.sha256"
    cfg = ap.Config(**{**cfg.__dict__, "state_file": str(state)})
    held = ap.desired(base, ap.gate_ids(GATE), cfg)
    held["connectors"]["servers"]["sure"]["auth"]["secret"] = "keyid:c:sure"
    fake = Aperture(held=held)
    no_sleep = {"sleep": lambda s: None}

    # No state yet: the first run pushes once and records the digest.
    assert ap.run(cfg, opener=fake, **no_sleep) == 0
    assert len(fake.puts) == 1 and state.read_text().strip()
    assert "tok" not in state.read_text()
    # Same secrets: a no-op.
    assert ap.run(cfg, opener=fake, **no_sleep) == 0
    assert len(fake.puts) == 1
    # Only the token changed: pushed again.
    rotated = ap.Config(
        **{**cfg.__dict__, "connector_secrets": {"MCP_API_TOKEN": "tok2"}}
    )
    assert ap.run(rotated, opener=fake, **no_sleep) == 0
    assert len(fake.puts) == 2
    pushed = json.loads(fake.puts[1]["config"])
    assert pushed["connectors"]["servers"]["sure"]["auth"]["secret"] == "tok2"


def test_initialized_needs_the_response_to_initialize():
    ok = INIT_OK
    assert ap.initialized(ok)
    assert not ap.initialized(b'{"result": {"protocolVersion": "x"}}')
    assert not ap.initialized(
        b'{"jsonrpc": "2.0", "id": 2, "result": {"protocolVersion": "x"}}'
    )
    assert not ap.initialized(b'{"jsonrpc": "2.0", "id": 1, "result": {}}')


def test_wake_stops_at_the_wall_clock_deadline():
    config = {
        "connectors": {
            "servers": {"s": {"url": "http://s/mcp", "send_caller_identity": True}}
        }
    }
    now = [0.0]
    timeouts = []

    def opener(req, timeout=None):
        timeouts.append(timeout)
        now[0] += min(timeout, 60)  # hangs 60 s, or until its timeout
        raise OSError("timed out")

    def sleep(s):
        now[0] += s

    assert ap.wake(
        config, opener=opener, sleep=sleep, deadline=90, clock=lambda: now[0]
    ) == ["http://s/mcp"]
    assert timeouts == [90, 20] and now[0] <= 90


def test_an_unready_connector_makes_the_next_run_push_again(tmp_path):
    base = {
        **BASE,
        "connectors": {
            "servers": {
                "sure": {"url": "http://sure/mcp", "send_caller_identity": True}
            }
        },
    }
    p = tmp_path / "base.json"
    p.write_text(json.dumps(base))
    state = tmp_path / "secrets.sha256"
    cfg = ap.Config(
        aperture_url="http://ap", base_config=str(p), apply=True, state_file=str(state)
    )
    fake = Aperture(held={"old": True})
    cold = [True]

    def opener(req, timeout=None):
        if req.full_url == "http://sure/mcp":
            if cold[0]:
                raise OSError("cold")
            return Resp(INIT_OK)
        return fake(req, timeout)

    assert ap.run(cfg, opener=opener, sleep=lambda s: None) == 0
    assert len(fake.puts) == 1 and state.read_text().strip() == ""
    fake.held = json.loads(fake.puts[0]["config"])
    cold[0] = False
    assert ap.run(cfg, opener=opener, sleep=lambda s: None) == 0
    assert len(fake.puts) == 2 and state.read_text().strip()
    assert ap.run(cfg, opener=opener, sleep=lambda s: None) == 0
    assert len(fake.puts) == 2


def test_an_unwritable_digest_does_not_repeat_an_accepted_push(tmp_path):
    base, cfg = connector_cfg(tmp_path, {"MCP_API_TOKEN": "tok"})
    cfg = ap.Config(**{**cfg.__dict__, "state_file": str(tmp_path / "missing" / "d")})
    fake = Aperture(held={"old": True})
    assert ap.run(cfg, opener=fake, sleep=lambda s: None) == 0
    assert len(fake.puts) == 1


def test_wake_retries_a_body_cut_short():
    import http.client

    config = {
        "connectors": {
            "servers": {"s": {"url": "http://s/mcp", "send_caller_identity": True}}
        }
    }

    class Truncated(Resp):
        def read(self, *a):
            raise http.client.IncompleteRead(b"{")

    answers = [Truncated(b""), Resp(INIT_OK)]
    assert (
        ap.wake(
            config,
            opener=lambda req, timeout=None: answers.pop(0),
            sleep=lambda s: None,
        )
        == []
    )
    assert answers == []


def _serve(handler):
    import http.server
    import threading

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{srv.server_address[1]}/mcp"


def _sleepy(url):
    return {
        "connectors": {"servers": {"s": {"url": url, "send_caller_identity": True}}}
    }


def test_wake_gives_up_on_a_trickling_body_at_the_deadline():
    import http.server
    import time

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "100000")
            self.end_headers()
            try:
                for _ in range(100):  # a byte every 0.5 s: each read beats its timeout
                    self.wfile.write(b" ")
                    self.wfile.flush()
                    time.sleep(0.5)
            except OSError:
                pass

    srv, url = _serve(H)
    try:
        t0 = time.monotonic()
        assert ap.wake(_sleepy(url), deadline=2) == [url]
        assert time.monotonic() - t0 < 4
    finally:
        srv.shutdown()


def test_wake_rejects_json_short_of_its_content_length():
    import http.server

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(INIT_OK) + 50))
            self.end_headers()
            self.wfile.write(INIT_OK)  # complete-looking, then the connection closes
            self.close_connection = True

    srv, url = _serve(H)
    try:
        assert ap.wake(_sleepy(url), sleep=lambda s: None, deadline=3) == [url]
    finally:
        srv.shutdown()


def test_an_sse_event_counts_only_once_its_blank_line_arrived():
    event = b"data: " + INIT_OK + b"\n"
    assert not ap.initialized(event, sse=True)
    assert ap.initialized(event + b"\n", sse=True)
    assert ap.initialized(event.replace(b"\n", b"\r\n") + b"\r\n", sse=True)


def test_wake_never_follows_a_redirect_with_the_token():
    import http.server
    import threading

    hits = []

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def answer(self):
            hits.append((self.command, self.path, self.headers.get("Authorization")))
            # 302: urllib's default opener would re-send it as a GET to /elsewhere.
            self.send_response(302)
            self.send_header("Location", "/elsewhere")
            self.send_header("Content-Length", "0")
            self.end_headers()

        do_POST = do_GET = answer

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        url = f"http://127.0.0.1:{srv.server_address[1]}/mcp"
        config = {
            "connectors": {
                "servers": {
                    "s": {
                        "url": url,
                        "send_caller_identity": True,
                        "auth": {"type": "bearer_token", "secret": "tok"},
                    }
                }
            }
        }
        assert ap.wake(config, sleep=lambda s: None, deadline=10) == [url]
        assert hits and {(m, p, a) for m, p, a in hits} == {
            ("POST", "/mcp", "Bearer tok")
        }
    finally:
        srv.shutdown()


def test_an_unready_connector_clears_the_digest_before_the_put(tmp_path):
    base = {
        **BASE,
        "connectors": {
            "servers": {
                "sure": {"url": "http://sure/mcp", "send_caller_identity": True}
            }
        },
    }
    p = tmp_path / "base.json"
    p.write_text(json.dumps(base))
    state = tmp_path / "secrets.sha256"
    cfg = ap.Config(
        aperture_url="http://ap", base_config=str(p), apply=True, state_file=str(state)
    )
    state.write_text(ap.secrets_digest(ap.desired(base, ap.gate_ids(GATE), cfg)) + "\n")
    fake = Aperture(held={"old": True})
    seen_at_put = []

    def opener(req, timeout=None):
        if req.full_url == "http://sure/mcp":
            raise OSError("cold")
        if req.get_method() == "PUT":
            seen_at_put.append(state.read_text().strip())
        return fake(req, timeout)

    assert ap.run(cfg, opener=opener, sleep=lambda s: None) == 0
    assert seen_at_put == [""]


def test_an_invalid_initialize_result_is_not_ready():
    for bad in [
        b'{"jsonrpc": "2.0", "id": true, "result": {"protocolVersion": "x", "capabilities": {}, "serverInfo": {}}}',
        b'{"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": null, "capabilities": {}, "serverInfo": {}}}',
        b'{"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "x", "serverInfo": {}}}',
        b'{"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "x", "capabilities": {}}}',
    ]:
        assert not ap.initialized(bad), bad


def test_a_probe_still_reading_at_the_deadline_is_stopped():
    import http.server
    import threading
    import time

    gone = threading.Event()

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "100000")
            self.end_headers()
            try:
                for _ in range(100):
                    self.wfile.write(b" ")
                    self.wfile.flush()
                    time.sleep(0.2)
            except OSError:
                gone.set()

    srv, url = _serve(H)
    try:
        before = threading.active_count()
        assert ap.wake(_sleepy(url), deadline=1) == [url]
        assert gone.wait(5), "the probe kept reading after the deadline"
        time.sleep(0.2)
        assert threading.active_count() <= before
    finally:
        srv.shutdown()
