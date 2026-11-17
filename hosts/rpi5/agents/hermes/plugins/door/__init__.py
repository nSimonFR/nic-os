"""door — ``/door [30m|2h|off|status]``: an auto-open window for the hall door.

Writes the window's end to ``sensor.door_auto_open_until`` in Home Assistant; the HA
automation ``door_auto_open`` unlocks the Intratone door on a ring while it is in the
future and reports a failed unlock; ``door_auto_open_shutdown`` warns when an HA
restart closes an open window (a REST-set state is not restored). Both are in
hosts/rpi5/home-assistant/automations/door.yaml.
Nico's DM and the group with Alfie only; « Alfie Postule ! » (her job-search group) stays out.
"""

from __future__ import annotations

import json
import logging
import os
import re
import urllib.request
from datetime import datetime, timedelta, timezone

logger = logging.getLogger("hermes_plugins.door")

ALLOWED_CHATS = {
    "82389391",  # Nico's DM (a DM's chat_id == user id)
    "-1003356011841",  # group "nSimon, ServaTilis and Alfie"
}
SENSOR = "sensor.door_auto_open_until"
# Agent Vault (HTTP_PROXY) swaps the placeholder for the real token.
TOKEN = "__ha_token__"
# Everything the window depends on, as a JSON list of problems. A rotated push
# token leaves push_channel_connected "on": only the repair says rings stopped.
HEALTH = """{%- set ns = namespace(p=[]) -%}
{%- for i in issues() | list | map('join', '/') | select('match', 'intratone/') -%}
  {%- set ns.p = ns.p + ['repair:' ~ i.split('/')[1]] -%}
{%- endfor -%}
{%- if not is_state('binary_sensor.intratone_push_channel_connected', 'on') -%}
  {%- set ns.p = ns.p + ['push:' ~ states('binary_sensor.intratone_push_channel_connected')] -%}
{%- endif -%}
{%- for e in ['lock.intratone_door', 'event.intratone_doorbell'] -%}
  {%- if states(e) in ['unavailable', 'unknown'] -%}{%- set ns.p = ns.p + ['entity:' ~ e] -%}{%- endif -%}
{%- endfor -%}
{%- if not is_state('automation.door_auto_open_window', 'on') -%}
  {%- set ns.p = ns.p + ['automation:' ~ states('automation.door_auto_open_window')] -%}
{%- endif -%}
{{ ns.p | to_json }}"""


def describe(problem: str) -> str:
    kind, _, detail = problem.partition(":")
    if kind == "repair" and detail.startswith("fcm_token_stale"):
        return "Rings no longer reach Home Assistant (Intratone push token rotated). Re-pair: HA → Settings → Repairs."
    if kind == "repair":
        return f"Intratone repair pending ({detail}): HA → Settings → Repairs."
    if kind == "push":
        return f"Intratone push channel is {detail}: rings won't reach Home Assistant."
    if kind == "entity":
        return f"{detail} is unavailable: the Intratone integration isn't running."
    if kind == "automation":
        return f"HA automation door_auto_open is {detail}: nothing will open on a ring."
    return problem


DEFAULT = timedelta(hours=1)
MAX = timedelta(hours=12)


def parse_duration(arg: str) -> timedelta | None:
    """``""`` → 1h; ``30m``, ``2h``, ``1h30m``, ``45`` (minutes). None if unparseable."""
    arg = arg.strip().lower()
    if not arg:
        return DEFAULT
    if arg.isdigit():
        return timedelta(minutes=int(arg))
    m = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m(?:in)?)?", arg)
    if not m or not any(m.groups()):
        return None
    return timedelta(hours=int(m[1] or 0), minutes=int(m[2] or 0))


def _ha(
    method: str, path: str, body: dict | None = None, opener=urllib.request.urlopen
):
    req = urllib.request.Request(
        os.environ.get("HA_URL", "http://ha.home.arpa:8123") + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
        },
    )
    with opener(req, timeout=15) as r:
        return json.load(r)


def _set_until(until: datetime | None, opener, chat_id: str = "") -> None:
    _ha(
        "POST",
        f"/api/states/{SENSOR}",
        {
            "state": until.isoformat() if until else "unknown",
            "attributes": {
                "friendly_name": "Door auto-open until",
                "device_class": "timestamp",
                "icon": "mdi:door-open",
                # HA's door automations reply here; the chat must be an allowed
                # chat of HA's telegram_bot entry or the send fails.
                "chat_id": chat_id,
            },
        },
        opener,
    )


def _get_until(opener) -> datetime | None:
    try:
        state = _ha("GET", f"/api/states/{SENSOR}", opener=opener)["state"]
        return datetime.fromisoformat(state)
    except Exception:  # noqa: BLE001 — 404 before the first /door, or "unknown"
        return None


def _health_warning(opener) -> str:
    """ "" when healthy; otherwise one ⚠️ line per problem, prefixed by a newline."""
    try:
        req = urllib.request.Request(
            os.environ.get("HA_URL", "http://ha.home.arpa:8123") + "/api/template",
            method="POST",
            data=json.dumps({"template": HEALTH}).encode(),
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Content-Type": "application/json",
            },
        )
        with opener(req, timeout=15) as r:
            problems = json.loads(r.read().decode())
    except Exception as e:  # noqa: BLE001 — a failed check must not block arming
        logger.warning("door: health check failed", exc_info=True)
        return f"\n⚠️ Couldn't check the intercom's health ({e}): the door may not open."
    if not problems:
        return ""
    lines = [describe(p) for p in problems]
    return (
        "".join(f"\n⚠️ {line}" for line in lines) + "\nThe door will NOT open on a ring."
    )


def _hhmm(t: datetime) -> str:
    return t.astimezone().strftime("%H:%M")


def handle(raw_args: str, source=None, now=None, opener=urllib.request.urlopen) -> str:
    if source is None or str(getattr(source, "chat_id", "")) not in ALLOWED_CHATS:
        return "🚫 /door only works in Nico's DM and the group with Alfie."
    now = now or datetime.now(timezone.utc)
    arg = (raw_args or "").strip().lower()
    try:
        if arg in ("status", "?"):
            until = _get_until(opener)
            if until and until > now:
                left = int((until - now).total_seconds() // 60)
                return f"🚪 Auto-open ON until {_hhmm(until)} ({left} min left).{_health_warning(opener)}"
            return f"🔒 Auto-open is off.{_health_warning(opener)}"
        if arg in ("off", "stop", "cancel", "close"):
            _set_until(None, opener)
            return "🔒 Auto-open off."
        dur = parse_duration(arg)
        if dur is None or dur <= timedelta(0):
            return "Usage: /door [30m|2h|1h30m|off|status] — default 1h."
        dur = min(dur, MAX)
        until = now + dur
        _set_until(until, opener, str(source.chat_id))
        return (
            f"🚪 Auto-open ON until {_hhmm(until)}: every ring opens the hall door. /door off to stop."
            + _health_warning(opener)
        )
    except Exception as e:  # noqa: BLE001
        logger.exception("door: Home Assistant call failed")
        return f"⚠️ /door failed: {e}"


def register(ctx):
    ctx.register_command(
        "door",
        handle,
        description="Auto-open the hall door on every ring (default 1h)",
        args_hint="[30m|2h|off|status]",
    )
