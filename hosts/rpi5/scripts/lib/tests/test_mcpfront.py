import json

import pytest

from nicos_scripts import mcpfront

TOOLS = {"tools": [{"name": "get_accounts", "inputSchema": {}}]}
AUTH = {"Authorization": "Bearer tok", "Content-Type": "application/json"}


class Backend:
    """Fake `post`: the direct port refuses while asleep; the wake URL wakes it."""

    def __init__(self, awake):
        self.awake, self.calls = awake, []

    def __call__(self, url, body, headers, timeout):
        self.calls.append((url, json.loads(body) if body else None, headers))
        if url == "direct":
            if not self.awake:
                raise mcpfront.Asleep
        else:
            self.awake = True
        msg = json.loads(body)
        if "id" not in msg:
            return 204, "", b""
        result = TOOLS if msg["method"] == "tools/list" else {"from": url}
        return 200, "application/json", mcpfront._reply(msg["id"], result)


@pytest.fixture
def front(tmp_path, logged):
    def make(awake):
        cfg = mcpfront.Config(
            wake_url="wake",
            direct_url="direct",
            cache_path=str(tmp_path / "cache.json"),
            token="tok",
        )
        backend = Backend(awake)
        return mcpfront.Front(cfg, post=backend, log=logged[1]), backend

    return make


def rpc(method, rid=1):
    msg = {"jsonrpc": "2.0", "method": method}
    if rid is not None:
        msg["id"] = rid
    return json.dumps(msg).encode()


def body(reply):
    return json.loads(reply[2])


def test_tools_list_comes_from_the_cache_while_the_backend_sleeps(front):
    f, backend = front(awake=True)
    f.handle(rpc("tools/list"), AUTH)
    backend.awake = False

    reply = f.handle(rpc("tools/list", rid=7), AUTH)

    assert body(reply) == {"jsonrpc": "2.0", "id": 7, "result": TOOLS}
    assert [c[0] for c in backend.calls] == ["direct", "direct"]


def test_an_empty_cache_wakes_the_backend_once(front):
    f, backend = front(awake=False)

    assert body(f.handle(rpc("tools/list"), AUTH))["result"] == TOOLS
    assert [c[0] for c in backend.calls] == ["direct", "wake"]


def test_tool_calls_always_wake_the_backend(front):
    f, backend = front(awake=False)

    reply = f.handle(rpc("tools/call"), AUTH)

    assert body(reply)["result"] == {"from": "wake"}
    assert backend.calls[0][2]["Authorization"] == "Bearer tok"


def test_ping_and_notifications_never_wake_it(front):
    f, backend = front(awake=False)

    assert body(f.handle(rpc("ping"), AUTH))["result"] == {}
    assert f.handle(rpc("notifications/initialized", rid=None), AUTH)[0] == 202
    assert not backend.awake


def test_a_caller_without_the_token_never_sees_the_cache(front):
    f, backend = front(awake=True)
    f.handle(rpc("tools/list"), AUTH)
    backend.awake = False

    f.handle(rpc("tools/list"), {"Authorization": "Bearer nope"})

    assert backend.calls[-1][0] == "wake"


def test_a_failed_reply_is_not_cached(front, tmp_path):
    f, _ = front(awake=True)
    f.post = lambda *a: (401, "application/json", b'{"error": "unauthorized"}')

    f.handle(rpc("tools/list"), AUTH)

    assert not (tmp_path / "cache.json").exists()


def test_config_reads_the_token_by_variable_name():
    cfg = mcpfront.Config.from_env(
        {
            "MCP_FRONT_PORT": "8371",
            "MCP_FRONT_WAKE_URL": "w",
            "MCP_FRONT_DIRECT_URL": "d",
            "MCP_FRONT_CACHE": "/c",
            "MCP_FRONT_TOKEN_VAR": "MCP_API_TOKEN",
            "MCP_API_TOKEN": "secret",
        }
    )
    assert (cfg.port, cfg.token) == (8371, "secret")


def test_post_turns_a_refused_port_into_asleep():
    import urllib.error

    def refuse(req, timeout):
        raise urllib.error.URLError(ConnectionRefusedError())

    with pytest.raises(mcpfront.Asleep):
        mcpfront.post("http://x", b"{}", {}, 1, opener=refuse)
