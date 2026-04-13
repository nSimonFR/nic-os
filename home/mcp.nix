{ config, pkgs, ... }:
let
  secretsPath = config.age.secrets.mcp-secrets.path;
  jq = "${pkgs.jq}/bin/jq";

  generateScript = pkgs.writeShellScript "generate-mcp-config" ''
    SECRETS_FILE="$1"
    [ -f "$SECRETS_FILE" ] || SECRETS_FILE="/run/user/$(id -u)/agenix/mcp-secrets"
    if [ -f "$SECRETS_FILE" ]; then
      . "$SECRETS_FILE"
    else
      echo "Warning: MCP secrets not found, skipping MCP config generation" >&2
      exit 0
    fi

    MCP_JSON=$(${jq} -n \
      --arg gh_pat "''${GITHUB_PAT}" \
      --arg miro "''${MIRO_TOKEN}" \
      --arg dd_api "''${DD_API_KEY}" \
      --arg dd_app "''${DD_APP_KEY}" \
      --arg affine "''${AFFINE_TOKEN}" \
      '{
        mcpServers: {
          Linear: { url: "https://mcp.linear.app/sse" },
          GitHub: {
            command: "docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server",
            env: { GITHUB_PERSONAL_ACCESS_TOKEN: $gh_pat }
          },
          Miro: {
            command: "npx",
            args: ["-y", "@k-jarzyna/mcp-miro"],
            env: { MIRO_ACCESS_TOKEN: $miro }
          },
          datadog: {
            command: "npx",
            args: ["-y", "datadog-mcp"],
            env: { DD_API_KEY: $dd_api, DD_APP_KEY: $dd_app, DD_SITE: "datadoghq.com" }
          },
          "affine_workspace_35d244cd-e6d5-4b3d-b1c2-fa50cab50621": {
            type: "streamable-http",
            url: "https://rpi5.gate-mintaka.ts.net:3010/api/workspaces/35d244cd-e6d5-4b3d-b1c2-fa50cab50621/mcp",
            note: "Read docs from AFFiNE workspace \"Nico\"",
            headers: { Authorization: ("Bearer " + $affine) }
          },
          "trusk-k8s":       { type: "http", url: "http://gateway-mcp.dev-tools.svc.cluster.local:8080/mcp" },
          "trusk-argocd":    { type: "http", url: "http://gateway-mcp.dev-tools.svc.cluster.local:3000/mcp" },
          "trusk-grafana":   { type: "http", url: "http://gateway-mcp.dev-tools.svc.cluster.local:8000/mcp" },
          "trusk-datadog":   { type: "http", url: "http://gateway-mcp.dev-tools.svc.cluster.local:9000/mcp" },
          "trusk-github":    { type: "sse",  url: "http://supergateway-mcp.dev-tools.svc.cluster.local:7001/sse" },
          "trusk-context7":  { type: "sse",  url: "http://supergateway-mcp.dev-tools.svc.cluster.local:7002/sse" },
          "trusk-steampipe": { type: "sse",  url: "http://steampipe-mcp-server.dev-tools.svc.cluster.local:9194/sse" },
          "trusk-searxncrawl": { type: "sse", url: "http://searxncrawl-mcp.dev-tools.svc.cluster.local:7010/sse" }
        }
      }')

    # Write Cursor MCP config
    mkdir -p "$HOME/.cursor"
    echo "$MCP_JSON" > "$HOME/.cursor/mcp.json"

    # Merge MCP servers into Claude settings.json
    CLAUDE_SETTINGS="$HOME/.claude/settings.json"
    if [ -f "$CLAUDE_SETTINGS" ] || [ -L "$CLAUDE_SETTINGS" ]; then
      EXISTING=$(cat "$CLAUDE_SETTINGS")
      MERGED=$(echo "$EXISTING" | ${jq} \
        --argjson mcp "$(echo "$MCP_JSON" | ${jq} '.mcpServers')" \
        '. + {mcpServers: $mcp}')
      rm -f "$CLAUDE_SETTINGS"
      echo "$MERGED" > "$CLAUDE_SETTINGS"
    fi
  '';
in
{
  home.activation.mcp-config = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    run ${generateScript} "${secretsPath}"
  '';
}
