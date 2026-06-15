#!/usr/bin/env python3
"""picoclaw `before_tool` process hook: transparently rewrite `exec` commands
via `rtk rewrite` so the agent's shell output is token-compressed.

Protocol (picoclaw pkg/agent/hook_process.go): JSON-RPC 2.0 over stdio,
newline-delimited. picoclaw is the CLIENT; this process is the SERVER. picoclaw
sends requests; we reply `{"jsonrpc":"2.0","id":<id>,"result":<result>}`:

  hook.hello        params = {name, version, modes}                  → any result obj
  hook.before_tool  params = ToolCallHookRequest {tool, arguments, …} → {action, …}

For a rewrite we return {"action":"modify","call": <full request with
arguments.command replaced>} — picoclaw uses `call` verbatim as the new tool
invocation. Anything else returns {"action":"continue"}. We fail OPEN on any
error (never block or alter a command we couldn't rewrite cleanly).

`rtk` is located via the RTK_BIN env var (set to an absolute store path by the
hook config in picoclaw.nix), falling back to PATH lookup.
"""
import json
import os
import subprocess
import sys

RTK_BIN = os.environ.get("RTK_BIN", "rtk")
REWRITE_TIMEOUT_S = 2.0


def rewrite(cmd):
    """Return the rewritten command, or None to pass through.

    `rtk rewrite` exit codes: 0 + stdout = rewrite, 3 + stdout = advisory
    rewrite, 1 = no equivalent. Returns None (pass through) on any error.
    """
    try:
        p = subprocess.run(
            [RTK_BIN, "rewrite", cmd],
            capture_output=True,
            text=True,
            timeout=REWRITE_TIMEOUT_S,
        )
    except Exception:
        return None
    if p.returncode not in (0, 3):
        return None
    out = p.stdout.strip()
    return out or None


def handle_before_tool(params):
    if not isinstance(params, dict) or params.get("tool") != "exec":
        return {"action": "continue"}
    args = params.get("arguments")
    if not isinstance(args, dict):
        return {"action": "continue"}
    cmd = args.get("command")
    if not isinstance(cmd, str) or cmd.strip() == "" or cmd.startswith("rtk "):
        return {"action": "continue"}
    new_cmd = rewrite(cmd)
    if not new_cmd or new_cmd == cmd:
        return {"action": "continue"}
    # Echo the full request back with only arguments.command mutated.
    new_args = dict(args)
    new_args["command"] = new_cmd
    new_params = dict(params)
    new_params["arguments"] = new_args
    return {"action": "modify", "call": new_params}


def handle(method, params):
    if method == "hook.before_tool":
        return handle_before_tool(params)
    if method == "hook.hello":
        return {"name": "rtk", "version": 1}
    # We only subscribe to before_tool; answer other interceptor stages safely
    # if ever invoked.
    return {"action": "continue"}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        msg_id = msg.get("id")
        # Notifications (no id) expect no response.
        if msg_id is None:
            continue
        try:
            result = handle(msg.get("method"), msg.get("params"))
        except Exception:
            result = {"action": "continue"}
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
