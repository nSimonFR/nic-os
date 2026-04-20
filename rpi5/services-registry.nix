# Single source of truth for all services exposed via Tailscale Serve/Funnel.
# Consumed by tailscale-serve.nix (port routing) and homepage.nix (dashboard tiles).
#
# Icon formats:
#   "name.svg" / "name.png"  → dashboard-icons (walkxcode CDN)
#   "mdi-name"               → Material Design Icons (no extension)
#   "si-name"                → Simple Icons (no extension)
#
# Widget: optional homepage widget config (type + extra fields).
#   Secrets use {{HOMEPAGE_VAR_NAME}} syntax resolved from environmentFile.
{ voiceWebhookPort }:
{
  # Tailnet-only HTTPS services (tailscale serve).
  serveEntries = [
    # Services: Vaultwarden → Home Assistant → Filebrowser → Forgejo
    { port = 8222;  backend = "http://127.0.0.1:8222";  name = "Vaultwarden";    icon = "vaultwarden.svg";    category = "Services"; description = "Password manager"; }
    { port = 8123;  backend = "http://127.0.0.1:8123";  name = "Home Assistant"; icon = "home-assistant.svg"; category = "Services"; description = "Home automation"; }
    { port = 8085;  backend = "http://127.0.0.1:8085";  name = "Filebrowser";    icon = "filebrowser.svg";    category = "Services"; description = "File management"; }
    { port = 3100;  backend = "http://127.0.0.1:3100";  name = "Forgejo";        icon = "forgejo.svg";        category = "Services"; description = "Git hosting"; }
    { port = 3900;  backend = "http://127.0.0.1:13900"; name = "Dawarich";       icon = "dawarich.svg";       category = "Services"; description = "Location history"; }

    # Apps: AFFiNE → Immich (in funnelEntries) → Sure → Open WebUI
    { port = 3010;  backend = "http://127.0.0.1:13010"; name = "AFFiNE";         icon = "affine.svg";         category = "Apps"; description = "Collaborative docs";
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
    { port = 3333;  backend = "http://127.0.0.1:13334"; name = "Sure";           icon = "maybe.svg";          category = "Apps"; description = "Personal finance";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/sure";
        mappings = [
          { field = "net_worth"; label = "Net Worth"; format = "number"; prefix = "€"; }
          { field = "accounts"; label = "Accounts"; format = "number"; }
          { field = "transactions"; label = "Transactions"; format = "number"; }
        ];
      }; }
    { port = 8181;  backend = "http://127.0.0.1:8181";  name = "Open WebUI";     icon = "open-webui.svg";     category = "Apps"; description = "LLM chat interface";
      widget = {
        type = "customapi";
        url = "http://127.0.0.1:8087/openwebui";
        mappings = [
          { field = "models"; label = "Models"; format = "number"; }
          { field = "chats"; label = "Chats"; format = "number"; }
          { field = "messages"; label = "Messages"; format = "number"; }
        ];
      }; }

    # Monitoring
    { port = 3000;  backend = "http://127.0.0.1:8090";  name = "Beszel";         icon = "beszel.svg";         category = "Monitoring"; description = "System monitoring";
      widget = { type = "beszel"; url = "http://127.0.0.1:8090"; username = "homepage@nic-os.local"; password = "{{HOMEPAGE_VAR_BESZEL_PASS}}"; version = 2; }; }

    # Backend — API services
    { port = 443;   backend = "http://127.0.0.1:18789"; name = "Openclaw";       icon = "mdi-robot";          category = "Backend"; description = "AI gateway"; }
    { port = 4001;  backend = "http://127.0.0.1:4001";  name = "LiteLLM";        icon = "mdi-brain";          category = "Backend"; description = "LLM gateway"; }
    { port = 4040;  backend = "http://127.0.0.1:4040";  name = "Codex Proxy";    icon = "mdi-code-braces";    category = "Backend"; description = "OpenAI codex proxy"; }
    { port = 7020;  backend = "http://127.0.0.1:17020"; name = "AFFiNE MCP";     icon = "mdi-api";            category = "Backend"; description = "AFFiNE MCP gateway"; }

    # Infrastructure — not shown on dashboard
    { port = 8082;  backend = "http://127.0.0.1:8082";  name = "Homepage";       icon = "homepage.svg";       category = "Infrastructure"; description = "Service dashboard"; }
  ];

  # Publicly-accessible services (tailscale funnel).
  funnelEntries = [
    { port = voiceWebhookPort; backend = "http://127.0.0.1:${toString voiceWebhookPort}"; name = "Voice Webhook"; icon = "mdi-phone"; category = "Backend";  description = "Twilio inbound"; }
    { port = 10000;            backend = "http://127.0.0.1:2283";                          name = "Immich";        icon = "immich.svg"; category = "Apps";    description = "Photo management";
      widget = { type = "immich"; url = "http://127.0.0.1:2283"; key = "{{HOMEPAGE_VAR_IMMICH_KEY}}"; version = 2; }; }
  ];
}
