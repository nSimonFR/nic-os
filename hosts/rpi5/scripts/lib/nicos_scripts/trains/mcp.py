#!/usr/bin/env python3
"""
train-prices-mcp: stdio MCP server for live train prices.

Stdio JSON-RPC via nicos_scripts.mcpstdio. Hermes launches it as a subprocess,
so it costs nothing at rest.
Env: TRAIN_SOURCES.
"""

import sys
import urllib.error
from datetime import date

from .. import mcpstdio
from ..logs import logger
from . import sources as src

# stderr: stdout is the protocol stream.
log = logger("train-prices-mcp", lambda: sys.stderr)

_SOURCE_ERRORS = (
    urllib.error.URLError,
    OSError,
    ValueError,
    KeyError,
    LookupError,
    RuntimeError,
)

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
        journeys, errors = [], {}
        for name, client in self._chosen(sources).items():
            try:
                journeys += client.search(origin, destination, date)
            except _SOURCE_ERRORS as e:  # one dead source must not hide the other
                errors[name] = f"{type(e).__name__}: {e}"
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


def handle(msg, handlers):
    return mcpstdio.handle(msg, TOOLS, handlers, SERVER, log)


def serve(handlers, stdin=None, stdout=None):
    mcpstdio.serve(TOOLS, handlers, SERVER, log, stdin, stdout)


def main(argv=None, env=None):
    del argv
    serve(Handlers(src.make_sources(env)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
