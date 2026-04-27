#!/usr/bin/env python3
"""Mirror Claude Code memory writes into AFFiNE Wiki/Pages/Claude Memory/.

Wired as a PostToolUse hook on Write|Edit (see claude-settings.json).
Reads the hook payload from stdin:
    {"tool_name": "Write|Edit", "tool_input": {"file_path": ..., ...}, ...}

Matches any file under ~/.claude/projects/<project-slug>/memory/*.md and
upserts a child doc under the AFFiNE "Claude Memory" parent page. The
project slug is namespaced into the cache key so two projects with the
same memory filename (e.g. both have MEMORY.md) cannot stomp on each
other; cross-project title collisions also get a fresh doc rather than
reusing one already bound to another project.

No IDs are baked in: workspace_id and parent_doc_id are resolved on
first run via list_workspaces + search_docs and cached in
~/.claude/state/memory-sync-map.json alongside (project/file → docId).
Per-file misses fall back to a title search before creating, so a
fresh map re-binds to existing docs without duplicating them.

Always exits 0; never blocks Claude Code. Errors land in
~/.claude/logs/memory-sync.log.
"""
import json
import sys
import time
import urllib.request
from pathlib import Path

PROJECTS_DIR = Path.home() / ".claude" / "projects"
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


def project_and_file(path):
    """Return (project_slug, filename) if path is <PROJECTS>/<slug>/memory/<file>.md, else None."""
    try:
        parts = path.relative_to(PROJECTS_DIR).parts
    except ValueError:
        return None
    if len(parts) < 3 or parts[1] != "memory" or not parts[-1].endswith(".md"):
        return None
    return parts[0], parts[-1]


def title_for(path, content):
    if content.startswith("---"):
        for line in content.splitlines()[:10]:
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

    def _post(self, body, notify=False):
        if not notify:
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
            MCP_URL, data=json.dumps(body).encode(), headers=headers, method="POST"
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            sid = resp.headers.get("Mcp-Session-Id")
            if sid and not self.session:
                self.session = sid
            raw = resp.read().decode()
        if notify:
            return None
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
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized"}, notify=True)

    def call(self, name, args):
        res = self._post({
            "jsonrpc": "2.0",
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        })
        return json.loads(res["content"][0]["text"])


def first_workspace_id(client):
    res = client.call("list_workspaces", {})
    if res:
        return res[0]["id"]
    raise RuntimeError("no workspaces")


def find_doc_by_exact_title(client, ws_id, title):
    """Return docId of a doc whose title matches `title` exactly, or None."""
    res = client.call("search_docs", {"workspaceId": ws_id, "query": title, "limit": 20})
    for r in res.get("results", []):
        if r.get("title") == title:
            return r.get("id") or r.get("docId")
    return None


def ensure_parent(client, ws_id):
    parent_id = find_doc_by_exact_title(client, ws_id, PARENT_TITLE)
    if parent_id:
        return parent_id
    res = client.call("create_doc_from_markdown", {
        "workspaceId": ws_id,
        "title": PARENT_TITLE,
        "markdown": f"# {PARENT_TITLE}\n\nAuto-mirrored from `~/.claude/projects/*/memory/`.\n",
    })
    if not res.get("docId"):
        raise RuntimeError(f"could not create '{PARENT_TITLE}' page: {res}")
    return res["docId"]


def resolve_workspace_and_parent(client, mapping):
    if not mapping.get("workspace_id"):
        mapping["workspace_id"] = first_workspace_id(client)
    if not mapping.get("parent_doc_id"):
        mapping["parent_doc_id"] = ensure_parent(client, mapping["workspace_id"])
    return mapping["workspace_id"], mapping["parent_doc_id"]


def sync(path, project_slug, file_name):
    content = path.read_text()
    title = title_for(path, content)
    token = TOKEN_PATH.read_text().strip()
    mapping = load_map()

    client = MCP(token)
    client.init()
    ws_id, parent_id = resolve_workspace_and_parent(client, mapping)

    map_key = f"{project_slug}/{file_name}"
    # Migrate legacy single-file keys (pre-multi-project) to namespaced keys.
    existing_id = mapping["files"].get(map_key) or mapping["files"].pop(file_name, None)

    if not existing_id:
        # Map miss — try to rebind to an existing doc with this title, but
        # only if no other project already claims it (otherwise we'd overwrite).
        candidate = find_doc_by_exact_title(client, ws_id, title)
        if candidate and candidate not in mapping["files"].values():
            existing_id = candidate
            log(f"REBIND  {map_key} title='{title}' docId={existing_id}")

    if existing_id:
        result = client.call("replace_doc_with_markdown", {
            "workspaceId": ws_id, "docId": existing_id, "markdown": content,
        })
        log(f"REPLACE {map_key} title='{title}' docId={existing_id} ok={result.get('ok')}")
        mapping["files"][map_key] = existing_id
    else:
        result = client.call("create_doc_from_markdown", {
            "workspaceId": ws_id, "title": title, "markdown": content, "parentDocId": parent_id,
        })
        new_id = result.get("docId")
        log(f"CREATE  {map_key} title='{title}' docId={new_id}")
        if new_id:
            mapping["files"][map_key] = new_id

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

    path = Path(file_path).resolve()
    pf = project_and_file(path)
    if not pf or not path.exists():
        return

    project_slug, file_name = pf
    try:
        sync(path, project_slug, file_name)
    except Exception as e:
        log(f"FAIL {path.name}: {type(e).__name__}: {e}")


if __name__ == "__main__":
    main()
