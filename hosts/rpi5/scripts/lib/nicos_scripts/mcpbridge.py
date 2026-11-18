"""mcp-stdio-bridge: serve a stdio MCP server over Streamable HTTP, for Aperture.

    mcp-stdio-bridge [--exclude TOOL | --include TOOL]... -- COMMAND [ARG]...

One long-lived child, initialized by the bridge; requests are serialized to it.
Excluded tools, and with any --include every tool not included, are neither
listed nor callable. With a `token` credential
(LoadCredential=token:…), POST /mcp needs `Authorization: Bearer <token>`.
Env: MCP_BRIDGE_HOST (127.0.0.1), MCP_BRIDGE_PORT.
"""

import json
import queue
import subprocess
import sys
import threading
import time

from . import mcpstdio
from .logs import logger
from .secrets import env_int, env_str

log = logger("mcp-stdio-bridge", lambda: sys.stderr)
CALL_TIMEOUT = 300


class Child:
    def __init__(self, argv, popen=subprocess.Popen, timeout=CALL_TIMEOUT):
        self.argv, self.popen, self.timeout = argv, popen, timeout
        self.proc = None
        self.lines = None
        self.next_id = 0
        self.init_result = None
        self.lock = threading.Lock()

    def _start(self):
        self.init_result = None
        self.proc = self.popen(
            self.argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.lines = queue.Queue()
        threading.Thread(
            target=self._read, args=(self.proc, self.lines), daemon=True
        ).start()
        reply = self._rpc(
            "initialize",
            {
                "protocolVersion": mcpstdio.PROTOCOL,
                "capabilities": {},
                "clientInfo": {"name": "mcp-stdio-bridge", "version": "1"},
            },
        )
        if "result" not in reply:
            self.stop()
            raise RuntimeError(f"initialize failed: {reply}")
        self.init_result = reply["result"]
        self._write({"jsonrpc": "2.0", "method": "notifications/initialized"})
        log(f"started {self.argv[0]}")

    @staticmethod
    def _read(proc, lines):
        for line in proc.stdout:
            try:
                lines.put(json.loads(line))
            except ValueError:
                log(f"non-JSON line from the child: {line[:200]!r}")
        lines.put(None)

    def _write(self, msg):
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def _rpc(self, method, params):
        """One request, one deadline: past it the child is killed, which also
        frees a write blocked on a child that stopped reading."""
        self.next_id += 1
        rid = self.next_id
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        deadline = time.monotonic() + self.timeout
        watchdog = threading.Timer(self.timeout, self.proc.kill)
        watchdog.start()
        try:
            return self._exchange(msg, rid, deadline)
        except TimeoutError:
            raise
        except OSError as e:
            self.stop()
            raise RuntimeError(
                f"{method}: the MCP server stopped reading ({e})"
            ) from None
        finally:
            watchdog.cancel()

    def _exchange(self, msg, rid, deadline):
        self._write(msg)
        while True:
            try:
                got = self.lines.get(timeout=max(0, deadline - time.monotonic()))
            except queue.Empty:
                self.stop()
                raise TimeoutError(
                    f"{msg['method']}: no reply in {self.timeout}s"
                ) from None
            if got is None:
                self.proc = None
                if time.monotonic() >= deadline:
                    raise TimeoutError(f"{msg['method']}: no reply in {self.timeout}s")
                raise RuntimeError("the MCP server exited")
            if got.get("id") == rid and "method" not in got:
                return got
            if "method" in got and got.get("id") is not None:
                # A request to the client (roots, sampling): the bridge offers none.
                self._write(
                    {
                        "jsonrpc": "2.0",
                        "id": got["id"],
                        "error": {"code": -32601, "message": "not supported"},
                    }
                )

    def call(self, method, params=None):
        with self.lock:
            if self.proc is None or self.proc.poll() is not None:
                self._start()
            return self._rpc(method, params)

    def initialize(self):
        with self.lock:
            if (
                self.proc is None
                or self.proc.poll() is not None
                or not self.init_result
            ):
                self._start()
            return self.init_result

    def stop(self):
        if self.proc is not None:
            self.proc.kill()
            self.proc = None


def dispatcher(child, exclude=frozenset(), include=None):
    def allowed(name):
        return name not in exclude and (include is None or name in include)

    def dispatch(msg):
        method, rid = msg.get("method"), msg.get("id")
        if rid is None:
            return None  # the bridge already sent notifications/initialized
        params = msg.get("params")
        try:
            if method == "initialize":
                return {"jsonrpc": "2.0", "id": rid, "result": child.initialize()}
            if method == "ping":
                return {"jsonrpc": "2.0", "id": rid, "result": {}}
            if method == "tools/call":
                name = params.get("name") if isinstance(params, dict) else None
                if not isinstance(name, str) or not allowed(name):
                    return mcpstdio._error(rid, -32602, f"unknown tool: {name}")
            reply = child.call(method, params)
        except (OSError, RuntimeError, TimeoutError) as e:
            log(f"{method} failed: {e}")
            return mcpstdio._error(rid, -32603, str(e))
        reply = {**reply, "id": rid}
        if method == "tools/list" and "result" in reply:
            tools = reply["result"].get("tools") or []
            reply["result"] = {
                **reply["result"],
                "tools": [t for t in tools if allowed(t.get("name"))],
            }
        return reply

    return dispatch


USAGE = (
    "usage: mcp-stdio-bridge [--exclude TOOL | --include TOOL]... -- COMMAND [ARG]..."
)


def parse_args(argv):
    """-> (exclude, include or None, command)."""
    if "--" not in argv:
        raise ValueError(USAGE)
    split = argv.index("--")
    opts, command = argv[:split], argv[split + 1 :]
    flags = opts[::2]
    if (
        not command
        or len(opts) % 2
        or any(o not in ("--exclude", "--include") for o in flags)
    ):
        raise ValueError(USAGE)
    pairs = list(zip(flags, opts[1::2]))
    exclude = frozenset(v for f, v in pairs if f == "--exclude")
    include = frozenset(v for f, v in pairs if f == "--include") or None
    return exclude, include, command


def main(argv=None, env=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        exclude, include, command = parse_args(argv)
    except ValueError as e:
        log(str(e))
        return 2
    host = env_str("MCP_BRIDGE_HOST", "127.0.0.1", env)
    port = env_int("MCP_BRIDGE_PORT", 0, env)
    if not port:
        log("FATAL: MCP_BRIDGE_PORT unset")
        return 2
    child = Child(command)
    mcpstdio.serve_dispatch(
        dispatcher(child, exclude, include),
        log,
        host,
        port,
        mcpstdio.credential_token(env),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
