# Single source of truth for all services exposed via Tailscale Serve/Funnel.
# Consumed by tailscale-serve.nix (port routing) and homepage.nix (dashboard tiles).
#
# Icon formats:
#   "name.svg" / "name.png"  → dashboard-icons (walkxcode CDN)
#   "mdi-name"               → Material Design Icons (no extension)
#   "si-name"                → Simple Icons (no extension)
#
# `funnel = true` marks an entry for `tailscale funnel` (publicly accessible)
# instead of `tailscale serve` (tailnet-only). Display order in homepage
# follows list order regardless of funnel flag.
#
# `proxied = true` marks an entry that is fronted by the nginx path-mux
# (see front-proxy.nix): tailscale-serve.nix emits NO serve/funnel command
# for it (the single Front Proxy funnel on 443 fronts it instead), but
# homepage still renders its tile. Such entries carry `path` (e.g. "/affine")
# so the homepage tile links to https://<host><path>.
#
# Widget: optional homepage widget config (type + extra fields).
#   Secrets use {{HOMEPAGE_VAR_NAME}} syntax resolved from environmentFile.
{ }:
{
  entries = [
    # Apps: Nextcloud → AFFiNE → Sure → Immich → Papra → Open WebUI → Karakeep → Home Assistant → Beszel
    { port = 443;   backend = "http://127.0.0.1:8091";  name = "Nextcloud";      icon = "nextcloud.svg";      category = "Apps"; description = "Files + Contacts + Calendar (DAV)"; proxied = true; path = "/nextcloud";
      widget = {
        type = "nextcloud";
        url = "http://127.0.0.1:8091";
        # serverinfo NC-Token (set to nextcloud-homepage-password by the
        # nextcloud-serverinfo-token oneshot). Basic auth as nsimon 401s.
        key = "{{HOMEPAGE_VAR_NEXTCLOUD_PASSWORD}}";
        fields = [ "freespace" "activeusers" "numfiles" "numshares" ];
      }; }
    { port = 8443; backend = "http://127.0.0.1:13010"; name = "AFFiNE";         icon = "affine.svg";         category = "Apps"; description = "Collaborative docs"; funnel = true;
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:13010/graphql";
        method = "POST";
        headers = { "Content-Type" = "application/json"; "Authorization" = "Bearer {{HOMEPAGE_VAR_AFFINE_TOKEN}}"; };
        requestBody = { query = "{ workspaces { memberCount blobsSize docs(pagination: {first: 0}) { totalCount } } }"; };
        display = "block";
        mappings = [
          { field = "data.workspaces.0.memberCount"; label = "Members"; format = "number"; }
          { field = "data.workspaces.0.docs.totalCount"; label = "Docs"; format = "number"; }
          { field = "data.workspaces.0.blobsSize"; label = "Storage"; format = "bytes"; }
        ];
      }; }
    { port = 443;   backend = "http://127.0.0.1:13334"; name = "Sure";           icon = "maybe.svg";          category = "Apps"; description = "Personal finance"; noSiteMonitor = true; proxied = true; path = "/sure";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/sure";
        mappings = [
          { field = "net_worth"; label = "Net Worth"; format = "number"; prefix = "€"; }
          { field = "accounts"; label = "Accounts"; format = "number"; }
          { field = "transactions"; label = "Transactions"; format = "number"; }
        ];
      }; }
    { port = 10000; backend = "http://127.0.0.1:2283";  name = "Immich";         icon = "immich.svg";         category = "Apps"; description = "Photo management"; funnel = true; noSiteMonitor = true;
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/immich";
        mappings = [
          { field = "photos"; label = "Photos"; format = "number"; }
          { field = "videos"; label = "Videos"; format = "number"; }
          { field = "usage";  label = "Storage"; format = "bytes"; }
        ];
      }; }
    # Socket-activated (idle-sleep) — noSiteMonitor so the homepage ping doesn't re-arm the idle timer.
    # Widget reads Papra's SQLite directly via homepage-stats.py (:8087/papra), not
    # Papra's HTTP API, so the daily poll never wakes the service (see homepage-stats.py).
    { port = 3450;  backend = "http://127.0.0.1:8220";  name = "Papra";          icon = "papra.svg";          category = "Apps"; description = "Document archive (bills, invoices)"; noSiteMonitor = true;
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/papra";
        mappings = [
          { field = "documents"; label = "Documents"; format = "number"; }
          { field = "tags"; label = "Tags"; format = "number"; }
          { field = "size"; label = "Storage"; format = "bytes"; }
        ];
      }; }
    # Open WebUI DISABLED 2026-06-15 (venv crash-loop, exit 126); re-enable alongside ./open-webui.nix in configuration.nix.
    # { port = 8181;  backend = "http://127.0.0.1:8181";  name = "Open WebUI";     icon = "open-webui.svg";     category = "Apps"; description = "LLM chat interface"; noSiteMonitor = true;
    #   widget = {
    #     type = "customapi";
    #     url = "http://127.0.0.1:8087/openwebui";
    #     mappings = [
    #       { field = "models"; label = "Models"; format = "number"; }
    #       { field = "chats"; label = "Chats"; format = "number"; }
    #       { field = "messages"; label = "Messages"; format = "number"; }
    #     ];
    #   }; }
    # Socket-activated (idle-sleep) — noSiteMonitor so the homepage ping doesn't re-arm the idle timer.
    { port = 3500;  backend = "http://127.0.0.1:8210";  name = "Karakeep";       icon = "karakeep.svg";       category = "Apps"; description = "Bookmarks + read-later (AI-tagged)"; noSiteMonitor = true;
      # Stats via homepage-stats.py reading karakeep's SQLite read-only (no API
      # key, never wakes karakeep → preserves idle-sleep). NOT the native
      # `type = "karakeep"` widget, which would poll the API and keep it awake.
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/karakeep";
        mappings = [
          { field = "bookmarks"; label = "Bookmarks"; format = "number"; }
          { field = "favorites"; label = "Favorites"; format = "number"; }
          { field = "archived";  label = "Archived";  format = "number"; }
          { field = "tags";      label = "Tags";      format = "number"; }
        ];
      }; }
    { port = 8123;  backend = "http://127.0.0.1:8123";  name = "Home Assistant"; icon = "home-assistant.svg"; category = "Apps"; description = "Home automation";
      # Routed through the homepage-stats aggregator (:8087, daily-cached) like the
      # other customapi tiles rather than the native `homeassistant` widget that
      # polls HA directly. Counts can be up to the aggregator's REFRESH_INTERVAL
      # (24h) stale — acceptable for a glanceable tile; the aggregator holds the
      # HA token, so no key is exposed here.
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/homeassistant";
        mappings = [
          { field = "people_home"; label = "Home";     format = "number"; }
          { field = "lights_on";   label = "Lights";   format = "number"; }
          { field = "switches_on"; label = "Switches"; format = "number"; }
        ];
      }; }
    { port = 3000;  backend = "http://127.0.0.1:8090";  name = "Beszel";         icon = "beszel.svg";         category = "Apps"; description = "System monitoring";
      widget = {
        type = "beszel";
        url = "http://127.0.0.1:8090";
        username = "homepage@nic-os.local";
        password = "homepage-widget-pass"; # superuser dedicated to homepage; same cred reused in monitoring.nix:213
        version = 2;
      }; }
    # Apps continued: Vaultwarden → Dawarich → AirTrail → Gramps Web → Forgejo → Wakapi → Reactive Resume
    # noSiteMonitor on socket-activated entries — see homepage.nix mkTile.
    # Vaultwarden/Dawarich/AirTrail/Forgejo/Wakapi have no native homepage widget,
    # so their widgets read the app's database directly via homepage-stats.py
    # (SQLite for Vaultwarden/Wakapi, Postgres-as-superuser for Dawarich/AirTrail/
    # Forgejo) rather than the app's HTTP API — daily polling never wakes the
    # socket-activated ones and needs no per-app API key or role password.
    # Gramps Web and Reactive Resume use the same direct-read approach for their
    # own reasons — see their individual comments below.
    { port = 8222;  backend = "http://127.0.0.1:8222";  name = "Vaultwarden";    icon = "vaultwarden.svg";    category = "Apps"; description = "Password manager"; noSiteMonitor = true;
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/vaultwarden";
        mappings = [
          { field = "items"; label = "Items"; format = "number"; }
          { field = "users"; label = "Users"; format = "number"; }
          { field = "devices"; label = "Devices"; format = "number"; }
        ];
      }; }
    { port = 3900;  backend = "http://127.0.0.1:13900"; name = "Dawarich";       icon = "dawarich.svg";       category = "Apps"; description = "Location history";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/dawarich";
        mappings = [
          { field = "points"; label = "Points"; format = "number"; }
          { field = "trips"; label = "Trips"; format = "number"; }
          { field = "visits"; label = "Visits"; format = "number"; }
        ];
      }; }
    # Socket-activated (idle-sleep) — noSiteMonitor so the homepage ping doesn't re-arm the idle timer.
    # icon: AirTrail isn't in dashboard-icons, so point at its favicon.svg via jsdelivr (pinned tag).
    { port = 3600;  backend = "http://127.0.0.1:8310";  name = "AirTrail";       icon = "https://cdn.jsdelivr.net/gh/johanohly/AirTrail@v3.11.1/static/favicon.svg"; category = "Apps"; description = "Personal flight tracker"; noSiteMonitor = true;
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/airtrail";
        mappings = [
          { field = "flights"; label = "Flights"; format = "number"; }
          { field = "countries"; label = "Countries"; format = "number"; }
          { field = "hours"; label = "Hours"; format = "number"; }
        ];
      }; }
    # Socket-activated (idle-sleep) — noSiteMonitor so the homepage ping doesn't re-arm the idle timer.
    # NOT behind the 443 path-mux: Gramps Web's SPA hardcodes absolute API paths and its
    # service worker needs root scope (gramps-web#531), so it keeps its own Tailscale Serve
    # port (5050 → socket-activate proxy :15050) — same call as AFFiNE on 8443.
    # Widget reads Gramps Web's per-tree SQLite directly (:8087/grampsweb, summed across
    # trees), so the daily poll never wakes the service.
    { port = 5050;  backend = "http://127.0.0.1:15050"; name = "Gramps Web";      icon = "gramps.svg";         category = "Apps"; description = "Genealogy"; noSiteMonitor = true;
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/grampsweb";
        mappings = [
          { field = "people"; label = "People"; format = "number"; }
          { field = "families"; label = "Families"; format = "number"; }
          { field = "events"; label = "Events"; format = "number"; }
        ];
      }; }
    { port = 3100;  backend = "http://127.0.0.1:3100";  name = "Forgejo";        icon = "forgejo.svg";        category = "Apps"; description = "Git hosting"; noSiteMonitor = true;
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/forgejo";
        mappings = [
          { field = "repositories"; label = "Repos"; format = "number"; }
          { field = "issues"; label = "Issues"; format = "number"; }
          { field = "pulls"; label = "PRs"; format = "number"; }
        ];
      }; }
    { port = 3030;  backend = "http://127.0.0.1:3030";  name = "Wakapi";         icon = "wakatime.svg";       category = "Apps"; description = "Coding stats (WakaTime-compatible)"; noSiteMonitor = true;
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/wakapi";
        mappings = [
          { field = "heartbeats"; label = "Heartbeats"; format = "number"; }
          { field = "languages"; label = "Languages"; format = "number"; }
          { field = "users"; label = "Users"; format = "number"; }
        ];
      }; }
    # Ryot proxy (Caddy) is the entrypoint; it path-muxes backend+frontend and
    # serves the SPA at root, so an own Serve port fits (no 443 path-mux needed).
    # Widget reads Ryot's Postgres directly via homepage-stats.py (:8087/ryot,
    # daily-cached, postgres superuser) — no API token on the tile.
    { port = 3700;  backend = "http://127.0.0.1:13350"; name = "Ryot";           icon = "ryot.svg";           category = "Apps"; description = "Media & life tracker";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/ryot";
        mappings = [
          { field = "media";   label = "Media";   format = "number"; }
          { field = "seen";    label = "Seen";    format = "number"; }
          { field = "reviews"; label = "Reviews"; format = "number"; }
        ];
      }; }
    # Socket-activated (idle-sleep) — noSiteMonitor so the ~5-min homepage ping doesn't keep waking it (see homepage.nix mkTile).
    # Fronted by the 443 nginx path-mux at /rxresume (prefix stripped); the SPA is built with Vite base=/rxresume/. proxied → no direct serve/funnel.
    # Widget queries Reactive Resume's Postgres directly (:8087/reactiveresume, scram auth
    # via agenix password) — Postgres isn't part of the socket-activated tier, so this
    # never wakes the Node service either.
    { port = 443;   backend = "http://127.0.0.1:13336"; name = "Reactive Resume"; icon = "reactive-resume.svg"; category = "Apps"; description = "Resume builder"; noSiteMonitor = true; proxied = true; path = "/rxresume";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/reactiveresume";
        mappings = [
          { field = "resumes"; label = "Resumes"; format = "number"; }
          { field = "users"; label = "Users"; format = "number"; }
          { field = "views"; label = "Views"; format = "number"; }
        ];
      }; }
    # Socket-activated (idle-sleep) — noSiteMonitor so the homepage ping doesn't re-arm the idle timer.
    # icon: BeaverHabits isn't in dashboard-icons, so point at its apple-touch-icon via jsdelivr (pinned tag).
    # Widget reads habits.db (JSON blob) directly via :8087/beaverhabits, so the daily poll never wakes it.
    # Kept last in Apps so the tile sits at the end of the group.
    { port = 3650;  backend = "http://127.0.0.1:8320";  name = "BeaverHabits";   icon = "https://cdn.jsdelivr.net/gh/daya0576/beaverhabits@v0.9.1/statics/images/apple-touch-icon.png"; category = "Apps"; description = "Habit tracker"; noSiteMonitor = true;
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/beaverhabits";
        mappings = [
          { field = "habits"; label = "Habits"; format = "number"; }
          { field = "done_today"; label = "Done today"; format = "number"; }
          { field = "checkins"; label = "Check-ins"; format = "number"; }
        ];
      }; }
    # Socket-activated (idle-sleep) — noSiteMonitor so the homepage ping doesn't re-arm the idle timer.
    # Own Serve port (not the 443 path-mux): Plane's React-Router SPAs (/, /spaces,
    # /god-mode) need a root origin, like AFFiNE / Gramps Web. 3800 → the always-on
    # nginx vhost (:8330) from nixosModules.plane, which lazy-wakes the api tier.
    # No widget yet — add a homepage-stats.py :8087/plane DB-reader (like the other
    # socket-activated tiles) so stats don't wake the service. eval-only for now.
    { port = 3800;  backend = "http://127.0.0.1:8330";  name = "Plane";          icon = "plane.svg";          category = "Apps"; description = "Project management (Jira/Linear alt)"; noSiteMonitor = true; }

    # Backend — API services
    # PicoClaw demoted from 443 to 8444 (tailnet-only) so AFFiNE can claim the
    # bare https://rpi5.gate-mintaka.ts.net URL via Tailscale Funnel.
    { port = 8444;  backend = "http://127.0.0.1:18789"; name = "PicoClaw";       icon = "mdi-robot";          category = "Backend"; description = "AI gateway"; }
    { port = 4001;  backend = "http://127.0.0.1:4001";  name = "tiny-llm-gate";  icon = "mdi-brain";          category = "Backend"; description = "LLM gateway (OpenAI + Gemini + Anthropic + native Codex)"; }
    # Codex Proxy (:4040) removed 2026-07-15 — codex is now served natively by
    # tiny-llm-gate; codex-proxy service + files deleted.
    # Not shown on dashboard — internal MCP gateway, not user-facing.
    { port = 7020;  backend = "http://127.0.0.1:4001/mcp/affine"; name = "AFFiNE MCP"; icon = "mdi-api";       category = "Infrastructure"; description = "AFFiNE MCP gateway (via tiny-llm-gate)"; }
    # Hydroxide moved 8443 → 8083 (matches its backend port) to free the 8443
    # Funnel slot (only 443/8443/10000 are funnel-eligible; 443 + 10000 are also
    # taken). 8443 now fronts AFFiNE at its root origin (see the AFFiNE entry).
    # Devices using https://rpi5.gate-mintaka.ts.net:8443/.well-known/carddav
    # must update to :8083.
    { port = 8083;  backend = "http://127.0.0.1:8083";  name = "Hydroxide";      icon = "mdi-email-outline";  category = "Backend";  description = "ProtonMail bridge (SMTP + CardDAV)"; }
    # Cyrus is fronted by the 443 nginx path-mux at /cyrus (prefix stripped). Its
    # public URL (CYRUS_BASE_URL in cyrus.nix) is https://…/cyrus, and its
    # hardcoded root routes (/callback, /linear-webhook, /github-webhook) sit
    # under it. AFFiNE took the freed 8443 Funnel slot (it needs a root origin).
    { port = 443;   backend = "http://127.0.0.1:3456";  name = "Cyrus";          icon = "mdi-robot-outline";  category = "Backend"; description = "Linear coding-agent (cyrusagents/cyrus)"; proxied = true; path = "/cyrus"; }

    # Infrastructure — not shown on dashboard
    # Single public 443 Funnel → nginx path-mux (front-proxy.nix), which routes
    # /nextcloud → Nextcloud and /cyrus → Cyrus (both `proxied = true` above).
    { port = 443;   backend = "http://127.0.0.1:8092";  name = "Front Proxy";    icon = "mdi-sitemap";        category = "Infrastructure"; description = "nginx 443 path-mux (/nextcloud, /cyrus, /sure, /rxresume)"; funnel = true; }
    { port = 8082;  backend = "http://127.0.0.1:8082";  name = "Homepage";       icon = "homepage.svg";       category = "Infrastructure"; description = "Service dashboard"; }
    { port = 8088;  backend = "http://127.0.0.1:8088";  name = "Claude Notify";  icon = "mdi-bell";           category = "Infrastructure"; description = "Debounced agent → Telegram aggregator"; noSiteMonitor = true; }
    # epicgames-freegames device/captcha portal. Only listens during a run (and
    # only when Epic demands an interactive solve), so noSiteMonitor. Tailnet-only
    # serve so the Telegram captcha link resolves from a phone; hidden tile.
    { port = 3750;  backend = "http://127.0.0.1:3211";  name = "Epic Free Games"; icon = "mdi-gift";           category = "Infrastructure"; description = "Auto-claim Epic weekly free games (Thu+Sun 12:30; captcha portal)"; noSiteMonitor = true; }
  ];
}
