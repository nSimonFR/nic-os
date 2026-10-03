"""mitmproxy addon: serve openrouter.ai's API from tiny-llm-gate.

Apps on the tailnet that call https://openrouter.ai/api/v1 are transparently
redirected (openrouter-mitm.nix) here. The API paths the gate implements go to
the gate; everything else — the website, "Sign in with OpenRouter", /generation —
reaches the real openrouter.ai untouched.

Gate-only by design: an unknown model is the gate's 404 and a gate outage is a
502, never a silent fallback that spends OpenRouter credits.
"""

import re

OPENROUTER_HOST = "openrouter.ai"

# Exactly what tiny-llm-gate v0.10.0 serves under /api/v1.
GATE_PATHS = re.compile(
    r"^/api/v1/(chat/completions|responses|messages|embeddings"
    r"|models(/.*)?|key|auth/key|credits)/?(\?.*)?$"
)

# The app's OpenRouter key must not reach the gate or its logs.
CREDENTIAL_HEADERS = ("authorization", "x-api-key")

ATTRIBUTION = "openrouter-mitm"


def route(host: str, path: str) -> str:
    """'gate' for an OpenRouter API call the gate serves, else 'passthrough'."""
    if host != OPENROUTER_HOST:
        return "passthrough"
    return "gate" if GATE_PATHS.match(path) else "passthrough"


def attribution(app_title: str | None) -> str:
    return f"{ATTRIBUTION}:{app_title}" if app_title else ATTRIBUTION


class OpenRouterToGate:
    def __init__(self, gate_host: str = "127.0.0.1", gate_port: int = 4001):
        self.gate_host = gate_host
        self.gate_port = gate_port

    def request(self, flow):
        req = flow.request
        # In transparent mode req.host is the destination IP; pretty_host is the SNI.
        if route(req.pretty_host, req.path) != "gate":
            return
        for h in CREDENTIAL_HEADERS:
            req.headers.pop(h, None)
        req.headers["X-Title"] = attribution(req.headers.get("X-Title"))
        req.scheme = "http"
        req.host = self.gate_host
        req.port = self.gate_port
        req.headers["Host"] = f"{self.gate_host}:{self.gate_port}"
        print(f"[openrouter-mitm] {req.method} {req.path} -> gate", flush=True)

    def responseheaders(self, flow):
        # mitmproxy buffers whole bodies by default, which would hold back every
        # token of an SSE stream until the end.
        ctype = flow.response.headers.get("content-type", "")
        if ctype.startswith("text/event-stream"):
            flow.response.stream = True


addons = [OpenRouterToGate()]
