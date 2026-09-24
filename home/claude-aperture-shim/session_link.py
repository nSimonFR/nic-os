"""Keep one Aperture session across Claude Code auto-compactions.

Auto-compaction forks the conversation under a new session id
(anthropics/claude-code#79830) and Aperture groups requests by the raw
`metadata.user_id` string, so every compaction opened a new Aperture session.
The fork's first message names its parent's transcript; each descendant is mapped
back to the root of its chain.
"""

import json
import os
import re
from pathlib import Path

CONTINUATION = "This session is being continued from a previous conversation"
_PARENT = re.compile(
    r"read the full transcript at: \S*?"
    r"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl"
)


def _first_message_texts(body: dict) -> list[str]:
    messages = body.get("messages") or []
    if not messages or not isinstance(messages[0], dict):
        return []
    content = messages[0].get("content")
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        return [b.get("text", "") for b in content if isinstance(b, dict)]
    return []


def parent_of(body: dict) -> str | None:
    """Session id this request's conversation was compacted from, if any."""
    for text in _first_message_texts(body):
        if text.lstrip().startswith(CONTINUATION):
            m = _PARENT.search(text)
            return m.group(1) if m else None
    return None


def _user_id(body: dict) -> dict | None:
    raw = (body.get("metadata") or {}).get("user_id")
    if not isinstance(raw, str):
        return None
    try:
        user_id = json.loads(raw)
    except ValueError:
        return None
    return user_id if isinstance(user_id, dict) else None


def session_of(body: dict) -> str | None:
    user_id = _user_id(body)
    sid = user_id.get("session_id") if user_id else None
    return sid if isinstance(sid, str) and sid else None


def set_session(body: dict, old: str, new: str) -> None:
    # Swap the id inside the original string: Aperture fingerprints the raw
    # user_id, so re-serialising it (even whitespace) lands in another session.
    raw = body["metadata"]["user_id"]
    body["metadata"]["user_id"] = raw.replace(f'"{old}"', f'"{new}"', 1)


class SessionLinks:
    """child -> parent session ids, persisted so a chain survives a shim restart."""

    def __init__(self, path: Path):
        self.path = path
        try:
            data = json.loads(path.read_text())
            self.parents = {k: v for k, v in data.items() if isinstance(v, str)}
        except (OSError, ValueError, AttributeError):
            self.parents = {}

    def root(self, sid: str) -> str:
        seen = {sid}
        while (parent := self.parents.get(sid)) and parent not in seen:
            seen.add(parent)
            sid = parent
        return sid

    def observe(self, sid: str, parent: str | None) -> None:
        if not parent or parent == sid or self.parents.get(sid) == parent:
            return
        self.parents[sid] = parent
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.parents, indent=1, sort_keys=True))
        os.replace(tmp, self.path)

    def link(self, body: dict) -> str | None:
        """Rewrite body's session id to its chain root; return the root if changed."""
        sid = session_of(body)
        if sid is None:
            return None
        self.observe(sid, parent_of(body))
        root = self.root(sid)
        if root == sid:
            return None
        set_session(body, sid, root)
        return root
