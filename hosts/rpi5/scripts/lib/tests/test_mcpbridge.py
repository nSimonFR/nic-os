"""mcp-stdio-bridge: a stdio MCP server behind the minimal HTTP transport."""

import json
import sys
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import pytest

from nicos_scripts import mcpbridge, mcpstdio

# A stdio MCP server: two tools, one of them dangerous; it asks the client for
# roots before answering a call, which the bridge must refuse and move past.
FAKE = r"""
import json, sys
tools = [{"name": "read", "inputSchema": {}}, {"name": "delete", "inputSchema": {}}]
for line in sys.stdin:
    m = json.loads(line)
    if "id" not in m or "method" not in m:
        continue
    if m["method"] == "initialize":
        r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
             "serverInfo": {"name": "fake", "version": "1"}}
    elif m["method"] == "tools/list":
        r = {"tools": tools}
    elif m["method"] == "tools/call":
        print(json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "id": "roots-1", "method": "roots/list"}), flush=True)
        json.loads(sys.stdin.readline())
        r = {"content": [{"type": "text", "text": m["params"]["name"]}]}
    elif m["method"] == "exit":
        sys.exit(0)
    elif m["method"] == "chatty":
        import time
        for _ in range(4):
            print(json.dumps({"jsonrpc": "2.0", "method": "notifications/progress"}), flush=True)
            time.sleep(0.5)
        continue
    elif m["method"] == "deaf":
        import time
        print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": {}}), flush=True)
        time.sleep(60)
    else:
        r = {}
    print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
"""


@pytest.fixture
def server():
    child = mcpbridge.Child([sys.executable, "-c", FAKE], timeout=10)
    httpd = ThreadingHTTPServer(
        ("127.0.0.1", 0),
        mcpstdio.dispatch_handler(
            mcpbridge.dispatcher(child, frozenset({"delete"})), token="tok"
        ),
    )
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_address[1]}", child
    httpd.shutdown()
    child.stop()


def _post(base, msg, token="tok"):
    req = urllib.request.Request(
        f"{base}/mcp",
        data=json.dumps(msg).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    with urllib.request.urlopen(req, timeout=15) as r:
        body = r.read()
        return r.status, json.loads(body) if body else None


def test_lists_and_calls_through_the_child_without_excluded_tools(server):
    base, _ = server
    _, init = _post(
        base, {"jsonrpc": "2.0", "id": 7, "method": "initialize", "params": {}}
    )
    assert init["id"] == 7 and init["result"]["serverInfo"]["name"] == "fake"
    assert _post(base, {"jsonrpc": "2.0", "method": "notifications/initialized"}) == (
        202,
        None,
    )
    _, listed = _post(base, {"jsonrpc": "2.0", "id": "a", "method": "tools/list"})
    assert listed["id"] == "a"
    assert [t["name"] for t in listed["result"]["tools"]] == ["read"]
    _, called = _post(
        base,
        {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "read"}},
    )
    assert called == {
        "jsonrpc": "2.0",
        "id": 9,
        "result": {"content": [{"type": "text", "text": "read"}]},
    }


def test_an_excluded_tool_cannot_be_called(server):
    base, _ = server
    _, reply = _post(
        base,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "delete"},
        },
    )
    assert reply["error"]["code"] == -32602


def test_a_wrong_token_is_refused_and_health_stays_open(server):
    base, _ = server
    with pytest.raises(urllib.error.HTTPError) as e:
        _post(base, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, token="nope")
    assert e.value.code == 401
    with urllib.request.urlopen(f"{base}/health", timeout=5) as r:
        assert r.status == 200


def test_a_dead_child_is_restarted_on_the_next_request(server):
    base, child = server
    _post(base, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    _, reply = _post(base, {"jsonrpc": "2.0", "id": 2, "method": "exit"})
    assert "error" in reply
    _, listed = _post(base, {"jsonrpc": "2.0", "id": 3, "method": "tools/list"})
    assert [t["name"] for t in listed["result"]["tools"]] == ["read"]


def test_parse_args_needs_a_command():
    assert mcpbridge.parse_args(["--exclude", "x", "--", "srv", "stdio"]) == (
        frozenset({"x"}),
        ["srv", "stdio"],
    )
    with pytest.raises(ValueError):
        mcpbridge.parse_args(["srv"])
    with pytest.raises(ValueError):
        mcpbridge.parse_args(["--bogus", "--", "srv"])


def test_one_deadline_per_request_despite_notifications():
    child = mcpbridge.Child([sys.executable, "-c", FAKE], timeout=1)
    try:
        started = __import__("time").monotonic()
        with pytest.raises(TimeoutError):
            child.call("chatty")
        assert __import__("time").monotonic() - started < 1.8
        assert child.call("tools/list")["result"]["tools"]
    finally:
        child.stop()


def test_a_child_that_stops_reading_is_killed_at_the_deadline():
    child = mcpbridge.Child([sys.executable, "-c", FAKE], timeout=1)
    try:
        assert child.call("deaf") == {"jsonrpc": "2.0", "id": 2, "result": {}}
        # The child now reads nothing: this write fills the pipe and blocks.
        started = __import__("time").monotonic()
        with pytest.raises((TimeoutError, RuntimeError)):
            child.call("tools/list", {"blob": "x" * 2_000_000})
        assert __import__("time").monotonic() - started < 2
        assert child.call("tools/list")["result"]["tools"]
    finally:
        child.stop()


def test_a_failed_initialize_discards_the_child():
    class Proc:
        def __init__(self, *a, **k):
            import io

            self.stdin = io.StringIO()
            self.stdout = io.StringIO(
                '{"jsonrpc":"2.0","id":1,"error":{"code":-1,"message":"no"}}\n'
            )
            self.killed = False

        def kill(self):
            self.killed = True

        def poll(self):
            return None

    child = mcpbridge.Child(["x"], popen=Proc, timeout=2)
    with pytest.raises(RuntimeError):
        child.initialize()
    assert child.proc is None and child.init_result is None
