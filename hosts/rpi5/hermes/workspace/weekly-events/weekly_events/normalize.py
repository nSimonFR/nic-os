from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from zoneinfo import ZoneInfo

from .model import Event

HASH_FIELDS = ("title", "games", "description", "start_at", "end_at", "timezone", "venue", "city", "organizer", "price", "capacity", "registered", "remaining_seats", "registration_url", "event_url", "calendar_url", "status")


def clean(value):
    if value is None:
        return None
    if isinstance(value, str):
        value = re.sub(r"\s+", " ", value).strip()
        return value or None
    return value


def canonical_url(url: str | None) -> str:
    if not url:
        return ""
    p = urlsplit(url)
    query = [(k, v) for k, v in parse_qsl(p.query, keep_blank_values=True) if not k.lower().startswith("utm_")]
    return urlunsplit((p.scheme.lower(), p.netloc.lower(), p.path.rstrip("/") or "/", urlencode(sorted(query)), ""))


def stable_id(url: str | None, start_at: str | None) -> str:
    return hashlib.sha256(f"{canonical_url(url)}|{start_at or ''}".encode()).hexdigest()[:20]


def iso(value, tz_name: str) -> str | None:
    value = clean(value)
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        # Generic French textual date support for HTML sources; not source-specific.
        match = re.search(r"(?:lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)\s+(\d{1,2})\s+([\wéû]+)\s+(\d{4})\s*(?:·|&middot;)?\s*(\d{1,2}:\d{2})?", value, re.I)
        months = {"janvier":1,"février":2,"fevrier":2,"mars":3,"avril":4,"mai":5,"juin":6,"juillet":7,"août":8,"aout":8,"septembre":9,"octobre":10,"novembre":11,"décembre":12,"decembre":12}
        if not match or match.group(2).casefold() not in months:
            return value
        day, month, year, clock = match.groups()
        hour, minute = (map(int, clock.split(":")) if clock else (0, 0))
        dt = datetime(int(year), months[month.casefold()], int(day), hour, minute)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=ZoneInfo(tz_name))
    return dt.isoformat()


def normalize(source_id: str, raw: dict, default_timezone: str = "Europe/Paris") -> Event:
    timezone = clean(raw.get("timezone")) or default_timezone
    start_at = iso(raw.get("start_at"), timezone)
    end_at = iso(raw.get("end_at"), timezone)
    event_url = canonical_url(raw.get("event_url")) or None
    registration_url = canonical_url(raw.get("registration_url")) or None
    calendar_url = canonical_url(raw.get("calendar_url")) or None
    external_id = str(clean(raw.get("external_id")) or stable_id(event_url or registration_url, start_at))
    games = raw.get("games") or []
    if isinstance(games, str):
        games = [clean(games)] if clean(games) else []
    values = {
        "source_id": source_id, "external_id": external_id, "title": clean(raw.get("title")) or "Untitled event",
        "games": [clean(x) for x in games if clean(x)], "description": clean(raw.get("description")),
        "start_at": start_at, "end_at": end_at, "timezone": timezone, "venue": clean(raw.get("venue")),
        "city": clean(raw.get("city")), "organizer": clean(raw.get("organizer")), "price": clean(raw.get("price")),
        "capacity": integer(raw.get("capacity")), "registered": integer(raw.get("registered")),
        "remaining_seats": integer(raw.get("remaining_seats")), "registration_url": registration_url,
        "event_url": event_url, "calendar_url": calendar_url,
        "status": (clean(raw.get("status")) or "scheduled").lower(),
    }
    digest = json.dumps({key: values[key] for key in HASH_FIELDS}, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    values["content_hash"] = hashlib.sha256(digest.encode()).hexdigest()
    return Event(**values)


def integer(value):
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def is_future(event: Event, now: datetime) -> bool:
    if not event.start_at:
        return True
    try:
        return datetime.fromisoformat(event.start_at) >= now.astimezone(ZoneInfo(event.timezone or "UTC"))
    except ValueError:
        return True
