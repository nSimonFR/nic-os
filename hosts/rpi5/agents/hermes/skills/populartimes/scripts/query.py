#!/usr/bin/env python3
"""Google popular times (live + weekly) for one place, via SerpApi's Google Search engine.

Reads the "Popular times" block of the Google Search knowledge panel. Google Maps
itself only shows it to signed-in users since autumn 2026.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

SEARCH_URL = "https://serpapi.com/search.json"
ACCOUNT_URL = "https://serpapi.com/account.json"
DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]


def fetch(url, params, opener=urllib.request.urlopen):
    query = urllib.parse.urlencode(params)
    with opener(f"{url}?{query}", timeout=60) as resp:
        return json.load(resp)


def summarize(result, day):
    kg = result.get("knowledge_graph") or {}
    pt = kg.get("popular_times") or {}
    lines = [" — ".join(x for x in (kg.get("title"), kg.get("address")) if x) or "?"]
    live = pt.get("live")
    if live:
        score = live.get("busyness_score")
        lines.append(
            f"Live: {live.get('info', '?')}"
            + (f" ({score}/100)" if score is not None else "")
        )
    else:
        lines.append("Live: unavailable (closed, or Google has no live data now)")
    if live and live.get("typical_time_spent"):
        lines.append(f"Typical visit: {live['typical_time_spent']}")
    graph = pt.get("graph_results") or {}
    if not graph:
        lines.append("Weekly popular times: unavailable")
        return lines
    for name in [day] if day else DAYS:
        hours = [h for h in graph.get(name, []) if h.get("busyness_score")]
        if not hours:
            lines.append(f"{name}: closed or no data")
            continue
        series = " ".join(
            f"{h['time'].replace(' ', '')}={h['busyness_score']}" for h in hours
        )
        lines.append(f"{name}: {series}")
    return lines


def main(argv=None, env=os.environ, opener=urllib.request.urlopen):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "query", nargs="?", help='place name + city, e.g. "Arkose Chevaleret Paris"'
    )
    parser.add_argument("--day", choices=DAYS + ["all", "today"], default="today")
    parser.add_argument(
        "--json", action="store_true", help="print popular_times as JSON"
    )
    parser.add_argument(
        "--quota", action="store_true", help="show searches left (free)"
    )
    args = parser.parse_args(argv)

    key = env.get("SERPAPI_API_KEY")
    if not key:
        print("SERPAPI_API_KEY is not set in the Hermes environment.", file=sys.stderr)
        return 2
    try:
        if args.quota:
            acct = fetch(ACCOUNT_URL, {"api_key": key}, opener)
            print(
                f"{acct.get('total_searches_left')} searches left "
                f"({acct.get('plan_searches_left')} on plan {acct.get('plan_name')})"
            )
            return 0
        if not args.query:
            parser.error("query is required")
        params = {
            "engine": "google",
            "q": args.query,
            "hl": "fr",
            "gl": "fr",
            "api_key": key,
        }
        result = fetch(SEARCH_URL, params, opener)
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        print(f"SerpApi request failed: {exc}", file=sys.stderr)
        return 1
    if result.get("error"):
        print(f"SerpApi error: {result['error']}", file=sys.stderr)
        return 1

    pt = (result.get("knowledge_graph") or {}).get("popular_times")
    if args.json:
        print(json.dumps(pt, ensure_ascii=False))
        return 0 if pt else 1
    if not pt:
        title = (result.get("knowledge_graph") or {}).get("title")
        print(
            f"No popular times in Google's panel for {title!r}."
            if title
            else "No Google knowledge panel for this query; add the city or street.",
            file=sys.stderr,
        )
        return 1
    day = None if args.day == "all" else args.day
    if day == "today":
        day = DAYS[datetime.now().weekday()]
    print("\n".join(summarize(result, day)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
