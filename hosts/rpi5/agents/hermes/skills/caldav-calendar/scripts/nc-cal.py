#!/usr/bin/env python3
"""nc-cal — a tiny, zero-dependency CalDAV client for calendar CRUD.

Speaks standard CalDAV (RFC 4791) over HTTPS with Basic auth using only the
Python standard library, so it runs anywhere `python3` does — no vdirsyncer,
no khal, no local cache, no sync step. Reads happen live via a REPORT
calendar-query; writes are a single PUT (stable UID) or DELETE.

It is server-agnostic (Nextcloud, Radicale, iCloud, Fastmail, …): everything
server-specific comes from the environment, with Nextcloud-on-this-box defaults.

Environment (all optional — defaults target this machine's Nextcloud):
  CALDAV_BASE           calendar-home URL, must end with '/'
                        default https://rpi5.gate-mintaka.ts.net/nextcloud/remote.php/dav/calendars/nsimon/
  CALDAV_USER           default nsimon
  CALDAV_PASSWORD       literal password (takes precedence over the file)
  CALDAV_PASSWORD_FILE  default /run/agenix/nextcloud-homepage-password
  CALDAV_CALENDAR       default calendar collection, default 'personal'

Usage:
  nc-cal.py calendars
  nc-cal.py list [--calendar C] [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--json]
  nc-cal.py add  --summary S --start ISO [--end ISO] [--all-day]
                 [--location L] [--description D] [--calendar C]
  nc-cal.py edit --uid U [--summary S] [--start ISO] [--end ISO] [--all-day]
                 [--location L] [--description D] [--calendar C]
  nc-cal.py delete --uid U [--calendar C]

Dates: --start/--end accept 'YYYY-MM-DD' (all-day) or 'YYYY-MM-DDTHH:MM'
(local floating time) or a full ISO datetime with offset. --from/--to for
`list` accept 'YYYY-MM-DD'. Times without an offset are treated as floating
local time (the server renders them in the viewer's zone).
"""
import argparse
import base64
import hashlib
import html
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

DEFAULT_BASE = ("https://rpi5.gate-mintaka.ts.net/nextcloud/remote.php/dav/"
                "calendars/nsimon/")


def cfg():
    base = os.environ.get("CALDAV_BASE", DEFAULT_BASE)
    if not base.endswith("/"):
        base += "/"
    return {
        "base": base,
        "user": os.environ.get("CALDAV_USER", "nsimon"),
        "cal": os.environ.get("CALDAV_CALENDAR", "personal"),
    }


def _password():
    if os.environ.get("CALDAV_PASSWORD"):
        return os.environ["CALDAV_PASSWORD"]
    path = os.environ.get("CALDAV_PASSWORD_FILE",
                          "/run/agenix/nextcloud-homepage-password")
    with open(path, encoding="utf-8") as f:
        return f.read().strip()


def _auth(user):
    tok = base64.b64encode(f"{user}:{_password()}".encode()).decode()
    return "Basic " + tok


