#!/usr/bin/env python3
"""
train-prices-mcp: stdio MCP server for live train prices.

Hand-rolled JSON-RPC (initialize / tools/list / tools/call over newline-delimited
stdio) so nicos-scripts stays free of the `mcp` SDK. Hermes launches it as a
subprocess, so it costs nothing at rest. Alerts are `hermes-train-watch`, on cron.

Env: TRAIN_WATCH_SOURCES.
"""

import json
import sys
from datetime import date

from ..logs import logger
from . import sources as src
from . import watch as w

# stderr: stdout is the protocol stream.
log = logger("train-prices-mcp", lambda: sys.stderr)

PROTOCOL = "2025-06-18"
SERVER = {"name": "train-prices", "version": "0.1.0"}

_STR = {"type": "string"}
_DATE = {"type": "string", "description": "YYYY-MM-DD"}
_SOURCES = {
    "type": "array",
    "items": {"type": "string", "enum": list(src.SOURCES)},
    "description": "ouigo, inoui (TGV INOUI via 12train). Default: both.",
}


def _schema(props, required):
    return {"type": "object", "properties": props, "required": required}


TOOLS = {
    "train_prices": {
        "description": "Live prices for one day, cheapest 2nd class per train, OUIGO and TGV INOUI.",
        "inputSchema": _schema(
            {
                "origin": {**_STR, "description": "City or station, e.g. Paris, Brest"},
                "destination": _STR,
                "date": _DATE,
                "sources": _SOURCES,
                "max_changes": {
                    "type": "integer",
                    "description": "Default 0 (direct only)",
                },
            },
            ["origin", "destination", "date"],
        ),
    },
    "train_calendar": {
        "description": "OUIGO lowest fare per day over a range (max 62 days). One call; use it to pick a cheap day.",
        "inputSchema": _schema(
            {"origin": _STR, "destination": _STR, "start": _DATE, "end": _DATE},
            ["origin", "destination", "start", "end"],
        ),
    },
}


class Handlers:
    """Tool bodies. `sources` is the seam."""

    def __init__(self, sources):
        self.sources = sources

    def _chosen(self, names):
        names = names or list(self.sources)
        missing = [n for n in names if n not in self.sources]
        if missing:
            raise ValueError(f"source indisponible : {', '.join(missing)}")
        return {n: self.sources[n] for n in names}

    def train_prices(self, origin, destination, date, sources=None, max_changes=0):
        watch = {
            "sources": ",".join(self._chosen(sources)),
            "origin": origin,
            "destination": destination,
            "date": date,
        }
        journeys, errors = w.search(watch, self.sources)
        keep = [j for j in journeys if j.changes <= max_changes]
        return {
            "trains": [j.to_dict() for j in sorted(keep, key=lambda j: j.departs)],
            "errors": errors,
        }

    def train_calendar(self, origin, destination, start, end):
        if (date.fromisoformat(end) - date.fromisoformat(start)).days not in range(
            0, 62
        ):
            raise ValueError("la plage doit faire 62 jours au plus, end >= start")
        days = self._chosen(["ouigo"])["ouigo"].calendar(
            origin, destination, start, end
        )
        return {
            "source": "ouigo",
            "days": [{"date": d, "price": p, "promo": promo} for d, p, promo in days],
        }


def _result(rid, payload):
    return {"jsonrpc": "2.0", "id": rid, "result": payload}


def _error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def handle(msg, handlers):
    """One JSON-RPC message -> reply dict, or None for a notification."""
    method, rid = msg.get("method"), msg.get("id")
    if rid is None:  # notifications/initialized and friends
        return None
    if method == "initialize":
        asked = (msg.get("params") or {}).get("protocolVersion") or PROTOCOL
        return _result(
            rid,
            {
                "protocolVersion": asked,
                "capabilities": {"tools": {}},
                "serverInfo": SERVER,
            },
        )
    if method == "ping":
        return _result(rid, {})
    if method == "tools/list":
        return _result(
            rid, {"tools": [{"name": n, **spec} for n, spec in TOOLS.items()]}
        )
    if method == "tools/call":
        params = msg.get("params") or {}
        name = params.get("name")
        if name not in TOOLS:
            return _error(rid, -32602, f"outil inconnu : {name}")
        try:
            data = getattr(handlers, name)(**(params.get("arguments") or {}))
            return _result(
                rid,
                {
                    "content": [
                        {"type": "text", "text": json.dumps(data, ensure_ascii=False)}
                    ]
                },
            )
        except Exception as e:  # a tool failure is an isError result, not a dead server
            log(f"{name} failed: {type(e).__name__}: {e}")
            return _result(
                rid,
                {
                    "isError": True,
                    "content": [{"type": "text", "text": f"{type(e).__name__}: {e}"}],
                },
            )
    return _error(rid, -32601, f"méthode inconnue : {method}")


def serve(handlers, stdin=None, stdout=None):
    stdin, stdout = stdin or sys.stdin, stdout or sys.stdout
    for line in stdin:
        if not line.strip():
            continue
        try:
            reply = handle(json.loads(line), handlers)
        except ValueError:
            reply = _error(None, -32700, "JSON invalide")
        if reply is not None:
            stdout.write(json.dumps(reply, ensure_ascii=False) + "\n")
            stdout.flush()


def main(argv=None, env=None):
    del argv
    serve(Handlers(src.make_sources(env)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
