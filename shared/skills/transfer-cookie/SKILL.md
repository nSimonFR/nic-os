---
name: transfer-cookie
description: Log the agent's T3 preview tab into a site by copying the user's existing browser session (Zen, or the T3 desktop panel) instead of a login. Use when an agent tab lands on a sign-in or SSO page the agent cannot pass, or the user says "transfer cookie", "copie ma session", "je suis connecté dans Zen".
---

# Transfer cookie

The agent's tabs (`preview_open`) run in T3's headless Chromium; the user's panel and
Zen keep their own cookie jars. The user cannot log in "in the agent tab", and SSO there
fails. Copy their session instead. Ask once before the first copy: it is their login.

1. The user logs into the site in Zen (default) or in their T3 panel (`--source t3`).
2. `scripts/cookie-js.py <domain>` prints one JS block per cookie host, and on stderr the
   `exp` of any Rails-signed token. Past `exp` = stale session, even if the cookie
   is still there: ask the user to log in again.
3. For each `==` block: `preview_navigate` to a page on that host (the sign-in page
   will do), then `preview_evaluate` the block. A host-only cookie can only be set from
   its own host, so a site with an API subdomain needs two stops.
4. `preview_navigate` to the target page and read `location.href`. Back on `/signin` or
   the IdP = refused.

- `document.cookie` cannot set `HttpOnly`; servers seen so far (Elevo, Trusk BO) accept
  the cookie anyway.
- Chrome and Safari stores are encrypted (Keychain): not supported, use Zen.
- The value passes through the tool call; never echo it in chat or write it outside the
  scratchpad. The script deletes its copy of the store.
- The agent session dies with the user's: re-run after each re-login.
