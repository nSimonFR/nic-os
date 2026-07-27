#!/usr/bin/env python3
"""
Weekly job alert fetcher.

- Extend by editing sources.json.
- Supported source types:
  - ashby: public Ashby job board API, needs {"board": "org-slug"}
  - blablacar: server-rendered BlaBlaCar vacancies page
  - linear_single: one readable Linear/Ashby job page
  - generic_page: basic availability/fallback scanner

Output is plain text, suitable for Telegram/picoclaw scheduled command output.
"""
from __future__ import annotations

import datetime as dt
import html
import json
import os
import re
import sys
import textwrap
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
CONFIG = ROOT / "sources.json"
STATE = ROOT / ".seen_jobs.json"
USER_AGENT = "Mozilla/5.0 (compatible; nClawJobAlert/1.0)"
TIMEOUT = 25
MAX_PER_SOURCE = 8

@dataclass(frozen=True)
class Job:
    company: str
    title: str
    location: str = ""
    team: str = ""
    url: str = ""
    source_url: str = ""

    @property
    def key(self) -> str:
        return "|".join([
            norm(self.company), norm(self.title), norm(self.location), norm(self.url or self.source_url)
        ])


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip().lower())


def fetch(url: str, *, json_body: Any | None = None, headers: dict[str, str] | None = None) -> str:
    data = None
    req_headers = {"User-Agent": USER_AGENT, **(headers or {})}
    if json_body is not None:
        data = json.dumps(json_body).encode()
        req_headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=req_headers)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return r.read().decode("utf-8", errors="replace")




def absolute_url(base: str, href: str) -> str:
    href = html.unescape((href or "").strip())
    if not href or href.startswith(("mailto:", "tel:", "javascript:")):
        return ""
    return urllib.parse.urljoin(base, href)


def textify(raw: str) -> str:
    raw = re.sub(r"(?is)<(script|style).*?</\1>", " ", raw)
    raw = re.sub(r"(?i)<br\s*/?>", "\n", raw)
    raw = re.sub(r"(?i)</(p|div|li|h\d|tr)>", "\n", raw)
    raw = re.sub(r"<[^>]+>", " ", raw)
    raw = html.unescape(raw)
    raw = re.sub(r"[ \t\r\f\v]+", " ", raw)
    raw = re.sub(r"\n\s+", "\n", raw)
    return raw.strip()


def is_relevant(job: Job, keywords: list[str], locations: list[str]) -> bool:
    blob = norm(" ".join([job.title, job.location, job.team]))
    kw_ok = any(k.lower() in blob for k in keywords)
    loc_ok = not job.location or any(l.lower() in blob for l in locations)
    return kw_ok and loc_ok


def ashby(source: dict[str, Any]) -> list[Job]:
    board = source["board"]
    data = json.loads(fetch(f"https://api.ashbyhq.com/posting-api/job-board/{urllib.parse.quote(board)}"))
    out = []
    for j in data.get("jobs", []):
        locs = [j.get("location") or ""]
        locs += [x.get("locationName", "") for x in j.get("secondaryLocations", []) if isinstance(x, dict)]
        out.append(Job(
            company=source["name"],
            title=j.get("title", "Untitled"),
            location=", ".join(x for x in locs if x),
            team=j.get("team") or j.get("department") or "",
            url=j.get("jobUrl") or source["url"],
            source_url=source["url"],
        ))
    return out


def blablacar(source: dict[str, Any]) -> list[Job]:
    raw = fetch(source["url"])
    jobs: list[Job] = []

    # BlaBlaCar exposes individual Lever offer URLs in server-rendered job cards.
    card_re = re.compile(
        r'<a\s+[^>]*href="(?P<url>https://jobs\.lever\.co/blablacar/[^"]+)"[^>]*class="[^"]*job-wrapper[^"]*"[^>]*>(?P<body>.*?)</a>',
        re.I | re.S,
    )
    for m in card_re.finditer(raw):
        body = m.group("body")
        title_m = re.search(r'fs-cmsfilter-field="title"[^>]*>(?P<title>.*?)</p>', body, re.I | re.S)
        if not title_m:
            continue
        loc_m = re.search(r'fs-cmsfilter-field="location"[^>]*>(?P<loc>.*?)</div>', body, re.I | re.S)
        dept_m = re.search(r'fs-cmsfilter-field="department"[^>]*>(?P<dept>.*?)</div>', body, re.I | re.S)
        team_m = re.search(r'fs-cmsfilter-field="team"[^>]*>(?P<team>.*?)</div>', body, re.I | re.S)
        title = textify(title_m.group("title"))
        loc = textify(loc_m.group("loc")) if loc_m else ""
        dept = textify(dept_m.group("dept")) if dept_m else ""
        team = textify(team_m.group("team")) if team_m else ""
        team_blob = " / ".join(x for x in [dept, team] if x)
        jobs.append(Job(source["name"], title, loc or "Paris / France", team_blob, m.group("url"), source["url"]))

    if jobs:
        return dedupe(jobs)

    # Fallback text scanner if the markup changes; URL falls back to list page.
    txt = textify(raw)
    contract_re = r"(?:Permanent|Fixed-term|Internship|Apprenticeship|CDD [^\n]+|CDI)"
    pattern = re.compile(
        rf"(?P<title>[A-Z][^\n]{{6,120}}?)\s*(?P<contract>{contract_re})?\s*(?P<location>Paris(?: or Remote from France)? -? France|Paris or Remote from France)",
        re.I,
    )
    for m in pattern.finditer(txt):
        title = re.sub(r"\s+", " ", m.group("title")).strip(" -")
        if len(title) < 6 or title.lower().startswith(("location", "department", "contract")):
            continue
        jobs.append(Job(source["name"], title, m.group("location") or "Paris / France", url=source["url"], source_url=source["url"]))
    return dedupe(jobs)

