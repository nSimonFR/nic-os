"""Minimal Matrix client-server API, acting as Nico through the double-puppet
appservice token (`?user_id=` masquerade): no password, no device, no sync state.

Rooms are bridged portals, unencrypted, so message bodies are plain events.
"""

import json
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path

from ..httpjson import http_json

# The bridges tag their portals with m.bridge (MSC2346); older ones use the
# half-shot key. `protocol.id` is the network.
BRIDGE_TYPES = ("m.bridge", "uk.half-shot.bridge")

# A lazy /sync: one event per room, only the state that names it.
SYNC_FILTER = {
    "presence": {"types": []},
    "account_data": {"types": []},
    "room": {
        "timeline": {"limit": 1, "types": ["m.room.message"]},
        "state": {
            "types": ["m.room.name", "m.room.canonical_alias", *BRIDGE_TYPES],
            "lazy_load_members": True,
        },
        "ephemeral": {"types": []},
        "account_data": {"types": []},
    },
}


def token_from_env_file(path):
    """DOUBLEPUPPET_TOKEN from the env file matrix-doublepuppet-setup writes."""
    for line in Path(path).read_text().splitlines():
        key, _, value = line.partition("=")
        if key.strip() == "DOUBLEPUPPET_TOKEN":
            return value.strip()
    raise KeyError(f"DOUBLEPUPPET_TOKEN absent de {path}")


@dataclass(frozen=True)
class Matrix:
    homeserver: str
    user_id: str
    token: str
    opener: object = None
    timeout: int = 60

    def _call(self, method, path, query=None, body=None):
        q = {"user_id": self.user_id, **(query or {})}
        url = f"{self.homeserver}/_matrix/client/v3{path}?{urllib.parse.urlencode(q)}"
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        return http_json(req, timeout=self.timeout, opener=self.opener)

    def sync(self):
        return self._call(
            "GET",
            "/sync",
            {"filter": json.dumps(SYNC_FILTER, separators=(",", ":")), "timeout": "0"},
        )

    def messages(self, room_id, limit):
        path = f"/rooms/{urllib.parse.quote(room_id)}/messages"
        return self._call(
            "GET",
            path,
            {
                "dir": "b",
                "limit": str(limit),
                "filter": json.dumps(
                    {"types": ["m.room.message"], "lazy_load_members": True}
                ),
            },
        )

    def members(self, room_id):
        return self._call("GET", f"/rooms/{urllib.parse.quote(room_id)}/joined_members")

    def search(self, term, limit):
        body = {
            "search_categories": {
                "room_events": {
                    "search_term": term,
                    "keys": ["content.body"],
                    "order_by": "recent",
                    "filter": {"limit": limit},
                }
            }
        }
        return self._call("POST", "/search", body=body)

    def send_text(self, room_id, text):
        path = f"/rooms/{urllib.parse.quote(room_id)}/send/m.room.message/{uuid.uuid4().hex}"
        return self._call("PUT", path, body={"msgtype": "m.text", "body": text})
