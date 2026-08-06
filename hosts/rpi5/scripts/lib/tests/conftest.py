"""Fakes for the injectable seams. No network, no /var/lib, no os.environ."""

import io
import json

import pytest


class FakeResponse(io.BytesIO):
    """Enough of an http.client.HTTPResponse for httpjson to work with."""

    def __init__(self, body=b"", status=200):
        super().__init__(body)
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


class FakeOpener:
    """Drop-in for `urllib.request.urlopen`.

    Records every Request it is handed and replies from a queue of responses
    (the last one repeats, so single-reply tests stay terse).
    """

    def __init__(self, replies=None):
        self.replies = list(replies or [FakeResponse(b"{}")])
        self.requests = []

    def __call__(self, req, timeout=None):
        self.requests.append(req)
        reply = self.replies.pop(0) if len(self.replies) > 1 else self.replies[0]
        return reply() if callable(reply) else reply

    @property
    def last(self):
        return self.requests[-1]

    def body_of(self, index=-1):
        return json.loads(self.requests[index].data.decode())


def json_reply(obj, status=200):
    return lambda: FakeResponse(json.dumps(obj).encode(), status)


@pytest.fixture
def opener():
    return FakeOpener


@pytest.fixture
def logged():
    """A `log` callable that appends to a list instead of writing to stdout."""
    lines = []
    return lines, lines.append
