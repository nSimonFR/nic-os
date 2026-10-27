"""One Ryot client for the Python connectors.

There were four Ryot clients speaking three protocols. This module owns the two
Python ones:

  * the Generic JSON sink (`/ryot/_i/<slug>`) — takes a `CompleteExport` body;
    used by the Steam and Spotify pull connectors.
  * GraphQL — V1's API; nothing in this package calls it any more.
  * V2 REST (`api_post`, `ryotql`, `invoke_operation`) — the scale shim.

(`hosts/rpi5/scripts/ryot-plex-import.sh` still speaks GraphQL via curl+jq and drops
to raw psql DML. Out of scope here — it is a shell rewrite, not an extraction.)

The `reviews`/`collections` empty lists in `metadata_item` are load-bearing:
they are non-optional in Ryot's `ImportOrExportMetadataItem`, and omitting
either makes the strict deserialize drop the whole item silently.
"""

import json
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request

from .httpjson import http_json, post_json

# Ryot answers the sink with any of these on success.
OK_STATUS = (200, 201, 202)

# V2 is always-on, but a restart (image unpack, migrations) can hold a request for
# minutes; give up later rather than drop a weigh-in.
RYOT_WAKE_TIMEOUT = 240


def seen(ended_on, progress=100, providers=None, manual_time_spent=None):
    """One entry of `seen_history`.

    `manual_time_spent` is seconds-as-string (Ryot Decimal); pass None to omit
    it entirely — a null there is not the same as an absent key.
    """
    entry = {"progress": progress, "ended_on": ended_on}
    if manual_time_spent is not None:
        entry["manual_time_spent"] = manual_time_spent
    entry["providers_consumed_on"] = list(providers or [])
    return entry


def metadata_item(lot, source, identifier, source_id, seen_history):
    return {
        "lot": lot,
        "source": source,
        "identifier": identifier,
        "source_id": source_id,
        # Non-optional in ImportOrExportMetadataItem — see the module docstring.
        # `collections` stays empty on purpose: CollectionToEntityDetails needs a
        # collection_id + timestamps the connectors cannot supply, and one bad
        # entry drops the whole item. Items attach to the library via their seen.
        "reviews": [],
        "collections": [],
        "seen_history": seen_history,
    }


def post_export(url, metadata, timeout=RYOT_WAKE_TIMEOUT, opener=None):
    """POST a CompleteExport body to a Generic JSON integration webhook."""
    return post_json(url, {"metadata": metadata}, timeout=timeout, opener=opener)


def is_ok(status):
    return status in OK_STATUS


def graphql(url, token, query, variables, timeout=RYOT_WAKE_TIMEOUT, opener=None):
    """Run a GraphQL operation, returning the `data` object.

    Raises RuntimeError on a GraphQL-level error — those come back inside a 200,
    so a status check alone would report success on a failed mutation.
    """
    out = http_json(
        _graphql_request(url, token, query, variables), timeout=timeout, opener=opener
    )
    if out.get("errors"):
        raise RuntimeError(f"Ryot GraphQL error: {out['errors']}")
    return out.get("data") or {}


def _graphql_request(url, token, query, variables):
    return urllib.request.Request(
        url,
        data=json.dumps({"query": query, "variables": variables}).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + token,
        },
        method="POST",
    )


def api_post(base, api_key, path, payload, timeout=RYOT_WAKE_TIMEOUT, opener=None):
    """POST JSON to a Ryot V2 `/api` route as the API key's user.

    V2 answers failures with a JSON body (`_tag` + `reason`) and a 4xx/5xx; that
    body is the only useful diagnostic, so it is folded into the RuntimeError.
    """
    req = urllib.request.Request(
        base.rstrip("/") + "/api" + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "X-Api-Key": api_key},
        method="POST",
    )
    try:
        return http_json(req, timeout=timeout, opener=opener)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Ryot {path} -> {e.code}: {e.read().decode()[:500]}") from e


def ryotql(base, api_key, queries, timeout=RYOT_WAKE_TIMEOUT, opener=None):
    """Run a RyotQL document (scoped to the key's user), returning its `data`."""
    out = api_post(
        base, api_key, "/ryotql/execute", {"queries": queries}, timeout=timeout, opener=opener
    )
    return out.get("data") or {}


def invoke_operation(
    base,
    api_key,
    package_id,
    slug,
    payload,
    idempotency_key=None,
    timeout=RYOT_WAKE_TIMEOUT,
    opener=None,
):
    """Invoke a plugin operation, returning its `result`.

    Reusing an `idempotency_key` with the same payload returns the first
    execution's result; with a different payload Ryot answers 400.
    """
    body = {"payload": payload}
    if idempotency_key is not None:
        body["idempotencyKey"] = idempotency_key
    path = f"/plugins/{package_id}/operations/{slug}"
    return api_post(base, api_key, path, body, timeout=timeout, opener=opener)["result"]


# API keys are limited to 60 requests per rolling minute; one per second never trips it.
API_PAUSE_SEC = 1.0
RATE_LIMIT_RETRIES = 3
# The import result endpoint long-polls ~20 s per request.
IMPORT_POLLS = 6
# A 502 diagnostic for an operation whose script never started, so nothing was written.
SIDECAR_STARTUP_FAILED = "Sandbox sidecar startup failed"


class ImportStalled(RuntimeError):
    """A provider import still unfinished after IMPORT_POLLS; some never finish."""


class RateLimited(RuntimeError):
    def __init__(self, path, retry_after_ms):
        super().__init__(f"Ryot {path} -> 429 (retry after {retry_after_ms} ms)")
        self.retry_after_ms = retry_after_ms


