"""messaging-mcp: stdio MCP over Nico's bridged chats.

Two servers from one binary, so Hermes can gate them apart:
  messaging-mcp          read-only: list_chats, read_chat, search_messages
  messaging-mcp --send   send_message only (Hermes marks it untrusted)
Env: MATRIX_HOMESERVER, MATRIX_USER_ID, MATRIX_TOKEN_FILE.
"""

import sys
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone

from .. import mcpstdio
from ..logs import logger
from ..secrets import env_str
from .matrix import BRIDGE_TYPES, Matrix, token_from_env_file

log = logger("messaging-mcp", lambda: sys.stderr)
SERVER = {"name": "messaging", "version": "0.1.0"}

_STR = {"type": "string"}
_INT = {"type": "integer"}


def _schema(props, required=()):
    return {"type": "object", "properties": props, "required": list(required)}


READ_TOOLS = {
    "list_chats": {
        "description": (
            "Conversations of Nico's on every bridged network (WhatsApp, Signal, Telegram, "
            "Instagram, Slack, Discord, LinkedIn, X), "
            "most recent first, with the last message and the unread count."
        ),
        "inputSchema": _schema(
            {
                "network": {
                    **_STR,
                    "description": "whatsapp, signal, telegram, instagram, slack, discord, linkedin, twitter. Default: all.",
                },
                "unread_only": {"type": "boolean"},
                "limit": {**_INT, "description": "Default 30"},
            }
        ),
    },
    "read_chat": {
        "description": "Latest messages of one conversation (room_id from list_chats), oldest first.",
        "inputSchema": _schema(
            {"room_id": _STR, "limit": {**_INT, "description": "Default 30, max 200"}},
            ["room_id"],
        ),
    },
    "search_messages": {
        "description": "Full-text search across every bridged conversation, most recent first.",
        "inputSchema": _schema(
            {"query": _STR, "limit": {**_INT, "description": "Default 20"}},
            ["query"],
        ),
    },
}

SEND_TOOLS = {
    "send_message": {
        "description": (
            "Send a text message as Nico in one conversation (room_id from list_chats). "
            "It goes out on the real network: the recipient sees it from Nico."
        ),
        "inputSchema": _schema({"room_id": _STR, "text": _STR}, ["room_id", "text"]),
    },
}


@dataclass(frozen=True)
class Config:
    homeserver: str
    user_id: str
    token_file: str

    @classmethod
    def from_env(cls, env=None):
        return cls(
            homeserver=env_str("MATRIX_HOMESERVER", "http://127.0.0.1:6167", env),
            user_id=env_str("MATRIX_USER_ID", "", env),
            token_file=env_str(
                "MATRIX_TOKEN_FILE",
                "/var/lib/matrix-doublepuppet/doublepuppet.env",
                env,
            ),
        )


def _ts(ms):
    return datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat(timespec="seconds")


def _state(room, etype):
    for ev in (room.get("state") or {}).get("events", []):
        if ev.get("type") == etype:
            return ev.get("content") or {}
    return None


def network_of(room):
    for etype in BRIDGE_TYPES:
        content = _state(room, etype)
        if content and (content.get("protocol") or {}).get("id"):
            return content["protocol"]["id"]
    return None


def _name(room, room_id):
    named = _state(room, "m.room.name") or {}
    if named.get("name"):
        return named["name"]
    heroes = (room.get("summary") or {}).get("m.heroes") or []
    return ", ".join(heroes) or room_id


def _message(ev, names=None):
    content = ev.get("content") or {}
    return {
        "sender": (names or {}).get(ev.get("sender"), ev.get("sender")),
        "time": _ts(ev.get("origin_server_ts", 0)),
        "body": content.get("body", ""),
        "type": content.get("msgtype", ""),
    }


class Handlers:
    """Tool bodies. `matrix` is the seam."""

    def __init__(self, matrix):
        self.matrix = matrix

    def list_chats(self, network=None, unread_only=False, limit=30):
        rooms = (self.matrix.sync().get("rooms") or {}).get("join") or {}
        chats = []
        for room_id, room in rooms.items():
            net = network_of(room)
            if net is None or (network and net != network):
                continue  # management rooms (bridge bots, spaces) carry no m.bridge
            unread = (room.get("unread_notifications") or {}).get(
                "notification_count", 0
            )
            if unread_only and not unread:
                continue
            events = (room.get("timeline") or {}).get("events") or []
            last = events[-1] if events else None
            chats.append(
                {
                    "room_id": room_id,
                    "name": _name(room, room_id),
                    "network": net,
                    "unread": unread,
                    "last": _message(last) if last else None,
                    "_ts": last.get("origin_server_ts", 0) if last else 0,
                }
            )
        chats.sort(key=lambda c: c["_ts"], reverse=True)
        for c in chats:
            del c["_ts"]
        return {"chats": chats[: max(1, int(limit))]}

    def read_chat(self, room_id, limit=30):
        limit = min(max(1, int(limit)), 200)
        names = {
            uid: (m.get("display_name") or uid)
            for uid, m in (self.matrix.members(room_id).get("joined") or {}).items()
        }
        events = self.matrix.messages(room_id, limit).get("chunk") or []
        return {
            "room_id": room_id,
            "messages": [_message(ev, names) for ev in reversed(events)],
        }

    def search_messages(self, query, limit=20):
        found = (
            (
                (
                    self.matrix.search(query, int(limit)).get("search_categories") or {}
                ).get("room_events")
            )
            or {}
        ).get("results") or []
        return {
            "results": [
                {"room_id": r["result"].get("room_id"), **_message(r["result"])}
                for r in found
                if r.get("result")
            ]
        }

    def send_message(self, room_id, text):
        if not text.strip():
            raise ValueError("message vide")
        return {"event_id": self.matrix.send_text(room_id, text).get("event_id")}


def main(argv=None, env=None, matrix=None, stdin=None, stdout=None):
    argv = sys.argv[1:] if argv is None else argv
    tools = SEND_TOOLS if "--send" in argv else READ_TOOLS
    if matrix is None:
        cfg = Config.from_env(env)
        if not cfg.user_id:
            log("FATAL: MATRIX_USER_ID unset")
            return 2
        # Loopback: never through hermes' Agent Vault proxy.
        direct = urllib.request.build_opener(urllib.request.ProxyHandler({})).open
        matrix = Matrix(
            cfg.homeserver,
            cfg.user_id,
            token_from_env_file(cfg.token_file),
            opener=direct,
        )
    mcpstdio.serve(tools, Handlers(matrix), SERVER, log, stdin, stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
