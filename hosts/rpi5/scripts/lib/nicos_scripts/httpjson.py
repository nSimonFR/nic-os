"""Minimal JSON-over-HTTP on urllib — the shared half of every connector.

`opener` is the seam. It defaults to `urllib.request.urlopen`, so production
code passes nothing; tests pass a fake that returns a canned body and records
the request it was handed.
"""

import json
import urllib.parse
import urllib.request


def _urlopen(opener):
    return opener or urllib.request.urlopen


def http_json(req, timeout=30, opener=None):
    """Send a prepared Request, decode the JSON body ({} when empty)."""
    with _urlopen(opener)(req, timeout=timeout) as resp:
        raw = resp.read().decode()
    return json.loads(raw) if raw else {}


def get_json(url, headers=None, timeout=30, opener=None):
    req = urllib.request.Request(url, headers=headers or {})
    return http_json(req, timeout=timeout, opener=opener)


def post_form(url, fields, headers=None, timeout=30, opener=None):
    """POST an x-www-form-urlencoded body, decode the JSON reply.

    Used by both OAuth token exchanges (Spotify refresh, Twitch client creds).
    """
    body = urllib.parse.urlencode(fields).encode()
    hdrs = {"Content-Type": "application/x-www-form-urlencoded"}
    hdrs.update(headers or {})
    req = urllib.request.Request(url, data=body, headers=hdrs, method="POST")
    return http_json(req, timeout=timeout, opener=opener)


def post_json(url, payload, headers=None, timeout=60, opener=None):
    """POST a JSON body. Returns (status, raw_text) — callers check the status
    themselves because Ryot answers 200/201/202 interchangeably."""
    hdrs = {"Content-Type": "application/json"}
    hdrs.update(headers or {})
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), headers=hdrs, method="POST"
    )
    with _urlopen(opener)(req, timeout=timeout) as resp:
        return resp.status, resp.read().decode()
