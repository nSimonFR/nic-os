# Single source of truth for all services exposed via Tailscale Serve/Funnel.
# Consumed by tailscale-serve.nix (port routing) and homepage.nix (dashboard tiles).
{ voiceWebhookPort }:
{
  # Tailnet-only HTTPS services (tailscale serve).
  serveEntries = [
    # Services — self-hosted apps
    { port = 8123;  backend = "http://127.0.0.1:8123";  name = "Home Assistant"; icon = "home-assistant";    category = "Services"; description = "Home automation"; }
    { port = 8181;  backend = "http://127.0.0.1:8181";  name = "Open WebUI";     icon = "open-webui";        category = "Services"; description = "LLM chat interface"; }
    { port = 3010;  backend = "http://127.0.0.1:13010"; name = "AFFiNE";         icon = "mdi-note-text";     category = "Services"; description = "Collaborative docs"; }
    { port = 3100;  backend = "http://127.0.0.1:3100";  name = "Forgejo";        icon = "forgejo";           category = "Services"; description = "Git hosting"; }
    { port = 3333;  backend = "http://127.0.0.1:13334"; name = "Sure";           icon = "mdi-cash-multiple"; category = "Services"; description = "Personal finance"; }
    { port = 8222;  backend = "http://127.0.0.1:8222";  name = "Vaultwarden";    icon = "vaultwarden";       category = "Services"; description = "Password manager"; }
    { port = 8085;  backend = "http://127.0.0.1:8085";  name = "Filebrowser";    icon = "filebrowser";       category = "Services"; description = "File management"; }

    # Monitoring
    { port = 3000;  backend = "http://127.0.0.1:8090";  name = "Beszel";         icon = "beszel";            category = "Monitoring"; description = "System monitoring"; }
    { port = 9099;  backend = "http://127.0.0.1:9099";  name = "Scrutiny";       icon = "scrutiny";          category = "Monitoring"; description = "Disk SMART health"; }

    # Backend — API services
    { port = 443;   backend = "http://127.0.0.1:18789"; name = "Openclaw";       icon = "mdi-robot";         category = "Backend"; description = "AI gateway"; }
    { port = 4001;  backend = "http://127.0.0.1:4001";  name = "LiteLLM";        icon = "mdi-brain";         category = "Backend"; description = "LLM gateway"; }
    { port = 4040;  backend = "http://127.0.0.1:4040";  name = "Codex Proxy";    icon = "mdi-code-braces";   category = "Backend"; description = "OpenAI codex proxy"; }
    { port = 7020;  backend = "http://127.0.0.1:17020"; name = "AFFiNE MCP";     icon = "mdi-api";           category = "Backend"; description = "AFFiNE MCP gateway"; }

    # Infrastructure — not shown on dashboard
    { port = 8082;  backend = "http://127.0.0.1:8082";  name = "Homepage";       icon = "homepage";          category = "Infrastructure"; description = "Service dashboard"; }
  ];

  # Publicly-accessible services (tailscale funnel).
  funnelEntries = [
    { port = voiceWebhookPort; backend = "http://127.0.0.1:${toString voiceWebhookPort}"; name = "Voice Webhook"; icon = "mdi-phone"; category = "Backend"; description = "Twilio inbound"; }
    { port = 10000;            backend = "http://127.0.0.1:2283";                          name = "Immich";        icon = "immich";    category = "Services"; description = "Photo management"; }
  ];
}
