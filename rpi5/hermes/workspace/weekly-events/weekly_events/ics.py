from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

from .normalize import normalize


def _unfold(text: str) -> list[str]:
    lines = []
    for line in text.replace("\r\n", "\n").split("\n"):
        if line.startswith((" ", "\t")) and lines:
            lines[-1] += line[1:]
        else:
            lines.append(line)
    return lines


def _value(line: str):
    head, _, value = line.partition(":")
    params = dict(part.split("=", 1) for part in head.split(";")[1:] if "=" in part)
    return head.split(";", 1)[0], params, value.replace("\\n", "\n").replace("\\,", ",")


def _date(value: str, tz: str) -> str:
    value = value.rstrip("Z")
    fmt = "%Y%m%dT%H%M%S" if len(value) >= 15 else "%Y%m%dT%H%M"
    if "T" not in value:
        fmt = "%Y%m%d"
    return datetime.strptime(value, fmt).replace(tzinfo=ZoneInfo(tz)).isoformat()


def parse_ics(text: str, source_id: str, default_timezone: str) -> list:
    output, current = [], None
    for line in _unfold(text):
        if line == "BEGIN:VEVENT": current = {}
        elif line == "END:VEVENT" and current is not None:
            tz = current.pop("_timezone", default_timezone)
            current["start_at"] = _date(current.pop("_start"), tz) if current.get("_start") else None
            current["end_at"] = _date(current.pop("_end"), tz) if current.get("_end") else None
            current["timezone"] = tz
            output.append(normalize(source_id, current, default_timezone)); current = None
        elif current is not None and ":" in line:
            key, params, value = _value(line)
            if key == "UID": current["external_id"] = value
            elif key == "SUMMARY": current["title"] = value
            elif key == "DESCRIPTION": current["description"] = value
            elif key == "LOCATION":
                current["venue"] = value
                if "," in value: current["city"] = value.rsplit(",", 1)[1].strip()
            elif key == "URL": current["event_url"] = value
            elif key == "STATUS": current["status"] = "cancelled" if value.upper() == "CANCELLED" else "scheduled"
            elif key == "DTSTART": current["_start"] = value; current["_timezone"] = params.get("TZID", default_timezone)
            elif key == "DTEND": current["_end"] = value; current["_timezone"] = params.get("TZID", default_timezone)
    return output
