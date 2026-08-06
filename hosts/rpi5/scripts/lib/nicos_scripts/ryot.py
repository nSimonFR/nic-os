"""One Ryot client for the Python connectors.

There were four Ryot clients speaking three protocols. This module owns the two
Python ones:

  * the Generic JSON sink (`/ryot/_i/<slug>`) — takes a `CompleteExport` body;
    used by the Steam and Spotify pull connectors.
  * GraphQL — used by the scale shim's `createOrUpdateUserMeasurement`.

(`hosts/rpi5/scripts/ryot-plex-import.sh` still speaks GraphQL via curl+jq and drops
to raw psql DML. Out of scope here — it is a shell rewrite, not an extraction.)

The `reviews`/`collections` empty lists in `metadata_item` are load-bearing:
they are non-optional in Ryot's `ImportOrExportMetadataItem`, and omitting
either makes the strict deserialize drop the whole item silently.
"""

import json
import urllib.request

from .httpjson import http_json, post_json

# Ryot answers the sink with any of these on success.
OK_STATUS = (200, 201, 202)


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


def post_export(url, metadata, timeout=60, opener=None):
    """POST a CompleteExport body to a Generic JSON integration webhook."""
    return post_json(url, {"metadata": metadata}, timeout=timeout, opener=opener)


def is_ok(status):
    return status in OK_STATUS


def graphql(url, token, query, variables, timeout=15, opener=None):
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
