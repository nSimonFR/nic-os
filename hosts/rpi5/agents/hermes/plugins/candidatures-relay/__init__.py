"""candidatures-relay — hook ``pre_gateway_dispatch`` (avant auth et avant tout LLM).

- Une seule conversation est détournée : la dernière liée par « /lier_candidatures »
  (envoyé par un membre autorisé dans un groupe où se trouve le bot ; relier ailleurs déplace la liaison).
- Chaque message de cette conversation est ajouté à ``inbox.jsonl`` puis avalé
  (``{"action": "skip"}``) : Hermes ne le voit pas, ne le stocke pas, n'y répond pas.
- Le pont du Mac lit la file par SSH et répond lui-même via l'API Bot.
- Sauf les expéditeurs listés dans ``passthrough_users`` : leurs messages vont à Hermes, qui les
  route vers le profil « candidatures » (essai avant la bascule).
Tout le reste passe inchangé. En cas d'erreur, le message est quand même avalé s'il vient
de la conversation liée (fail-closed : on ne veut pas qu'Hermes réponde à sa place).
"""

from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path

logger = logging.getLogger("hermes_plugins.candidatures_relay")

HOME = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes")) / "candidatures"
CHAT_FILE = HOME / "chat_id"
INBOX = HOME / "inbox.jsonl"
# One user id per line: their messages in the bound chat are NOT diverted, so Hermes routes
# them (gateway.profile_routes -> the "candidatures" profile). Read on every message.
PASSTHROUGH = HOME / "passthrough_users"
# Nico et Alfie (chat_id d'un DM == user id)
MEMBERS = {"82389391", "8627259779"}
BIND_CMD = "/lier_candidatures"


def _bound_chat() -> str | None:
    try:
        return CHAT_FILE.read_text().strip() or None
    except OSError:
        return None


def _passthrough() -> set[str]:
    try:
        return {l.strip() for l in PASSTHROUGH.read_text().splitlines() if l.strip()}
    except OSError:
        return set()


def _document(event) -> dict | None:
    raw = getattr(event, "raw_message", None)
    for obj in (
        raw,
        getattr(raw, "message", None),
        getattr(raw, "effective_message", None),
    ):
        doc = getattr(obj, "document", None)
        if doc is not None:
            return {
                "file_id": getattr(doc, "file_id", None),
                "file_name": getattr(doc, "file_name", None),
                "mime_type": getattr(doc, "mime_type", None),
            }
    return None


def _append(record: dict) -> None:
    HOME.mkdir(parents=True, exist_ok=True)
    with open(INBOX, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def _on_dispatch(event=None, **_kw):
    src = getattr(event, "source", None)
    if (
        src is None
        or str(getattr(src, "platform", "telegram")).lower().split(".")[-1]
        != "telegram"
    ):
        return None
    chat = str(getattr(src, "chat_id", "") or "")
    user = str(getattr(event, "user_id", None) or getattr(src, "user_id", "") or "")
    text = (getattr(event, "text", "") or "").strip()
    bound = _bound_chat()

    if (
        text.split("@")[0].split(" ")[0] == BIND_CMD
        and user in MEMBERS
        and chat.startswith("-")
    ):
        # Re-binding moves the conversation (e.g. a group upgraded to a supergroup gets a new id).
        HOME.mkdir(parents=True, exist_ok=True)
        CHAT_FILE.write_text(chat)
        _append(
            {
                "ts": time.time(),
                "chat_id": chat,
                "user_id": user,
                "kind": "bound",
                "text": text,
            }
        )
        logger.info("candidatures-relay: conversation liée %s", chat)
        return {"action": "skip", "reason": "candidatures-relay: liaison"}

    if not bound or chat != bound:
        return None
    if user in _passthrough():
        return None
    try:
        _append(
            {
                "ts": time.time(),
                "chat_id": chat,
                "user_id": user,
                "kind": "message",
                "message_id": getattr(event, "message_id", None),
                "text": text,
                "reply_to_own": bool(getattr(event, "reply_to_is_own_message", False)),
                "reply_to_text": (getattr(event, "reply_to_text", None) or "")[:2000],
                "document": _document(event),
                "media_urls": list(getattr(event, "media_urls", []) or []),
            }
        )
    except Exception:  # noqa: BLE001
        logger.exception("candidatures-relay: écriture impossible")
    return {"action": "skip", "reason": "candidatures-relay"}


def register(ctx):
    ctx.register_hook("pre_gateway_dispatch", _on_dispatch)
