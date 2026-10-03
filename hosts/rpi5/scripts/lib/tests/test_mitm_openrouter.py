from types import SimpleNamespace

import pytest

from nicos_scripts.mitm import openrouter as mod

GATE = [
    "/api/v1/chat/completions", "/api/v1/responses", "/api/v1/messages", "/api/v1/embeddings",
    "/api/v1/models", "/api/v1/models?supported_parameters=tools", "/api/v1/models/openai/gpt-5.5",
    "/api/v1/models/user", "/api/v1/key", "/api/v1/auth/key", "/api/v1/credits",
]
PASSTHROUGH = [
    "/", "/models", "/auth",  # website, incl. "Sign in with OpenRouter"
    "/api/v1/auth/keys",  # PKCE code → key exchange
    "/api/v1/generation?id=gen-1", "/api/v1/completions", "/api/v1/providers",
    "/api/v2/chat/completions", "/api/v1/chat/completionsX",
]


@pytest.mark.parametrize("path", GATE)
def test_gate_paths(path):
    assert mod.route("openrouter.ai", path) == "gate"


@pytest.mark.parametrize("path", PASSTHROUGH)
def test_passthrough_paths(path):
    assert mod.route("openrouter.ai", path) == "passthrough"


@pytest.mark.parametrize("host", ["example.com", "openrouter.ai.evil.com", "clerk.openrouter.ai"])
def test_other_hosts_pass_through(host):
    assert mod.route(host, "/api/v1/chat/completions") == "passthrough"


def flow(path, **headers):
    # Lowercase keys, as mitmproxy's Headers matches case-insensitively.
    req = SimpleNamespace(pretty_host="openrouter.ai", host="104.18.2.115", port=443, scheme="https",
                          method="POST", path=path, headers={k.lower().replace("_", "-"): v for k, v in headers.items()})
    return SimpleNamespace(request=req)


class Headers(dict):
    def __setitem__(self, k, v):
        super().__setitem__(k.lower(), v)

    def get(self, k, default=None):
        return super().get(k.lower(), default)


def test_gate_request_rewritten_without_app_key():
    f = flow("/api/v1/chat/completions", authorization="Bearer sk-or-v1-x", x_api_key="sk-or-v1-x", x_title="MyApp")
    f.request.headers = Headers(f.request.headers)
    mod.OpenRouterToGate().request(f)
    r = f.request
    assert (r.scheme, r.host, r.port, r.path) == ("http", "127.0.0.1", 4001, "/api/v1/chat/completions")
    assert "authorization" not in r.headers and "x-api-key" not in r.headers
    assert r.headers["host"] == "127.0.0.1:4001"
    assert r.headers["x-title"] == "openrouter-mitm:MyApp"


def test_attribution_without_app_title():
    assert mod.attribution(None) == "openrouter-mitm"


def test_passthrough_request_untouched():
    f = flow("/api/v1/auth/keys", authorization="Bearer sk-or-v1-x")
    mod.OpenRouterToGate().request(f)
    assert (f.request.scheme, f.request.host, f.request.port) == ("https", "104.18.2.115", 443)
    assert f.request.headers["authorization"] == "Bearer sk-or-v1-x"


@pytest.mark.parametrize("ctype, streamed", [
    ("text/event-stream", True), ("text/event-stream; charset=utf-8", True), ("application/json", False),
])
def test_sse_responses_stream(ctype, streamed):
    f = SimpleNamespace(response=SimpleNamespace(headers={"content-type": ctype}, stream=False))
    mod.OpenRouterToGate().responseheaders(f)
    assert f.response.stream is streamed
