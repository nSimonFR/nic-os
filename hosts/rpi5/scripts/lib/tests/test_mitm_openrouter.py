import pytest

from nicos_scripts.mitm import openrouter as mod


class Headers(dict):
    """Case-insensitive enough for the addon: it only uses lowercase keys and X-Title."""

    def _k(self, k):
        return k.lower()

    def get(self, k, default=None):
        return super().get(self._k(k), default)

    def pop(self, k, default=None):
        return super().pop(self._k(k), default)

    def __setitem__(self, k, v):
        super().__setitem__(self._k(k), v)

    def __getitem__(self, k):
        return super().__getitem__(self._k(k))


class Req:
    def __init__(self, host, path, headers=None):
        self.pretty_host = host
        self.host = "104.18.2.115"
        self.port = 443
        self.scheme = "https"
        self.method = "POST"
        self.path = path
        self.headers = Headers()
        for k, v in (headers or {}).items():
            self.headers[k] = v


class Resp:
    def __init__(self, ctype):
        self.headers = Headers({"content-type": ctype})
        self.stream = False


class Flow:
    def __init__(self, req=None, resp=None):
        self.request = req
        self.response = resp


@pytest.mark.parametrize(
    "path",
    [
        "/api/v1/chat/completions",
        "/api/v1/responses",
        "/api/v1/messages",
        "/api/v1/embeddings",
        "/api/v1/models",
        "/api/v1/models?supported_parameters=tools",
        "/api/v1/models/openai/gpt-5.5",
        "/api/v1/models/user",
        "/api/v1/key",
        "/api/v1/auth/key",
        "/api/v1/credits",
    ],
)
def test_gate_paths(path):
    assert mod.route("openrouter.ai", path) == "gate"


@pytest.mark.parametrize(
    "path",
    [
        "/",
        "/models",  # the website's model page, not the API
        "/auth",  # "Sign in with OpenRouter" (PKCE)
        "/api/v1/auth/keys",  # PKCE code → key exchange
        "/api/v1/generation?id=gen-1",
        "/api/v1/completions",  # legacy, not served by the gate
        "/api/v1/providers",
        "/api/v2/chat/completions",
        "/api/v1/chat/completionsX",
    ],
)
def test_passthrough_paths(path):
    assert mod.route("openrouter.ai", path) == "passthrough"


def test_other_hosts_pass_through():
    assert mod.route("api.openrouter.ai.evil.com", "/api/v1/chat/completions") == "passthrough"
    assert mod.route("example.com", "/api/v1/chat/completions") == "passthrough"


def test_request_rewritten_to_gate_without_app_key():
    req = Req(
        "openrouter.ai",
        "/api/v1/chat/completions",
        {"Authorization": "Bearer sk-or-v1-secret", "x-api-key": "sk-or-v1-secret", "X-Title": "MyApp"},
    )
    mod.OpenRouterToGate("127.0.0.1", 4001).request(Flow(req))
    assert (req.scheme, req.host, req.port) == ("http", "127.0.0.1", 4001)
    assert req.path == "/api/v1/chat/completions"
    assert req.headers.get("authorization") is None
    assert req.headers.get("x-api-key") is None
    assert req.headers["Host"] == "127.0.0.1:4001"
    assert req.headers["X-Title"] == "openrouter-mitm:MyApp"


def test_attribution_without_app_title():
    req = Req("openrouter.ai", "/api/v1/models")
    mod.OpenRouterToGate().request(Flow(req))
    assert req.headers["X-Title"] == "openrouter-mitm"


def test_passthrough_request_untouched():
    req = Req("openrouter.ai", "/api/v1/auth/keys", {"Authorization": "Bearer sk-or-v1-secret"})
    mod.OpenRouterToGate().request(Flow(req))
    assert (req.scheme, req.host, req.port) == ("https", "104.18.2.115", 443)
    assert req.headers["authorization"] == "Bearer sk-or-v1-secret"


@pytest.mark.parametrize(
    "ctype, streamed",
    [("text/event-stream", True), ("text/event-stream; charset=utf-8", True), ("application/json", False)],
)
def test_sse_responses_stream(ctype, streamed):
    flow = Flow(resp=Resp(ctype))
    mod.OpenRouterToGate().responseheaders(flow)
    assert flow.response.stream is streamed
