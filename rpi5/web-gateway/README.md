# rpi5 web-gateway (staged migration)

This directory introduces the first **safe, reversible slice** of a centralized web gateway for rpi5.

## What is in stage 1

- A dedicated Nginx virtual host (`web-gateway.local`) listening on `127.0.0.1:8443`.
- Path-based routes for:
  - `/firefly/` → `127.0.0.1:8080`
  - `/ghostfolio/` → `127.0.0.1:3333`
  - `/openclaw/` → `127.0.0.1:18789`
- Compatibility route:
  - `/` still proxies to OpenClaw (`127.0.0.1:18789`) so existing `https://rpi5:443` behavior remains usable.

## Tailscale Serve behavior in this stage

- `:443` now points to the gateway (`127.0.0.1:8443`) so path routing can be introduced incrementally.
- Legacy direct service endpoint `:3333` is intentionally kept for compatibility.

## Why this is safe

- Existing local service ports are unchanged.
- The migration is additive and can be rolled back by reverting this subtree and Tailscale mapping change.
- No service-specific module was removed.

## Next steps (future PRs)

1. Validate app behavior under prefixed paths and adjust app base URLs as needed.
2. Add additional services behind explicit prefixes.
3. Decide timeline to deprecate legacy direct Tailscale ports.
4. Add route-level auth/rate limits where appropriate.
