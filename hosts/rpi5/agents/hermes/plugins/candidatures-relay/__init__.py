"""candidatures-relay — hook ``pre_gateway_dispatch`` (avant auth et avant tout LLM).

- Une seule conversation est détournée : celle liée par « /lier_candidatures »
  (envoyé par un membre autorisé dans un groupe où se trouve le bot).
- Chaque message de cette conversation est ajouté à ``inbox.jsonl`` puis avalé
  (``{"action": "skip"}``) : Hermes ne le voit pas, ne le stocke pas, n'y répond pas.
- Le pont du Mac lit la file par SSH et répond lui-même via l'API Bot.
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
# Nico et Alfie (chat_id d'un DM == user id)
MEMBERS = {"82389391", "8627259779"}
BIND_CMD = "/lier_candidatures"


def _bound_chat() -> str | None:
    try:
        return CHAT_FILE.read_text().strip() or None
    except OSError:
        return None


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
        if bound and bound != chat:
            return None  # déjà lié ailleurs : on laisse Hermes répondre normalement
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
                "document": _document(event),
                "media_urls": list(getattr(event, "media_urls", []) or []),
            }
        )
    except Exception:  # noqa: BLE001
        logger.exception("candidatures-relay: écriture impossible")
    return {"action": "skip", "reason": "candidatures-relay"}


def register(ctx):
    ctx.register_hook("pre_gateway_dispatch", _on_dispatch)