def _request(method, url, user, body=None, headers=None, timeout=30):
    h = {"Authorization": _auth(user)}
    if headers:
        h.update(headers)
    req = urllib.request.Request(
        url, data=body.encode() if body else None, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        raise SystemExit(f"error: {method} {url} -> HTTP {e.code} {e.reason}\n{detail}")
    except urllib.error.URLError as e:
        raise SystemExit(f"error: cannot reach {url}: {e.reason}")


# ---------------------------------------------------------------- iCalendar --
def _esc(s):
    return ((s or "").replace("\\", "\\\\").replace(";", "\\;")
            .replace(",", "\\,").replace("\r", "").replace("\n", "\\n"))


def _unesc(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            out.append({"n": "\n", "N": "\n"}.get(nxt, nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _fold(line):
    """Fold a content line to <=75 octets (RFC 5545), never splitting a
    multi-byte char. Continuation lines begin with a single space."""
    if len(line.encode()) <= 75:
        return line
    out, cur, cur_len = [], "", 0
    for ch in line:
        n = len(ch.encode())
        limit = 75 if not out else 74
        if cur_len + n > limit:
            out.append(cur)
            cur, cur_len = ch, n
        else:
            cur += ch
            cur_len += n
    out.append(cur)
    return "\r\n ".join(out)


def _unfold(text):
    # RFC 5545: a CRLF followed by a space/tab is a line continuation.
    return re.sub(r"\r?\n[ \t]", "", text)


def _parse_dt(value, all_day):
    return (datetime.fromisoformat(value[:10]).date() if all_day
            else datetime.fromisoformat(value))


def _fmt_dt(dt, all_day):
    if all_day:
        return ";VALUE=DATE:" + dt.strftime("%Y%m%d")
    if getattr(dt, "tzinfo", None) is not None:
        return ":" + dt.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return ":" + dt.strftime("%Y%m%dT%H%M%S")  # floating local time


def _looks_all_day(value):
    return len(value) <= 10 and "T" not in value


def make_uid(summary, start):
    key = f"{summary}|{start}|{datetime.now(timezone.utc).timestamp()}"
    return "nc-cal-" + hashlib.sha1(key.encode()).hexdigest()[:16] + "@nic-os"


def build_ics(uid, summary, start, end=None, all_day=None,
              location=None, description=None):
    if all_day is None:
        all_day = _looks_all_day(start)
    s = _parse_dt(start, all_day)
    e = _parse_dt(end, all_day) if end else None
    default = timedelta(days=1) if all_day else timedelta(hours=1)
    try:
        bad = e is None or e <= s
    except TypeError:
        bad = True
    if bad:
        e = s + default
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//nic-os//nc-cal//EN",
        "BEGIN:VEVENT",
        f"UID:{uid}",
        "DTSTAMP:" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
        f"SUMMARY:{_esc(summary)}",
        "DTSTART" + _fmt_dt(s, all_day),
        "DTEND" + _fmt_dt(e, all_day),
    ]
    if location:
        lines.append("LOCATION:" + _esc(location))
    if description:
        lines.append("DESCRIPTION:" + _esc(description))
    lines += ["END:VEVENT", "END:VCALENDAR"]
    return "\r\n".join(_fold(ln) for ln in lines) + "\r\n"


def parse_vevent(ics):
    """Pull the first VEVENT's key fields out of a VCALENDAR string. Only the
    VEVENT body is scanned — a VTIMEZONE's STANDARD/DAYLIGHT sub-components also
    carry DTSTART lines (the 1970 DST-transition anchors) that must be ignored."""
    text = _unfold(ics)
    m = re.search(r"(?is)BEGIN:VEVENT\r?\n(.*?)\r?\nEND:VEVENT", text)
    body = m.group(1) if m else text
    ev = {}
    for line in body.splitlines():
        m = re.match(r"^(UID|SUMMARY|DTSTART|DTEND|LOCATION|DESCRIPTION|RRULE)"
                     r"(;[^:]*)?:(.*)$", line)
        if not m:
            continue
        key, params, val = m.group(1), m.group(2) or "", m.group(3)
        if key in ("DTSTART", "DTEND"):
            ev[key] = _fmt_display_dt(val, "DATE" in params.upper())
        elif key in ev:
            continue  # first occurrence wins
        else:
            ev[key] = _unesc(val)
    return ev


def _fmt_display_dt(raw, is_date):
    raw = raw.strip()
    try:
        if is_date or (len(raw) == 8 and "T" not in raw):
            return datetime.strptime(raw[:8], "%Y%m%d").strftime("%Y-%m-%d")
        if raw.endswith("Z"):
            dt = datetime.strptime(raw, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
            return dt.astimezone().strftime("%Y-%m-%d %H:%M")
        return datetime.strptime(raw[:15], "%Y%m%dT%H%M%S").strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return raw


# --------------------------------------------------------------- operations --
def _cal_url(c, cal):
    return f"{c['base']}{cal}/"


def cmd_calendars(c, _):
    body = ('<?xml version="1.0"?><d:propfind xmlns:d="DAV:">'
            "<d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>")
    _, xml = _request("PROPFIND", c["base"], c["user"], body,
                      {"Depth": "1", "Content-Type": "application/xml"})
    found = False
    for resp in re.findall(r"(?is)<[^>]*response>.*?</[^>]*response>", xml):
        if "calendar" not in resp.lower():
            continue
        href = re.search(r"(?is)<[^>]*href>(.*?)</[^>]*href>", resp)
        name = re.search(r"(?is)<[^>]*displayname>(.*?)</[^>]*displayname>", resp)
        if not href:
            continue
        uri = href.group(1).rstrip("/").rsplit("/", 1)[-1]
        if not uri:
            continue
        found = True
        label = html.unescape(name.group(1)) if name and name.group(1) else ""
        print(f"{uri}\t{label}")
    if not found:
        print("(no calendar collections found)", file=sys.stderr)


def _report(c, cal, start, end):
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">'
        "<d:prop><d:getetag/><c:calendar-data/></d:prop>"
        '<c:filter><c:comp-filter name="VCALENDAR">'
        '<c:comp-filter name="VEVENT">'
        f'<c:time-range start="{start}" end="{end}"/>'
        "</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>")
    _, xml = _request("REPORT", _cal_url(c, cal), c["user"], body,
                      {"Depth": "1", "Content-Type": "application/xml"})
    events = []
    for block in re.findall(r"(?is)<[^>]*calendar-data[^>]*>(.*?)</[^>]*calendar-data>", xml):
        ics = html.unescape(block).strip()
        if "BEGIN:VEVENT" in ics:
            events.append(parse_vevent(ics))
    events.sort(key=lambda e: e.get("DTSTART", ""))
    return events


def cmd_list(c, a):
    cal = a.calendar or c["cal"]
    now = datetime.now(timezone.utc)
    frm = (datetime.fromisoformat(a.frm).replace(tzinfo=timezone.utc)
           if a.frm else now)
    to = (datetime.fromisoformat(a.to).replace(tzinfo=timezone.utc)
          if a.to else now + timedelta(days=30))
    events = _report(c, cal, frm.strftime("%Y%m%dT%H%M%SZ"),
                     to.strftime("%Y%m%dT%H%M%SZ"))
    if a.json:
        import json
        print(json.dumps(events, ensure_ascii=False, indent=2))
        return
    if not events:
        print("(no events in range)")
        return
    for e in events:
        when = e.get("DTSTART", "?")
        if e.get("DTEND"):
            when += " → " + e["DTEND"]
        line = f"{when}  {e.get('SUMMARY', '(no title)')}"
        if e.get("LOCATION"):
            line += f"  @ {e['LOCATION']}"
        print(line)
        print(f"    uid: {e.get('UID', '?')}")


def cmd_add(c, a):
    cal = a.calendar or c["cal"]
    uid = make_uid(a.summary, a.start)
    ics = build_ics(uid, a.summary, a.start, a.end, a.all_day or None,
                    a.location, a.description)
    status, _ = _request(
        "PUT", f"{_cal_url(c, cal)}{uid}.ics", c["user"], ics,
        {"Content-Type": "text/calendar; charset=utf-8", "If-None-Match": "*"})
    print(f"added ({status}) to '{cal}': {a.summary}")
    print(f"uid: {uid}")


def cmd_edit(c, a):
    cal = a.calendar or c["cal"]
    url = f"{_cal_url(c, cal)}{a.uid}.ics"
    _, ics = _request("GET", url, c["user"])
    cur = parse_vevent(ics)
    # Re-derive raw start/end from the fetched event unless overridden.
    summary = a.summary if a.summary is not None else cur.get("SUMMARY", "")
    start = a.start or cur.get("DTSTART", "").replace(" ", "T")
    end = a.end or (cur.get("DTEND", "").replace(" ", "T") or None)
    location = a.location if a.location is not None else cur.get("LOCATION")
    description = a.description if a.description is not None else cur.get("DESCRIPTION")
    all_day = a.all_day or None
    new = build_ics(a.uid, summary, start, end, all_day, location, description)
    status, _ = _request(
        "PUT", url, c["user"], new,
        {"Content-Type": "text/calendar; charset=utf-8"})
    print(f"edited ({status}) in '{cal}': {summary}")
    print(f"uid: {a.uid}")


def cmd_delete(c, a):
    cal = a.calendar or c["cal"]
    status, _ = _request("DELETE", f"{_cal_url(c, cal)}{a.uid}.ics", c["user"])
    print(f"deleted ({status}) from '{cal}': {a.uid}")


def main():
    p = argparse.ArgumentParser(prog="nc-cal", description="Zero-dependency CalDAV client")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("calendars", help="list calendar collections")

    pl = sub.add_parser("list", help="list events in a time range")
    pl.add_argument("--calendar")
    pl.add_argument("--from", dest="frm", metavar="YYYY-MM-DD")
    pl.add_argument("--to", metavar="YYYY-MM-DD")
    pl.add_argument("--json", action="store_true")

    pa = sub.add_parser("add", help="create an event")
    pa.add_argument("--summary", required=True)
    pa.add_argument("--start", required=True)
    pa.add_argument("--end")
    pa.add_argument("--all-day", action="store_true")
    pa.add_argument("--location")
    pa.add_argument("--description")
    pa.add_argument("--calendar")

    pe = sub.add_parser("edit", help="modify an existing event by UID")
    pe.add_argument("--uid", required=True)
    pe.add_argument("--summary")
    pe.add_argument("--start")
    pe.add_argument("--end")
    pe.add_argument("--all-day", action="store_true")
    pe.add_argument("--location")
    pe.add_argument("--description")
    pe.add_argument("--calendar")

    pd = sub.add_parser("delete", help="delete an event by UID")
    pd.add_argument("--uid", required=True)
    pd.add_argument("--calendar")

    a = p.parse_args()
    c = cfg()
    {"calendars": cmd_calendars, "list": cmd_list, "add": cmd_add,
     "edit": cmd_edit, "delete": cmd_delete}[a.cmd](c, a)


if __name__ == "__main__":
    main()
