#!/usr/bin/env python3
"""Mirror Claude Code memory writes into AFFiNE Wiki/Pages/Claude Memory/.

Wired as a PostToolUse hook on Write|Edit (see claude-settings.json).
Reads the hook payload from stdin:
    {"tool_name": "Write|Edit", "tool_input": {"file_path": ..., ...}, ...}

If file_path is under ~/.claude/projects/-home-nsimon-nic-os/memory/*.md,
upserts a child doc under the AFFiNE "Claude Memory" parent page.

No IDs are baked into this script. On first run we resolve:
  - workspace_id  = list_workspaces()[0].id
  - parent_doc_id = exact-title match of "Claude Memory" via search_docs;
                    created top-level if absent.
…then cache both, plus a per-file (filename → docId) map, in
~/.claude/state/memory-sync-map.json. Per-file misses trigger an
exact-title search before falling back to create — so a fresh map
re-binds to existing docs without duplicating them.

Always exits 0; never blocks Claude Code. Errors land in
~/.claude/logs/memory-sync.log.
"""
import json
import sys
import time
import urllib.request
from pathlib import Path

MEM_DIR = Path("/home/nsimon/.claude/projects/-home-nsimon-nic-os/memory")
MCP_URL = "http://127.0.0.1:7021/mcp"
TOKEN_PATH = Path("/run/agenix/affine-mcp-http-token")
PARENT_TITLE = "Claude Memory"
STATE_DIR = Path.home() / ".claude" / "state"
MAP_PATH = STATE_DIR / "memory-sync-map.json"
LOG_PATH = Path.home() / ".claude" / "logs" / "memory-sync.log"


def log(msg):
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}\n")
    except Exception:
        pass


def load_map():
    if MAP_PATH.exists():
        try:
            data = json.loads(MAP_PATH.read_text())
            data.setdefault("files", {})
            return data
        except Exception:
            pass
    return {"files": {}}


def save_map(m):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = MAP_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(m, indent=2, sort_keys=True))
    tmp.replace(MAP_PATH)


def title_for(path):
    text = path.read_text()
    if text.startswith("---"):
        for line in text.split("\n", 12)[:12]:
            if line.startswith("name:"):
                return line.split(":", 1)[1].strip()
    if path.name == "MEMORY.md":
        return "MEMORY (index)"
    return path.stem


class MCP:
    def __init__(self, token):
        self.token = token
        self.session = None
        self.req = 0

    def _post(self, body):
        self.req += 1
        body["id"] = self.req
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        req = urllib.request.Request(
            MCP_URL,
            data=json.dumps(body).encode(),
            headers=headers,
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            sid = resp.headers.get("Mcp-Session-Id")
            if sid and not self.session:
                self.session = sid
            raw = resp.read().decode()
        for line in raw.splitlines():
            if line.startswith("data: "):
                payload = json.loads(line[6:])
                if "error" in payload:
                    raise RuntimeError(payload["error"])
                return payload.get("result")
        raise RuntimeError(f"no data: {raw[:200]}")

    def init(self):
        self._post({
            "jsonrpc": "2.0",
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "claude-memory-sync", "version": "1.0"},
            },
        })
        body = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Mcp-Session-Id": self.session,
        }
        urllib.request.urlopen(
            urllib.request.Request(
                MCP_URL,
                data=json.dumps(body).encode(),
                headers=headers,
                method="POST",
            ),
            timeout=10,
        ).read()

    def call(self, name, args):
        res = self._post({
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        })
        text = res["content"][0]["text"]
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text


def first_workspace_id(client):
    res = client.call("list_workspaces", {})
    if isinstance(res, list) and res:
        return res[0].get("id")
    raise RuntimeError(f"no workspaces: {res}")


def find_doc_by_exact_title(client, ws_id, title):
    """Return docId of a doc whose title matches `title` exactly, or None."""
    res = client.call("search_docs", {
        "workspaceId": ws_id,
        "query": title,
        "limit": 20,
    })
    if isinstance(res, dict):
        for r in res.get("results", []):
            if r.get("title") == title:
                return r.get("id") or r.get("docId")
    return None


def ensure_parent(client, ws_id):
    parent_id = find_doc_by_exact_title(client, ws_id, PARENT_TITLE)
    if parent_id:
        return parent_id
    # Not found — create as a top-level page.
    res = client.call("create_doc_from_markdown", {
        "workspaceId": ws_id,
        "title": PARENT_TITLE,
        "markdown": (
            f"# {PARENT_TITLE}\n\n"
            "Auto-mirrored from `~/.claude/projects/-home-nsimon-nic-os/memory/`.\n"
        ),
    })
    if isinstance(res, dict) and res.get("docId"):
        return res["docId"]
    raise RuntimeError(f"could not create '{PARENT_TITLE}' page: {res}")


def resolve_workspace_and_parent(client, mapping):
    ws_id = mapping.get("workspace_id")
    if not ws_id:
        ws_id = first_workspace_id(client)
        mapping["workspace_id"] = ws_id
    parent_id = mapping.get("parent_doc_id")
    if not parent_id:
        parent_id = ensure_parent(client, ws_id)
        mapping["parent_doc_id"] = parent_id
    return ws_id, parent_id


def sync(path):
    title = title_for(path)
    content = path.read_text()
    token = TOKEN_PATH.read_text().strip()
    mapping = load_map()

    client = MCP(token)
    client.init()
    ws_id, parent_id = resolve_workspace_and_parent(client, mapping)

    existing_id = mapping["files"].get(path.name)
    if not existing_id:
        # Map miss: try to bind to an existing doc with the same title
        # (covers the case where the map was deleted but docs already exist).
        existing_id = find_doc_by_exact_title(client, ws_id, title)
        if existing_id:
            log(f"REBIND  {path.name} title='{title}' docId={existing_id}")

    if existing_id:
        result = client.call("replace_doc_with_markdown", {
            "workspaceId": ws_id,
            "docId": existing_id,
            "markdown": content,
        })
        ok = result.get("ok") if isinstance(result, dict) else None
        log(f"REPLACE {path.name} title='{title}' docId={existing_id} ok={ok}")
        mapping["files"][path.name] = existing_id
    else:
        result = client.call("create_doc_from_markdown", {
            "workspaceId": ws_id,
            "title": title,
            "markdown": content,
            "parentDocId": parent_id,
        })
        new_id = result.get("docId") if isinstance(result, dict) else None
        log(f"CREATE  {path.name} title='{title}' docId={new_id}")
        if new_id:
            mapping["files"][path.name] = new_id

    save_map(mapping)


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception as e:
        log(f"bad-stdin: {type(e).__name__}: {e}")
        return

    if payload.get("tool_name") not in ("Write", "Edit"):
        return

    file_path = (payload.get("tool_input") or {}).get("file_path")
    if not file_path:
        return

    try:
        path = Path(file_path).resolve()
    except Exception:
        return

    try:
        path.relative_to(MEM_DIR)
    except ValueError:
        return  # not in the memory dir, ignore silently

    if path.suffix != ".md" or not path.exists():
        return

    try:
        sync(path)
    except Exception as e:
        log(f"FAIL {path.name}: {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
