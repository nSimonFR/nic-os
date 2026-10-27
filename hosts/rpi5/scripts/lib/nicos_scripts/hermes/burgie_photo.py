#!/usr/bin/env python3
"""
hermes-burgie-photo: one random image from the Burgiiiiiiie Immich album, sent as a
Telegram photo to the chat the cron job was created from.

Immich goes through Agent Vault (`immich.home.arpa`, placeholder key): the real
key is root-only, so reading /run/agenix/immich-api-key is EACCES. The chat is the
job's `origin` in jobs.json. Prints nothing on success; a non-zero exit is the
scheduler's alert.

Env: IMMICH_{URL,API_KEY}, BURGIE_{JOB_ID,ALBUM_MATCH}, HERMES_HOME,
TELEGRAM_TOKEN_FILE.
"""

import json
import os
import secrets
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from ..httpjson import get_json, http_json
from ..logs import logger
from ..secrets import env_str, read_secret

log = logger("hermes-burgie-photo", lambda: sys.stderr)

DEFAULT_IMMICH = "http://immich.home.arpa:2283"
PLACEHOLDER_KEY = "__immich_api_key__"


@dataclass(frozen=True)
class Config:
    immich_url: str = DEFAULT_IMMICH
    api_key: str = PLACEHOLDER_KEY
    job_id: str = "5eb0b7dd6e7f"
    album_match: str = "burg"
    hermes_home: str = "~/.hermes"
    token_file: str = "/run/agenix/telegram-bot-token"

    @classmethod
    def from_env(cls, env=None):
        return cls(
            immich_url=env_str("IMMICH_URL", DEFAULT_IMMICH, env).rstrip("/"),
            api_key=env_str("IMMICH_API_KEY", "", env) or PLACEHOLDER_KEY,
            job_id=env_str("BURGIE_JOB_ID", cls.job_id, env),
            album_match=env_str("BURGIE_ALBUM_MATCH", cls.album_match, env).casefold(),
            hermes_home=os.path.expanduser(env_str("HERMES_HOME", "~/.hermes", env)),
            token_file=env_str("TELEGRAM_TOKEN_FILE", cls.token_file, env),
        )


def origin_chat(jobs, job_id):
    job = next((j for j in jobs if j.get("id") == job_id), None)
    chat = ((job or {}).get("origin") or {}).get("chat_id")
    if not chat:
        raise RuntimeError(f"job {job_id} has no origin chat")
    return str(chat)


def pick_album(albums, match):
    hits = [a for a in albums if match in (a.get("albumName") or "").casefold()]
    if len(hits) != 1:
        raise RuntimeError(f"album match {match!r} is not unique ({len(hits)})")
    return hits[0]


def album_images(cfg, album, opener=None):
    """Every IMAGE asset of `album`; refuses a partial page."""
    req = urllib.request.Request(
        f"{cfg.immich_url}/api/search/metadata",
        data=json.dumps({"albumIds": [album["id"]], "size": 1000}).encode(),
        headers={"x-api-key": cfg.api_key, "Content-Type": "application/json"},
        method="POST",
    )
    assets = http_json(req, timeout=60, opener=opener)["assets"]
    if assets.get("total") != album.get("assetCount"):
        raise RuntimeError("album scope verification failed")
    images = [a for a in assets.get("items") or [] if a.get("type") == "IMAGE"]
    if not images:
        raise RuntimeError("album contains no images")
    return images


def preview(cfg, asset_id, opener=None):
    req = urllib.request.Request(
        f"{cfg.immich_url}/api/assets/{asset_id}/thumbnail?size=preview",
        headers={"x-api-key": cfg.api_key},
    )
    with (opener or urllib.request.urlopen)(req, timeout=60) as resp:
        image = resp.read()
    if not image:
        raise RuntimeError("selected preview is empty")
    return image


def send_photo(token, chat_id, image, opener=None):
    boundary = "----Hermes" + secrets.token_hex(16)
    body = (
        f'--{boundary}\r\nContent-Disposition: form-data; name="chat_id"\r\n\r\n{chat_id}\r\n'
        f'--{boundary}\r\nContent-Disposition: form-data; name="photo"; filename="burgie.jpg"\r\n'
        "Content-Type: image/jpeg\r\n\r\n"
    ).encode() + image + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendPhoto",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    result = http_json(req, timeout=60, opener=opener)
    sent_to = str(((result.get("result") or {}).get("chat") or {}).get("id"))
    if not result.get("ok") or sent_to != chat_id:
        raise RuntimeError("Telegram delivery verification failed")


def run(cfg, opener=None, choice=secrets.choice, token=None):
    jobs = json.loads(Path(cfg.hermes_home, "cron", "jobs.json").read_text())
    chat_id = origin_chat(jobs.get("jobs", jobs) if isinstance(jobs, dict) else jobs, cfg.job_id)

    albums = get_json(
        f"{cfg.immich_url}/api/albums?withAssets=false",
        {"x-api-key": cfg.api_key},
        opener=opener,
    )
    album = pick_album(albums, cfg.album_match)
    asset = choice(album_images(cfg, album, opener=opener))
    image = preview(cfg, asset["id"], opener=opener)
    send_photo(token or read_secret(cfg.token_file), chat_id, image, opener=opener)
    log(f"sent {asset['id']} from {album.get('albumName')!r} to {chat_id}")


def main(argv=None, env=None):
    del argv
    try:
        run(Config.from_env(env))
    except (urllib.error.URLError, OSError, ValueError, KeyError, RuntimeError) as e:
        log(f"FATAL: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
