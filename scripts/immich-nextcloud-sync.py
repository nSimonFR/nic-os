#!/usr/bin/env python3
"""Sync named Immich people into a Nextcloud Contacts addressbook.

For each named Immich person:
  1. find NC contact(s) with X-IMMICH-ID:<id> -> update PHOTO + BDAY
  2. else find NC contact(s) whose FN matches (case-insensitive) -> update
     PHOTO + BDAY, add X-IMMICH-ID
  3. else create a new contact with FN = Immich name + PHOTO + BDAY + X-IMMICH-ID

When multiple contacts share the FN/ID, all of them are updated with the same
photo so duplicates stay consistent until manually deduped.

Default is a dry-run; pass --apply to write.

Auth:
  Immich API key  -> /run/agenix/immich-api-key (or --immich-key)
  NC app password -> $NC_PASSWORD               (or --nc-password)
"""
import argparse
import base64
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from collections import defaultdict

NS = {"D": "DAV:", "C": "urn:ietf:params:xml:ns:carddav"}


def http(url, method="GET", headers=None, data=None):
    req = urllib.request.Request(url, method=method, headers=headers or {}, data=data)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read()


def norm(s):
    s = unicodedata.normalize("NFKD", s)
    return "".join(c for c in s if not unicodedata.combining(c)).lower().strip()


def fetch_immich_named(base, api_key):
    page, out = 1, []
    while True:
        status, _, body = http(
            f"{base}/api/people?withHidden=false&page={page}&size=500",
            headers={"x-api-key": api_key, "Accept": "application/json"},
        )
        if status != 200:
            sys.exit(f"Immich /api/people -> HTTP {status}: {body[:200]!r}")
        d = json.loads(body)
        out.extend(d["people"])
        if not d.get("hasNextPage"):
            return [p for p in out if (p.get("name") or "").strip()]
        page += 1


def fetch_thumbnail(base, api_key, person_id):
    status, headers, body = http(
        f"{base}/api/people/{person_id}/thumbnail",
        headers={"x-api-key": api_key},
    )
    if status != 200:
        raise RuntimeError(f"thumbnail {person_id}: HTTP {status}")
    ct = (headers.get("Content-Type") or "image/jpeg").split(";")[0].strip()
    return body, ct


def list_contacts(base, user, addressbook, auth):
    body = (
        b'<?xml version="1.0" encoding="utf-8"?>'
        b'<C:addressbook-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">'
        b'<D:prop><D:getetag/><C:address-data/></D:prop>'
        b'</C:addressbook-query>'
    )
    status, _, xml_body = http(
        f"{base}/remote.php/dav/addressbooks/users/{user}/{addressbook}/",
        method="REPORT",
        headers={"Authorization": auth, "Depth": "1", "Content-Type": "application/xml; charset=utf-8"},
        data=body,
    )
    if status not in (207, 200):
        sys.exit(f"CardDAV REPORT -> HTTP {status}: {xml_body[:300]!r}")
    out = []
    for resp in ET.fromstring(xml_body).findall("D:response", NS):
        href = resp.find("D:href", NS)
        ad = resp.find("D:propstat/D:prop/C:address-data", NS)
        if href is None or ad is None or not ad.text:
            continue
        out.append((href.text, ad.text))
    return out


def vcard_field(text, field):
    m = re.search(rf"^{field}(?:;[^:]*)?:(.*)$", text, re.MULTILINE)
    return m.group(1).strip() if m else None


def fold(text):
    out = []
    for line in text.split("\r\n"):
        if len(line.encode("utf-8")) <= 75:
            out.append(line)
            continue
        b = line.encode("utf-8")
        chunks, b = [b[:75]], b[75:]
        while b:
            chunks.append(b[:74])
            b = b[74:]
        out.append(chunks[0].decode("utf-8"))
        for c in chunks[1:]:
            out.append(" " + c.decode("utf-8"))
    return "\r\n".join(out)


def unfold(vcard):
    raw = vcard.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    out = []
    for ln in raw:
        if (ln.startswith(" ") or ln.startswith("\t")) and out:
            out[-1] += ln[1:]
        else:
            out.append(ln)
    while out and not out[-1].strip():
        out.pop()
    return out


def build_new(name, photo_b64, photo_subtype, bday, immich_id):
    uid = str(uuid.uuid4())
    lines = [
        "BEGIN:VCARD", "VERSION:3.0",
        f"UID:{uid}", f"FN:{name}", f"N:{name};;;;",
    ]
    if bday:
        lines.append(f"BDAY:{bday}")
    lines.append(f"X-IMMICH-ID:{immich_id}")
    lines.append(f"PHOTO;ENCODING=b;TYPE={photo_subtype}:{photo_b64}")
    lines.append("END:VCARD")
    return uid, fold("\r\n".join(lines)) + "\r\n"


