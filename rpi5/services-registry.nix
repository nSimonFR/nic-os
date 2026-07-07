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
    # Apps: Nextcloud → AFFiNE → Sure → Immich → Open WebUI → Paperless → Karakeep → Home Assistant
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
    { port = 3333;  backend = "http://127.0.0.1:13334"; name = "Sure";           icon = "maybe.svg";          category = "Apps"; description = "Personal finance"; noSiteMonitor = true;
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
    { port = 3400;  backend = "http://127.0.0.1:8200";  name = "Paperless";      icon = "paperless-ngx.svg";  category = "Apps"; description = "Document archive (bills, invoices)"; noSiteMonitor = true;
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/paperless";
        mappings = [
          { field = "total"; label = "Total"; format = "number"; }
          { field = "inbox"; label = "Inbox"; format = "number"; }
        ];
      }; }
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
      widget = {
        type = "homeassistant";
        url = "http://127.0.0.1:8123";
        key = "{{HOMEPAGE_VAR_HA_TOKEN}}";
      }; }
    { port = 3000;  backend = "http://127.0.0.1:8090";  name = "Beszel";         icon = "beszel.svg";         category = "Apps"; description = "System monitoring";
      widget = {
        type = "beszel";
        url = "http://127.0.0.1:8090";
        username = "homepage@nic-os.local";
        password = "homepage-widget-pass"; # superuser dedicated to homepage; same cred reused in monitoring.nix:213
        version = 2;
      }; }

    # Services: Vaultwarden → Dawarich → Forgejo → Wakapi
    # noSiteMonitor on socket-activated entries — see homepage.nix mkTile.
    { port = 8222;  backend = "http://127.0.0.1:8222";  name = "Vaultwarden";    icon = "vaultwarden.svg";    category = "Services"; description = "Password manager"; noSiteMonitor = true; }
    { port = 3900;  backend = "http://127.0.0.1:13900"; name = "Dawarich";       icon = "dawarich.svg";       category = "Services"; description = "Location history"; }
    { port = 3100;  backend = "http://127.0.0.1:3100";  name = "Forgejo";        icon = "forgejo.svg";        category = "Services"; description = "Git hosting"; noSiteMonitor = true; }
    { port = 3030;  backend = "http://127.0.0.1:3030";  name = "Wakapi";         icon = "wakatime.svg";       category = "Services"; description = "Coding stats (WakaTime-compatible)"; noSiteMonitor = true; }

    # Backend — API services
    # PicoClaw demoted from 443 to 8444 (tailnet-only) so AFFiNE can claim the
    # bare https://rpi5.gate-mintaka.ts.net URL via Tailscale Funnel.
    { port = 8444;  backend = "http://127.0.0.1:18789"; name = "PicoClaw";       icon = "mdi-robot";          category = "Backend"; description = "AI gateway"; }
    { port = 4001;  backend = "http://127.0.0.1:4001";  name = "tiny-llm-gate";  icon = "mdi-brain";          category = "Backend"; description = "LLM gateway (OpenAI + Gemini)"; }
    { port = 4040;  backend = "http://127.0.0.1:4040";  name = "Codex Proxy";    icon = "mdi-code-braces";    category = "Backend"; description = "ChatGPT OAuth proxy (token counts + tool_calls)"; }
    { port = 7020;  backend = "http://127.0.0.1:4001/mcp/affine"; name = "AFFiNE MCP"; icon = "mdi-api";       category = "Backend"; description = "AFFiNE MCP gateway (via tiny-llm-gate)"; }
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
    { port = 443;   backend = "http://127.0.0.1:8092";  name = "Front Proxy";    icon = "mdi-sitemap";        category = "Infrastructure"; description = "nginx 443 path-mux (/nextcloud, /cyrus)"; funnel = true; }
    { port = 8082;  backend = "http://127.0.0.1:8082";  name = "Homepage";       icon = "homepage.svg";       category = "Infrastructure"; description = "Service dashboard"; }
    { port = 8088;  backend = "http://127.0.0.1:8088";  name = "Claude Notify";  icon = "mdi-bell";           category = "Infrastructure"; description = "Debounced agent → Telegram aggregator"; noSiteMonitor = true; }
  ];
}
