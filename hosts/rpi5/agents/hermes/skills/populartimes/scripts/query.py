#!/usr/bin/env python3
"""Fetch Google Maps popular-times information for one Place ID."""

import argparse
import json
import os
import sys

import populartimes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("place_id", help="Google Maps Place ID")
    parser.add_argument("--json", action="store_true", help="print the full response as JSON")
    args = parser.parse_args()

    api_key = os.environ.get("GOOGLE_PLACES_API_KEY")
    if not api_key:
        print("GOOGLE_PLACES_API_KEY is not set in the Hermes environment.", file=sys.stderr)
        return 2

    try:
        place = populartimes.get_id(api_key, args.place_id)
    except Exception as exc:  # library/network/API errors should be actionable to Hermes
        print(f"Populartimes request failed: {exc}", file=sys.stderr)
        return 1

    if not place:
        print("No place data returned. Check the Place ID and API key.", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(place, ensure_ascii=False))
        return 0

    print(f"{place.get('name', 'Unknown place')} — {place.get('address', '')}".rstrip(" —"))
    current = place.get("current_popularity")
    print("Current popularity: " + (f"{current}/100" if current is not None else "unavailable"))
    days = place.get("populartimes") or []
    if not days:
        print("Weekly popular-times data: unavailable")
    for day in days:
        values = day.get("data") or []
        ranked = sorted(enumerate(values), key=lambda item: item[1], reverse=True)[:3]
        peaks = ", ".join(f"{hour:02d}:00 ({value}/100)" for hour, value in ranked if value)
        print(f"{day.get('name', 'Day')}: busiest {peaks or 'no reported busy hours'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