def update_existing(existing, photo_b64, photo_subtype, bday, immich_id):
    lines = unfold(existing)
    # Replace/append BDAY only if Immich has one (don't overwrite NC's existing date)
    if bday:
        for i, ln in enumerate(lines):
            if ln.startswith("BDAY:") or ln.startswith("BDAY;"):
                lines[i] = f"BDAY:{bday}"
                break
        else:
            lines.insert(-1, f"BDAY:{bday}")
    # Replace/append X-IMMICH-ID
    for i, ln in enumerate(lines):
        if ln.startswith("X-IMMICH-ID:"):
            lines[i] = f"X-IMMICH-ID:{immich_id}"
            break
    else:
        lines.insert(-1, f"X-IMMICH-ID:{immich_id}")
    # Replace PHOTO
    lines = [ln for ln in lines if not (ln.startswith("PHOTO:") or ln.startswith("PHOTO;"))]
    end_idx = next(i for i, ln in enumerate(lines) if ln.startswith("END:VCARD"))
    lines.insert(end_idx, f"PHOTO;ENCODING=b;TYPE={photo_subtype}:{photo_b64}")
    return fold("\r\n".join(lines)) + "\r\n"


def put(url, auth, body):
    s, _, b = http(url, method="PUT",
                   headers={"Authorization": auth, "Content-Type": "text/vcard; charset=utf-8"},
                   data=body.encode("utf-8"))
    if s not in (201, 204):
        raise RuntimeError(f"PUT {url} -> HTTP {s}: {b[:200]!r}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="Actually write changes (default: dry-run)")
    ap.add_argument("--immich-base", default="http://127.0.0.1:2283")
    ap.add_argument("--immich-key-file", default="/run/agenix/immich-api-key")
    ap.add_argument("--immich-key", default=None, help="Immich API key (overrides --immich-key-file)")
    ap.add_argument("--nc-base", default="http://127.0.0.1:8091")
    ap.add_argument("--nc-user", default="nsimon")
    ap.add_argument("--nc-addressbook", default="contacts")
    ap.add_argument("--nc-password", default=os.environ.get("NC_PASSWORD"),
                    help="Nextcloud app password (env: NC_PASSWORD)")
    ap.add_argument("--limit", type=int, default=None)
    args = ap.parse_args()
    if not args.nc_password:
        sys.exit("error: --nc-password or NC_PASSWORD env var required")

    immich_key = args.immich_key
    if not immich_key:
        with open(args.immich_key_file) as f:
            immich_key = f.read().strip()
    auth = "Basic " + base64.b64encode(f"{args.nc_user}:{args.nc_password}".encode()).decode()

    print("Fetching Immich named people...")
    people = fetch_immich_named(args.immich_base, immich_key)
    print(f"  {len(people)} named people")

    print("Listing Nextcloud contacts...")
    cards = list_contacts(args.nc_base, args.nc_user, args.nc_addressbook, auth)
    by_immich_id = defaultdict(list)
    by_fn_norm = defaultdict(list)
    for href, vc in cards:
        iid = vcard_field(vc, "X-IMMICH-ID")
        fn = vcard_field(vc, "FN")
        if iid:
            by_immich_id[iid].append((href, vc))
        if fn:
            by_fn_norm[norm(fn)].append((href, vc))
    print(f"  {len(cards)} contacts ({len(by_immich_id)} already tagged X-IMMICH-ID)")

    if args.limit:
        people = people[: args.limit]

    plan = []  # list of (action, person, targets, target_fn_for_new)
    for p in people:
        name = p["name"].strip()
        targets = by_immich_id.get(p["id"]) or by_fn_norm.get(norm(name))
        action = "update" if targets else "create"
        plan.append((action, p, targets or [], name))

    n_create = sum(1 for a, *_ in plan if a == "create")
    n_update = sum(1 for a, *_ in plan if a == "update")
    n_dups = sum(len(t) for _, _, t, _ in plan if len(t) > 1)
    print(f"\nPlan: {n_create} create, {n_update} update ({n_dups} extra writes for FN duplicates)\n")

    for action, p, targets, fn in plan:
        bday = (p.get("birthDate") or "").split("T")[0]
        suffix = f" -> {len(targets)} cards" if len(targets) > 1 else ""
        print(f"  [{action:6}] {p['name']!r:30} immich:{p['id'][:8]}"
              f"{' bday=' + bday if bday else ''}{suffix}")

    if not args.apply:
        print("\nDry-run. Pass --apply to write.")
        return

    print("\nApplying...")
    ok = err = 0
    for action, p, targets, fn in plan:
        bday = (p.get("birthDate") or "").split("T")[0] or None
        try:
            blob, ct = fetch_thumbnail(args.immich_base, immich_key, p["id"])
            b64 = base64.b64encode(blob).decode("ascii")
            subtype = ct.split("/")[-1].upper()
            if action == "create":
                uid, vcard = build_new(fn, b64, subtype, bday, p["id"])
                path = f"/remote.php/dav/addressbooks/users/{args.nc_user}/{args.nc_addressbook}/{uid}.vcf"
                put(args.nc_base + path, auth, vcard)
                ok += 1
                print(f"  [create] {fn}")
            else:
                for href, existing in targets:
                    vcard = update_existing(existing, b64, subtype, bday, p["id"])
                    put(args.nc_base + href, auth, vcard)
                    ok += 1
                if len(targets) > 1:
                    print(f"  [update] {p['name']} -> {len(targets)} cards")
                else:
                    print(f"  [update] {p['name']}")
        except Exception as e:
            err += 1
            print(f"  [ERR {action}] {p['name']}: {e}")
    print(f"\nDone: {ok} writes, {err} errors.")


if __name__ == "__main__":
    main()