def api_request(base, api_key, method, path, payload=None, timeout=RYOT_WAKE_TIMEOUT, opener=None):
    """Any-verb `/api` call; raises RateLimited on 429, RuntimeError on other errors."""
    req = urllib.request.Request(
        base.rstrip("/") + "/api" + path,
        data=None if payload is None else json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "X-Api-Key": api_key},
        method=method,
    )
    try:
        return http_json(req, timeout=timeout, opener=opener)
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code == 429:
            try:
                wait = json.loads(body)["reason"]["retryAfterMs"]
            except (ValueError, KeyError, TypeError):
                wait = None
            raise RateLimited(path, wait) from e
        raise RuntimeError(f"Ryot {path} -> {e.code}: {body[:500]}") from e


class Client:
    """V2 REST as one API key, paced under its rate limit."""

    def __init__(self, base, api_key, opener=None, sleep=None, log=None):
        self.base = base
        self.api_key = api_key
        self.opener = opener
        self.sleep = sleep or time.sleep
        self.log = log or (lambda _msg: None)
        self.calls = 0

    def request(self, method, path, payload=None):
        for attempt in range(RATE_LIMIT_RETRIES + 1):
            if self.calls:
                self.sleep(API_PAUSE_SEC)
            self.calls += 1
            try:
                return api_request(
                    self.base, self.api_key, method, path, payload, opener=self.opener
                )
            except RateLimited as e:
                if attempt == RATE_LIMIT_RETRIES:
                    raise
                wait = (e.retry_after_ms or 60000) / 1000 + 1
                self.log(f"Ryot rate limit hit; waiting {wait:.0f}s")
                self.sleep(wait)

    def query(self, queries):
        return self.request("POST", "/ryotql/execute", {"queries": queries}).get("data") or {}

    def query_all(self, name, query):
        """Every row of one RyotQL rows query, following `after` cursors."""
        rows, after = [], None
        while True:
            q = json.loads(json.dumps(query))
            if after:
                q["output"]["pagination"]["after"] = after
            page = self.query({name: q})[name]
            rows.extend(page["items"])
            after = page["pageInfo"].get("nextCursor")
            if not page["pageInfo"].get("hasMore") or not after:
                return rows

    def operation(self, package_id, slug, payload, idempotency_key=None):
        """A plugin operation's `result` (200 even on refusal: callers check it)."""
        path = f"/plugins/{package_id}/operations/{slug}"
        body = {"payload": payload}
        if idempotency_key is not None:
            body["idempotencyKey"] = idempotency_key
        try:
            return self.request("POST", path, body)["result"]
        except RuntimeError as e:
            # Ryot replays a stored failure for the key forever, even one where the
            # script never ran (seen 2026-10-26 after earlyoom killed the sandbox).
            if idempotency_key is None or SIDECAR_STARTUP_FAILED not in str(e):
                raise
        body["idempotencyKey"] = f"{idempotency_key}~{secrets.token_hex(4)}"
        self.log(f"Ryot {path}: sandbox never started for {idempotency_key}; retrying under a new key")
        return self.request("POST", path, body)["result"]

    def import_entity(self, provider_id, external_id):
        """Import through a provider; the entity id, or "" when the import failed."""
        job = self.request(
            "POST",
            "/entity-providers/imports",
            {"providerId": provider_id, "externalId": external_id},
        )["jobId"]
        status = None
        for _ in range(IMPORT_POLLS):
            res = self.request("GET", "/entity-providers/imports/" + urllib.parse.quote(job, safe=""))
            status = res.get("status")
            if status == "completed":
                return res["data"]["id"]
            if status in ("failed", "cancelled"):
                self.log(f"import of {external_id} {status}: {json.dumps(res)[:300]}")
                return ""
        raise ImportStalled(f"import of {external_id} still {status} after {IMPORT_POLLS} polls")


# ── RyotQL expression builders ────────────────────────────────────────────────

# RyotQL returns at most 100 rows per query.
RYOTQL_PAGE = 100


def ql_col(alias, field):
    return {"type": "column", "tableAlias": alias, "field": field}


def ql_lit(value):
    return {"type": "literal", "value": value}


def ql_prop(alias, key, cast=None):
    """A `properties` key. Comparing one needs a cast ("text"/"number"): a bare
    jsonPath in a predicate is refused as invalid-query."""
    expr = {"type": "jsonPath", "expr": ql_col(alias, "properties"), "path": [key]}
    return {"type": "cast", "target": cast, "expr": expr} if cast else expr


def ql_cmp(op, left, right):
    return {"type": "comparison", "operator": op, "left": left, "right": right}


def ql_eq(alias, field, value):
    return ql_cmp("eq", ql_col(alias, field), ql_lit(value))


def ql_in(expr, values):
    return {"type": "in", "expr": expr, "values": [ql_lit(v) for v in values]}


def ql_and(*predicates):
    return {"type": "and", "predicates": list(predicates)}


def ql_join(table, alias, on):
    return {"type": "inner", "table": {"table": table, "alias": alias}, "on": on}


def ql_rows(table, alias, where, fields, limit=RYOTQL_PAGE, order_by=None, joins=None):
    """A rows query; ordered by id unless told otherwise (pagination needs a total order)."""
    q = {
        "from": {"table": table, "alias": alias},
        "where": where,
        "output": {
            "type": "rows",
            "pagination": {"limit": limit},
            "orderBy": order_by or [{"direction": "asc", "expr": ql_col(alias, "id")}],
            "fields": [{"key": k, "expr": e} for k, e in fields.items()],
        },
    }
    if joins:
        q["joins"] = joins
    return q
