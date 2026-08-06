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

Config via environment (all optional — the defaults are the live paths):
  MEMORY_SYNC_PROJECTS_DIR   default ~/.claude/projects
  MEMORY_SYNC_MCP_URL        default http://127.0.0.1:7021/mcp
  MEMORY_SYNC_TOKEN_PATH     default /run/agenix/affine-mcp-http-token
  MEMORY_SYNC_MAP_PATH       default ~/.claude/state/memory-sync-map.json
  MEMORY_SYNC_LOG_PATH       default ~/.claude/logs/memory-sync.log
"""

import json
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from ..secrets import env_str

DEFAULT_MCP_URL = "http://127.0.0.1:7021/mcp"
DEFAULT_TOKEN_PATH = "/run/agenix/affine-mcp-http-token"
PARENT_TITLE = "Claude Memory"


@dataclass(frozen=True)
class Config:
    projects_dir: Path = None
    mcp_url: str = DEFAULT_MCP_URL
    token_path: Path = None
    map_path: Path = None
    log_path: Path = None
    parent_title: str = PARENT_TITLE

    @classmethod
    def from_env(cls, env=None, home=None):
        home = Path(home or env_str("HOME", str(Path.home()), env))

        def path_of(name, default):
            return Path(env_str(name, "", env) or default)

        return cls(
            projects_dir=path_of("MEMORY_SYNC_PROJECTS_DIR", home / ".claude/projects"),
            mcp_url=env_str("MEMORY_SYNC_MCP_URL", DEFAULT_MCP_URL, env),
            token_path=path_of("MEMORY_SYNC_TOKEN_PATH", DEFAULT_TOKEN_PATH),
            map_path=path_of("MEMORY_SYNC_MAP_PATH",
                             home / ".claude/state/memory-sync-map.json"),
            log_path=path_of("MEMORY_SYNC_LOG_PATH",
                             home / ".claude/logs/memory-sync.log"),
        )


def make_log(cfg):
    def log(msg):
        try:
            cfg.log_path.parent.mkdir(parents=True, exist_ok=True)
            with cfg.log_path.open("a") as f:
                f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}\n")
        except Exception:  # noqa: BLE001 — a hook must never fail on its own log
            pass

    return log


def load_map(cfg):
    if cfg.map_path.exists():
        try:
            data = json.loads(cfg.map_path.read_text())
            data.setdefault("files", {})
            return data
        except Exception:  # noqa: BLE001
            pass
    return {"files": {}}


def save_map(cfg, m):
    cfg.map_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = cfg.map_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(m, indent=2, sort_keys=True))
    tmp.replace(cfg.map_path)


def project_and_file(cfg, path):
    """Return (project_slug, filename) if path is <PROJECTS>/<slug>/memory/<file>.md,
    else None."""
    try:
        parts = Path(path).relative_to(cfg.projects_dir).parts
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
    """Streamable-HTTP MCP client (affine-mcp's bridge speaks SSE-framed JSON-RPC).

    `opener` is the seam — tests hand it canned `data:` frames.
    """

    def __init__(self, url, token, opener=None):
        self.url = url
        self.token = token
        self.opener = opener or urllib.request.urlopen
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
            self.url, data=json.dumps(body).encode(), headers=headers, method="POST"
        )
        with self.opener(req, timeout=30) as resp:
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


def ensure_parent(client, ws_id, parent_title=PARENT_TITLE):
    parent_id = find_doc_by_exact_title(client, ws_id, parent_title)
    if parent_id:
        return parent_id
    res = client.call("create_doc_from_markdown", {
        "workspaceId": ws_id,
        "title": parent_title,
        "markdown": f"# {parent_title}\n\nAuto-mirrored from `~/.claude/projects/*/memory/`.\n",
    })
    if not res.get("docId"):
        raise RuntimeError(f"could not create '{parent_title}' page: {res}")
    return res["docId"]


def resolve_workspace_and_parent(cfg, client, mapping):
    if not mapping.get("workspace_id"):
        mapping["workspace_id"] = first_workspace_id(client)
    if not mapping.get("parent_doc_id"):
        mapping["parent_doc_id"] = ensure_parent(client, mapping["workspace_id"],
                                                 cfg.parent_title)
    return mapping["workspace_id"], mapping["parent_doc_id"]


def sync(cfg, path, project_slug, file_name, client=None, log=None):
    log = log or make_log(cfg)
    path = Path(path)
    content = path.read_text()
    title = title_for(path, content)
    mapping = load_map(cfg)

    if client is None:
        token = cfg.token_path.read_text().strip()
        client = MCP(cfg.mcp_url, token)
        client.init()
    ws_id, parent_id = resolve_workspace_and_parent(cfg, client, mapping)

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
            "workspaceId": ws_id, "title": title, "markdown": content,
            "parentDocId": parent_id,
        })
        new_id = result.get("docId")
        log(f"CREATE  {map_key} title='{title}' docId={new_id}")
        if new_id:
            mapping["files"][map_key] = new_id

    save_map(cfg, mapping)
    return mapping


def main(env=None, stdin=None, client=None):
    cfg = Config.from_env(env)
    log = make_log(cfg)
    try:
        payload = json.load(stdin or sys.stdin)
    except Exception as e:  # noqa: BLE001
        log(f"bad-stdin: {type(e).__name__}: {e}")
        return 0

    if payload.get("tool_name") not in ("Write", "Edit"):
        return 0

    file_path = (payload.get("tool_input") or {}).get("file_path")
    if not file_path:
        return 0

    path = Path(file_path).resolve()
    pf = project_and_file(cfg, path)
    if not pf or not path.exists():
        return 0

    project_slug, file_name = pf
    try:
        sync(cfg, path, project_slug, file_name, client=client, log=log)
    except Exception as e:  # noqa: BLE001 — a hook must never block Claude Code
        log(f"FAIL {path.name}: {type(e).__name__}: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
