#!/usr/bin/env python3
"""SQLite-backed price observation and alert-condition store."""

import argparse
import datetime as dt
import json
import sqlite3
from pathlib import Path

SCHEMA = """
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS products (
  slug TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  category TEXT NOT NULL,
  currency TEXT NOT NULL DEFAULT 'EUR',
  metadata_json TEXT NOT NULL DEFAULT '{}',
  active INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS product_sources (
  product_slug TEXT NOT NULL REFERENCES products(slug) ON DELETE CASCADE,
  source TEXT NOT NULL,
  PRIMARY KEY(product_slug, source)
);
CREATE TABLE IF NOT EXISTS alert_conditions (
  id INTEGER PRIMARY KEY,
  product_slug TEXT NOT NULL REFERENCES products(slug) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  metric TEXT NOT NULL,
  operator TEXT NOT NULL,
  threshold REAL NOT NULL,
  baseline TEXT,
  config_json TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS price_observations (
  id INTEGER PRIMARY KEY,
  product_slug TEXT NOT NULL REFERENCES products(slug),
  observed_at TEXT NOT NULL,
  price REAL NOT NULL CHECK(price >= 0),
  shipping REAL NOT NULL DEFAULT 0 CHECK(shipping >= 0),
  total_price REAL NOT NULL CHECK(total_price >= 0),
  currency TEXT NOT NULL,
  seller TEXT NOT NULL,
  url TEXT NOT NULL,
  variant_key TEXT NOT NULL DEFAULT '',
  verified INTEGER NOT NULL DEFAULT 1,
  details_json TEXT NOT NULL DEFAULT '{}',
  UNIQUE(product_slug, observed_at, seller, url, variant_key, total_price)
);
CREATE INDEX IF NOT EXISTS idx_observations_product_time
  ON price_observations(product_slug, observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_observations_comparable
  ON price_observations(product_slug, variant_key, verified, total_price);
"""


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def connect(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    con.row_factory = sqlite3.Row
    con.executescript(SCHEMA)
    return con


def sync(con, config_path):
    config = json.loads(Path(config_path).read_text())
    timestamp = now_iso()
    slugs = []
    with con:
        for product in config["products"]:
            slug = product["slug"]
            slugs.append(slug)
            metadata = {k: v for k, v in product.items() if k not in {
                "slug", "name", "category", "currency", "sources", "conditions"
            }}
            con.execute(
                """INSERT INTO products(slug,name,category,currency,metadata_json,active,updated_at)
                   VALUES(?,?,?,?,?,1,?)
                   ON CONFLICT(slug) DO UPDATE SET name=excluded.name,
                   category=excluded.category,currency=excluded.currency,
                   metadata_json=excluded.metadata_json,active=1,updated_at=excluded.updated_at""",
                (slug, product["name"], product["category"], product.get("currency", "EUR"),
                 json.dumps(metadata, ensure_ascii=False, sort_keys=True), timestamp),
            )
            con.execute("DELETE FROM product_sources WHERE product_slug=?", (slug,))
            con.executemany(
                "INSERT INTO product_sources(product_slug,source) VALUES(?,?)",
                [(slug, source) for source in product.get("sources", [])],
            )
            con.execute("DELETE FROM alert_conditions WHERE product_slug=?", (slug,))
            for condition in product.get("conditions", []):
                extra = {k: v for k, v in condition.items() if k not in {
                    "kind", "metric", "operator", "value", "baseline"
                }}
                con.execute(
                    """INSERT INTO alert_conditions
                       (product_slug,kind,metric,operator,threshold,baseline,config_json)
                       VALUES(?,?,?,?,?,?,?)""",
                    (slug, condition["kind"], condition["metric"], condition["operator"],
                     condition["value"], condition.get("baseline"),
                     json.dumps(extra, ensure_ascii=False, sort_keys=True)),
                )
        if slugs:
            marks = ",".join("?" for _ in slugs)
            con.execute(f"UPDATE products SET active=0,updated_at=? WHERE slug NOT IN ({marks})",
                        (timestamp, *slugs))
    return {"products": len(slugs)}


def compare(actual, operator, expected):
    return {
        "<=": actual <= expected,
        "<": actual < expected,
        ">=": actual >= expected,
        ">": actual > expected,
        "==": actual == expected,
    }[operator]


def record(con, args):
    product = con.execute("SELECT * FROM products WHERE slug=? AND active=1", (args.product,)).fetchone()
    if not product:
        raise SystemExit(f"unknown or inactive product: {args.product}; run sync first")
    observed_at = args.observed_at or now_iso()
    total = round(args.price + args.shipping, 2)
    previous = con.execute(
        """SELECT total_price FROM price_observations
           WHERE product_slug=? AND variant_key=? AND verified=1
           ORDER BY observed_at DESC,id DESC LIMIT 1""",
        (args.product, args.variant),
    ).fetchone()
    previous_price = previous[0] if previous else None
    details = json.loads(args.details)
    with con:
        con.execute(
            """INSERT OR IGNORE INTO price_observations
               (product_slug,observed_at,price,shipping,total_price,currency,seller,url,
                variant_key,verified,details_json)
               VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
            (args.product, observed_at, args.price, args.shipping, total, args.currency,
             args.seller, args.url, args.variant, 0 if args.unverified else 1,
             json.dumps(details, ensure_ascii=False, sort_keys=True)),
        )
    saving = round(previous_price - total, 2) if previous_price is not None else None
    saving_pct = round(saving / previous_price * 100, 6) if previous_price else None
    matched = []
    if not args.unverified:
        conditions = con.execute("SELECT * FROM alert_conditions WHERE product_slug=?", (args.product,))
        for condition in conditions:
            if condition["kind"] == "threshold" and condition["metric"] == "total_price":
                actual = total
            elif (condition["kind"] == "relative_drop"
                  and condition["baseline"] == "previous_comparable_price"
                  and saving_pct is not None):
                actual = saving_pct
            else:
                continue
            if compare(actual, condition["operator"], condition["threshold"]):
                matched.append(condition["id"])
    return {
        "product": args.product,
        "observed_at": observed_at,
        "total_price": total,
        "previous_comparable_price": previous_price,
        "saving_eur": saving,
        "saving_percent": saving_pct,
        "alert": bool(matched),
        "matched_condition_ids": matched,
        "verified": not args.unverified,
    }


def history(con, product, limit):
    rows = con.execute(
        """SELECT observed_at,total_price,price,shipping,currency,seller,url,variant_key,
                  verified,details_json
           FROM price_observations WHERE product_slug=?
           ORDER BY observed_at DESC,id DESC LIMIT ?""",
        (product, limit),
    )
    return [{**dict(row), "details": json.loads(row["details_json"])} for row in rows]


def parser():
    p = argparse.ArgumentParser()
    p.add_argument("--db", default=str(Path(__file__).with_name("prices.sqlite3")))
    p.add_argument("--config", default=str(Path(__file__).with_name("products.json")))
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("sync")
    rec = sub.add_parser("record")
    rec.add_argument("--product", required=True)
    rec.add_argument("--price", required=True, type=float)
    rec.add_argument("--shipping", type=float, default=0)
    rec.add_argument("--currency", default="EUR")
    rec.add_argument("--seller", required=True)
    rec.add_argument("--url", required=True)
    rec.add_argument("--variant", default="")
    rec.add_argument("--details", default="{}")
    rec.add_argument("--observed-at")
    rec.add_argument("--unverified", action="store_true")
    hist = sub.add_parser("history")
    hist.add_argument("--product", required=True)
    hist.add_argument("--limit", type=int, default=20)
    sub.add_parser("products")
    return p


def main():
    args = parser().parse_args()
    con = connect(args.db)
    if args.command == "sync":
        result = sync(con, args.config)
    elif args.command == "record":
        sync(con, args.config)
        result = record(con, args)
    elif args.command == "history":
        result = history(con, args.product, args.limit)
    else:
        result = [dict(row) for row in con.execute(
            "SELECT slug,name,category,currency,metadata_json FROM products WHERE active=1 ORDER BY slug"
        )]
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
