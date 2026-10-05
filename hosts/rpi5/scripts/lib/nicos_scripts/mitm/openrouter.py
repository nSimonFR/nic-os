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

# openrouter.ai's own CORS policy; the gate sends none, so browser apps fail
# the preflight (gate 405s OPTIONS) and then the response read.
CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Expose-Headers": "X-Generation-Id,X-Provider-Name,request-id",
}
PREFLIGHT_HEADERS = {
    **CORS_HEADERS,
    "Access-Control-Allow-Methods": "GET,OPTIONS,PATCH,DELETE,POST,PUT",
    "Access-Control-Allow-Headers": "*,Authorization",
    "Access-Control-Max-Age": "86400",
}


def route(host: str, path: str) -> str:
    """'gate' for an OpenRouter API call the gate serves, else 'passthrough'."""
    if host != OPENROUTER_HOST:
        return "passthrough"
    return "gate" if GATE_PATHS.match(path) else "passthrough"


def attribution(app_title: str | None) -> str:
    return f"{ATTRIBUTION}:{app_title}" if app_title else ATTRIBUTION


def _make_response(status: int, headers: dict):
    from mitmproxy import http

    return http.Response.make(status, b"", headers)


class OpenRouterToGate:
    def __init__(self, gate_host: str = "127.0.0.1", gate_port: int = 4001, make_response=_make_response):
        self.gate_host = gate_host
        self.gate_port = gate_port
        self.make_response = make_response

    def request(self, flow):
        req = flow.request
        # In transparent mode req.host is the destination IP; pretty_host is the SNI.
        if route(req.pretty_host, req.path) != "gate":
            return
        if req.method == "OPTIONS":
            flow.response = self.make_response(204, PREFLIGHT_HEADERS)
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
        if (flow.request.host, flow.request.port) == (self.gate_host, self.gate_port):
            for k, v in CORS_HEADERS.items():
                flow.response.headers[k] = v
        # mitmproxy buffers whole bodies by default, which would hold back every
        # token of an SSE stream until the end.
        ctype = flow.response.headers.get("content-type", "")
        if ctype.startswith("text/event-stream"):
            flow.response.stream = True


addons = [OpenRouterToGate()]
