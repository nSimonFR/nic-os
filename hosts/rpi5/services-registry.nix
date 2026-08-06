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
# Widget: optional homepage widget config. Every tile is a `customapi` widget
# pointed at the homepage-stats aggregator on :8087 (nicos_scripts/homepage/stats.py),
# which fetches once a day and holds whatever API key or DB path the service needs.
# Three stats per tile, so no tile is taller than its neighbours.
{ }:
let
  # homepage's customapi widget defaults to refreshInterval = 10000 — every tile
  # would re-poll the aggregator every 10 seconds for a figure that only changes
  # once a day. Pin an hourly refresh instead: still comfortably fresher than the
  # aggregator's own daily cadence, and an open dashboard tab stops generating
  # ~8600 requests a day per tile.
  widgetRefresh = 3600000; # ms — 1 hour
in
{
  entries = [
    # Apps: Nextcloud → AFFiNE → Sure → Immich → Papra → Open WebUI → Karakeep → Home Assistant → Beszel
    { port = 443;   backend = "http://127.0.0.1:8091";  name = "Nextcloud";      icon = "nextcloud.svg";      category = "Apps"; description = "Files + Contacts + Calendar (DAV)"; proxied = true; path = "/nextcloud";
      # Was the native `nextcloud` widget, which always renders four stats
      # (freespace/activeusers/numfiles/numshares) and re-authenticates against
      # serverinfo on every page load. The aggregator holds the NC-Token instead.
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/nextcloud";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "users";  label = "Active users"; format = "number"; }
          { field = "files";  label = "Files";        format = "number"; }
          { field = "shares"; label = "Shares";       format = "number"; }
        ];
      }; }
    { port = 8443; backend = "http://127.0.0.1:13010"; name = "AFFiNE";         icon = "affine.svg";         category = "Apps"; description = "Collaborative docs"; funnel = true;
      # Was a customapi POSTing GraphQL straight at AFFiNE every 10s, and it read
      # workspaces[0] — the 3-doc scratch workspace, not the main one. The
      # aggregator sums all four workspaces and asks once a day.
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/affine";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "workspaces"; label = "Workspaces"; format = "number"; }
          { field = "docs";       label = "Docs";       format = "number"; }
          { field = "storage";    label = "Storage";    format = "bytes"; }
        ];
      }; }
    { port = 443;   backend = "http://127.0.0.1:13334"; name = "Sure";           icon = "maybe.svg";          category = "Apps"; description = "Personal finance"; proxied = true; path = "/sure";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/sure";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "net_worth"; label = "Net Worth"; format = "number"; prefix = "€"; }
          { field = "accounts"; label = "Accounts"; format = "number"; }
          { field = "transactions"; label = "Transactions"; format = "number"; }
        ];
      }; }
    { port = 10000; backend = "http://127.0.0.1:2283";  name = "Immich";         icon = "immich.svg";         category = "Apps"; description = "Photo management"; funnel = true;
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/immich";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "photos"; label = "Photos"; format = "number"; }
          { field = "videos"; label = "Videos"; format = "number"; }
          { field = "usage";  label = "Storage"; format = "bytes"; }
        ];
      }; }
    # Widget reads Papra's SQLite directly via homepage-stats.py (:8087/papra), not
    # Papra's HTTP API, so the daily poll never wakes the socket-activated service.
    { port = 3450;  backend = "http://127.0.0.1:8220";  name = "Papra";          icon = "papra.svg";          category = "Apps"; description = "Document archive (bills, invoices)";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/papra";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "documents"; label = "Documents"; format = "number"; }
          { field = "tags"; label = "Tags"; format = "number"; }
          { field = "size"; label = "Storage"; format = "bytes"; }
        ];
      }; }
    # Open WebUI DISABLED 2026-06-15 (venv crash-loop, exit 126); re-enable alongside ./open-webui.nix in configuration.nix.
    # { port = 8181;  backend = "http://127.0.0.1:8181";  name = "Open WebUI";     icon = "open-webui.svg";     category = "Apps"; description = "LLM chat interface";
    #   widget = {
    #     type = "customapi";
    #     url = "http://127.0.0.1:8087/openwebui";
    #     refreshInterval = widgetRefresh;
    #     mappings = [
    #       { field = "models"; label = "Models"; format = "number"; }
    #       { field = "chats"; label = "Chats"; format = "number"; }
    #       { field = "messages"; label = "Messages"; format = "number"; }
    #     ];
    #   }; }
    { port = 3500;  backend = "http://127.0.0.1:8210";  name = "Karakeep";       icon = "karakeep.svg";       category = "Apps"; description = "Bookmarks + read-later (AI-tagged)";
      # Stats via homepage-stats.py reading karakeep's SQLite read-only (no API
      # key, never wakes karakeep → preserves idle-sleep). NOT the native
      # `karakeep` widget, which would poll the API and keep it awake.
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/karakeep";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "bookmarks"; label = "Bookmarks"; format = "number"; }
          { field = "favorites"; label = "Favorites"; format = "number"; }
          { field = "tags";      label = "Tags";      format = "number"; }
        ];
      }; }
    { port = 8123;  backend = "http://127.0.0.1:8123";  name = "Home Assistant"; icon = "home-assistant.svg"; category = "Apps"; description = "Home automation";
      # Deep-link the tile straight to the "Mine" Lovelace dashboard
      # (url_path "mine-dashboard" in home-assistant.nix) instead of HA's root.
      path = "/mine-dashboard/";
      # Routed through the homepage-stats aggregator (:8087, daily-cached) like the
      # other tiles rather than the native `homeassistant` widget that polls HA
      # every 60s. Counts can be up to the aggregator's REFRESH_INTERVAL (24h)
      # stale — acceptable for a glanceable tile; the aggregator holds the HA
      # token, so no key is exposed here.
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/homeassistant";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "people_home"; label = "Home";     format = "number"; }
          { field = "lights_on";   label = "Lights";   format = "number"; }
          { field = "switches_on"; label = "Switches"; format = "number"; }
        ];
      }; }
    { port = 3000;  backend = "http://127.0.0.1:8090";  name = "Beszel";         icon = "beszel.svg";         category = "Apps"; description = "System monitoring";
      # Was the native `beszel` widget, which needed a Beszel superuser password
      # in plaintext here (and could only render two stats without pinning the
      # tile to one systemId). The aggregator reads Beszel's PocketBase SQLite
      # read-only instead — the homepage@nic-os.local superuser created in
      # monitoring.nix is no longer used by this tile.
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/beszel";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "systems"; label = "Systems"; format = "number"; }
          { field = "up";      label = "Up";      format = "number"; }
          { field = "alerts";  label = "Alerts";  format = "number"; }
        ];
      }; }
    # Apps continued: Vaultwarden → Dawarich → AirTrail → Gramps Web → Forgejo → Wakapi → Reactive Resume
    # Vaultwarden/Dawarich/AirTrail/Forgejo/Wakapi have no native homepage widget,
    # so their widgets read the app's database directly via homepage-stats.py
    # (SQLite for Vaultwarden/Wakapi, Postgres-as-superuser for Dawarich/AirTrail/
    # Forgejo) rather than the app's HTTP API — daily polling never wakes the
    # socket-activated ones and needs no per-app API key or role password.
    # Gramps Web and Reactive Resume use the same direct-read approach for their
    # own reasons — see their individual comments below.
    { port = 8222;  backend = "http://127.0.0.1:8222";  name = "Vaultwarden";    icon = "vaultwarden.svg";    category = "Apps"; description = "Password manager";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/vaultwarden";
        refreshInterval = widgetRefresh;
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
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "points"; label = "Points"; format = "number"; }
          { field = "trips"; label = "Trips"; format = "number"; }
          { field = "visits"; label = "Visits"; format = "number"; }
        ];
      }; }
    # icon: AirTrail isn't in dashboard-icons, so point at its favicon.svg via jsdelivr (pinned tag).
    { port = 3600;  backend = "http://127.0.0.1:8310";  name = "AirTrail";       icon = "https://cdn.jsdelivr.net/gh/johanohly/AirTrail@v3.11.1/static/favicon.svg"; category = "Apps"; description = "Personal flight tracker";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/airtrail";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "flights"; label = "Flights"; format = "number"; }
          { field = "countries"; label = "Countries"; format = "number"; }
          { field = "hours"; label = "Hours"; format = "number"; }
        ];
      }; }
    # NOT behind the 443 path-mux: Gramps Web's SPA hardcodes absolute API paths and its
    # service worker needs root scope (gramps-web#531), so it keeps its own Tailscale Serve
    # port (5050 → socket-activate proxy :15050) — same call as AFFiNE on 8443.
    # Widget reads Gramps Web's per-tree SQLite directly (:8087/grampsweb, summed across
    # trees), so the daily poll never wakes the service.
    { port = 5050;  backend = "http://127.0.0.1:15050"; name = "Gramps Web";      icon = "gramps.svg";         category = "Apps"; description = "Genealogy";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/grampsweb";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "people"; label = "People"; format = "number"; }
          { field = "families"; label = "Families"; format = "number"; }
          { field = "events"; label = "Events"; format = "number"; }
        ];
      }; }
    { port = 3100;  backend = "http://127.0.0.1:3100";  name = "Forgejo";        icon = "forgejo.svg";        category = "Apps"; description = "Git hosting";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/forgejo";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "repositories"; label = "Repos"; format = "number"; }
          { field = "issues"; label = "Issues"; format = "number"; }
          { field = "pulls"; label = "PRs"; format = "number"; }
        ];
      }; }
    { port = 3030;  backend = "http://127.0.0.1:3030";  name = "Wakapi";         icon = "wakatime.svg";       category = "Apps"; description = "Coding stats (WakaTime-compatible)";
      # Coding hours, from wakapi's own `durations` table — heartbeat/language/user
      # row counts said nothing about how much was actually coded.
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/wakapi";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "today";    label = "Today";    format = "float"; suffix = "h"; }
          { field = "last_30d"; label = "30 days";  format = "float"; suffix = "h"; }
          { field = "total";    label = "All time"; format = "float"; suffix = "h"; }
        ];
      }; }
    # Ryot's SPA is built with a /ryot/ base (ryot-nix) and its Caddy entrypoint is
    # re-rooted to mux under /ryot, so it's fronted by the 443 nginx path-mux at
    # /ryot (see front-proxy.nix / ryot.nix) — this also makes the Plex webhook
    # (…/ryot/_i/<id>) publicly reachable. proxied → no direct serve/funnel.
    # Widget reads Ryot's Postgres directly via homepage-stats.py (:8087/ryot,
    # daily-cached, postgres superuser) — no API token on the tile. "Hours"
    # excludes video-game playtime; see RYOT_MEDIA_HOURS_SQL for why.
    { port = 443;   backend = "http://127.0.0.1:13350"; name = "Ryot";           icon = "ryot.svg";           category = "Apps"; description = "Media & life tracker"; proxied = true; path = "/ryot";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/ryot";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "seen";     label = "Media seen"; format = "number"; }
          { field = "hours";    label = "Hours seen"; format = "number"; suffix = "h"; }
          { field = "workouts"; label = "Workouts";   format = "number"; }
        ];
      }; }
    # Fronted by the 443 nginx path-mux at /rxresume (prefix stripped); the SPA is built with Vite base=/rxresume/. proxied → no direct serve/funnel.
    # Widget queries Reactive Resume's Postgres directly (:8087/reactiveresume, scram auth
    # via agenix password) — Postgres isn't part of the socket-activated tier, so this
    # never wakes the Node service either.
    { port = 443;   backend = "http://127.0.0.1:13336"; name = "Reactive Resume"; icon = "reactive-resume.svg"; category = "Apps"; description = "Resume builder"; proxied = true; path = "/rxresume";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/reactiveresume";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "resumes"; label = "Resumes"; format = "number"; }
          { field = "users"; label = "Users"; format = "number"; }
          { field = "views"; label = "Views"; format = "number"; }
        ];
      }; }
    # icon: BeaverHabits isn't in dashboard-icons, so point at its apple-touch-icon via jsdelivr (pinned tag).
    # Widget reads habits.db (JSON blob) directly via :8087/beaverhabits, so the daily poll never wakes it.
    # Kept last in Apps so the tile sits at the end of the group.
    { port = 3650;  backend = "http://127.0.0.1:8320";  name = "BeaverHabits";   icon = "https://cdn.jsdelivr.net/gh/daya0576/beaverhabits@v0.9.1/statics/images/apple-touch-icon.png"; category = "Apps"; description = "Habit tracker";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/beaverhabits";
        refreshInterval = widgetRefresh;
        mappings = [
          { field = "habits"; label = "Habits"; format = "number"; }
          { field = "done_today"; label = "Done today"; format = "number"; }
          { field = "checkins"; label = "Check-ins"; format = "number"; }
        ];
      }; }
    # Backend (Go API) is localhost-only; only the SvelteKit frontend is served.
    # Widget reads ShowMyCards' SQLite directly via homepage-stats.py
    # (:8087/showmycards) rather than its HTTP API: :8330 is the only thing that wakes
    # the service, so an API-backed widget would pin it awake permanently.
    # backend is :8331 (nginx read-only guard), NOT :8330 (the socket-activate proxy):
    # Moxfield is the single writer, so an edit made here would be reverted by the next
    # daily sync. moxfield-sync itself still writes via :8330, which the tailnet cannot
    # reach — see the read-only guard in hosts/rpi5/showmycards.nix.
    { port = 3550;  backend = "http://127.0.0.1:8331";  name = "ShowMyCards";    icon = "mdi-cards-playing-outline"; category = "Apps"; description = "Magic: The Gathering collection";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/showmycards";
        refreshInterval = widgetRefresh;
        # "value" is EUR, computed foil-aware from the Scryfall prices in the local
        # catalogue (which self-updates daily at 03:00) — NOT ShowMyCards' own
        # total_collection_value, which is a different currency or blend and could
        # not be reproduced.
        mappings = [
          { field = "cards"; label = "Cards"; format = "number"; }
          { field = "decks"; label = "Decks"; format = "number"; }
          { field = "value"; label = "Value"; format = "float"; prefix = "€"; }
        ];
      }; }

    # Backend — API services
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
    { port = 8088;  backend = "http://127.0.0.1:8088";  name = "Claude Notify";  icon = "mdi-bell";           category = "Infrastructure"; description = "Debounced agent → Telegram aggregator"; }
    # epicgames-freegames device/captcha portal. Only listens during a run (and
    # only when Epic demands an interactive solve). Tailnet-only serve so the
    # Telegram captcha link resolves from a phone; hidden tile.
    { port = 3750;  backend = "http://127.0.0.1:3211";  name = "Epic Free Games"; icon = "mdi-gift";           category = "Infrastructure"; description = "Auto-claim Epic weekly free games (Thu+Sun 12:30; captcha portal)"; }
  ];
}
