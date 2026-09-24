"""mitmproxy addon: route Claude Code's inference through Aperture while the
session still believes it is talking to api.anthropic.com.

Why this exists: Remote Control refuses to run unless ANTHROPIC_BASE_URL points
at api.anthropic.com, but Aperture only records traffic that physically passes
through it — there is no ingest API (/api/logs is a 501 stub). Pointing the base
URL at Aperture therefore costs Remote Control, and pointing it at Anthropic
costs gateway capture.

So don't rewrite the URL, intercept a layer lower: Claude Code reaches this proxy
via HTTPS_PROXY and trusts its CA via NODE_EXTRA_CA_CERTS (which scopes the CA to
Claude Code alone — no system trust store change), and inference requests are
re-targeted at Aperture. The guard sees api.anthropic.com; Aperture sees and
captures the request.

Also keeps one Aperture session across auto-compactions (session_link.py).

Driven by home/claude-aperture-shim.nix; use the `claude-gated` wrapper.
"""

import json
import os
from pathlib import Path

from mitmproxy import ctx, http

from session_link import SessionLinks

APERTURE_HOST = os.environ.get("APERTURE_SHIM_HOST", "ai.gate-mintaka.ts.net")
# https/443 rather than http/80: the inbound flow arrives over a CONNECT tunnel,
# and rewriting scheme/port on such a flow is not honoured consistently — on the
# rpi5 the upstream leg stayed on https/443 while the Mac followed the override to
# http/80. Both work (Aperture serves both), but defaulting to https means the
# hop is encrypted either way and the two hosts behave identically.
APERTURE_PORT = int(os.environ.get("APERTURE_SHIM_PORT", "443"))
APERTURE_SCHEME = os.environ.get("APERTURE_SHIM_SCHEME", "https")

# Aperture implements the LLM inference surface only. Claude Code calls a control
# plane on the same host (/api/claude_code/settings, /api/claude_code/policy_limits,
# /v1/mcp_servers, /mcp-registry/..., /api/eval/..., /api/event_logging/...) which
# Aperture 404s. Redirecting those breaks them SILENTLY — the session still
# answers, so it looks fine — hence an explicit allowlist rather than a catch-all.
# Revisit if Anthropic adds an inference path: anything missing here quietly
# bypasses the gateway.
INFERENCE_PREFIXES = ("/v1/messages", "/v1/complete")

_links: SessionLinks | None = None


def _link_session(flow: http.HTTPFlow) -> None:
    global _links
    if _links is None:
        confdir = Path(os.path.expanduser(ctx.options.confdir))
        _links = SessionLinks(confdir / "session-links.json")
    try:
        body = json.loads(flow.request.content or b"")
    except ValueError:
        return
    if not isinstance(body, dict):
        return
    root = _links.link(body)
    if root is None:
        return
    # Re-serialising is safe for prompt caching, which keys on content, not bytes.
    flow.request.content = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
    flow.request.headers["X-Claude-Code-Session-Id"] = root


def request(flow: http.HTTPFlow) -> None:
    if flow.request.pretty_host != "api.anthropic.com":
        return
    if not flow.request.path.startswith(INFERENCE_PREFIXES):
        return
    if flow.request.path.startswith("/v1/messages"):
        try:
            _link_session(flow)
        except Exception as e:  # never fail inference over session grouping
            ctx.log.warn(f"session link skipped: {e!r}")
    flow.request.scheme = APERTURE_SCHEME
    flow.request.host = APERTURE_HOST
    flow.request.port = APERTURE_PORT
    flow.request.headers["Host"] = APERTURE_HOST