def linear_single(source: dict[str, Any]) -> list[Job]:
    txt = textify(fetch(source["url"]))
    m = re.search(r"Careers\s*/\s*Engineering\s*(?P<title>[^\n]+?)\s*Full-time\s*\((?P<loc>[^)]+)\)", txt, re.I)
    if m:
        return [Job(source["name"], m.group("title").strip(), m.group("loc").strip(), "Engineering", source["url"], source["url"])]
    # Current page title fallback.
    m = re.search(r"(Senior\s*/\s*Staff\s+Fullstack\s+Engineer)", txt, re.I)
    if m:
        return [Job(source["name"], m.group(1), "Europe / North America remote", "Engineering", source["url"], source["url"])]
    return []


def generic_page(source: dict[str, Any]) -> list[Job]:
    # Basic fallback: tells us if page is blocked/unusable, and catches obvious job-title links.
    raw = fetch(source["url"])
    txt = textify(raw)
    blocked = ["security checkpoint", "enable javascript", "subscription inactive", "error 402", "error 410"]
    if any(b in txt.lower() for b in blocked):
        return []

    titleish = re.compile(r"\b(engineer|engineering manager|architect|developer|sre|site reliability|backend|frontend|fullstack|platform|infrastructure|technical lead|staff)\b", re.I)
    out: list[Job] = []

    # Prefer linked titles so output includes direct-ish job links when available.
    anchor_re = re.compile(r'<a\s+[^>]*href=(?P<q>["\'])(?P<href>.*?)(?P=q)[^>]*>(?P<body>.*?)</a>', re.I | re.S)
    for m in anchor_re.finditer(raw):
        title = textify(m.group("body"))
        title = re.sub(r"\s+", " ", title).strip()
        if 8 <= len(title) <= 160 and titleish.search(title):
            url = absolute_url(source["url"], m.group("href")) or source["url"]
            out.append(Job(source["name"], title, "", url=url, source_url=source["url"]))

    if out:
        return dedupe(out)[:MAX_PER_SOURCE]

    # Last-resort text lines; URL falls back to source page.
    lines = [re.sub(r"\s+", " ", x).strip() for x in txt.splitlines()]
    for line in lines:
        if 8 <= len(line) <= 120 and titleish.search(line):
            out.append(Job(source["name"], line, "", url=source["url"], source_url=source["url"]))
    return dedupe(out)[:MAX_PER_SOURCE]

def dedupe(jobs: list[Job]) -> list[Job]:
    seen: set[str] = set()
    out = []
    for j in jobs:
        if j.key in seen:
            continue
        seen.add(j.key)
        out.append(j)
    return out


def load_seen() -> set[str]:
    if not STATE.exists():
        return set()
    try:
        return set(json.loads(STATE.read_text()).get("seen", []))
    except Exception:
        return set()


def save_seen(keys: set[str]) -> None:
    STATE.write_text(json.dumps({"updated_at": dt.datetime.now().isoformat(), "seen": sorted(keys)}, indent=2))


def render(results: dict[str, list[Job]], errors: dict[str, str], only_new: bool, new_count: int) -> str:
    today = dt.date.today().strftime("%A %Y-%m-%d")
    lines = [f"💼 Weekly job alert — {today}", ""]
    if only_new:
        lines.append(f"New matching listings: {new_count}")
    else:
        lines.append("Matching listings snapshot")
    lines.append("")

    any_job = False
    for company, jobs in results.items():
        if not jobs:
            continue
        any_job = True
        lines.append(f"{company}")
        for j in jobs[:MAX_PER_SOURCE]:
            meta = " — ".join(x for x in [j.location, j.team] if x)
            lines.append(f"• {j.title}" + (f" ({meta})" if meta else ""))
            if j.url:
                lines.append(f"  {j.url}")
        if len(jobs) > MAX_PER_SOURCE:
            lines.append(f"• … {len(jobs) - MAX_PER_SOURCE} more")
        lines.append("")

    if not any_job:
        lines.append("No matching listings found this week.")
        lines.append("")

    if errors:
        lines.append("Sources with fetch issues")
        for name, err in errors.items():
            lines.append(f"• {name}: {err}")
        lines.append("")

    lines.append("Config: job-alerts/sources.json")
    return "\n".join(lines).strip()


def main() -> int:
    only_new = "--all" not in sys.argv
    cfg = json.loads(CONFIG.read_text())
    keywords = cfg.get("profile", {}).get("keywords", [])
    locations = cfg.get("profile", {}).get("locations", [])
    seen = load_seen()
    next_seen = set(seen)

    handlers = {
        "ashby": ashby,
        "blablacar": blablacar,
        "linear_single": linear_single,
        "generic_page": generic_page,
    }
    results: dict[str, list[Job]] = {}
    errors: dict[str, str] = {}
    new_count = 0

    for source in cfg.get("sources", []):
        name = source.get("name", source.get("url", "unknown"))
        try:
            jobs = handlers[source.get("type", "generic_page")](source)
            jobs = [j for j in dedupe(jobs) if is_relevant(j, keywords, locations)]
            if only_new:
                fresh = [j for j in jobs if j.key not in seen]
            else:
                fresh = jobs
            for j in jobs:
                next_seen.add(j.key)
            if fresh:
                results[name] = fresh
                new_count += len(fresh)
        except urllib.error.HTTPError as e:
            errors[name] = f"HTTP {e.code}"
        except Exception as e:
            errors[name] = str(e)[:120]

    if only_new:
        save_seen(next_seen)
    print(render(results, errors, only_new, new_count))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
