{ config, pkgs, ... }:
let
  secretsPath = config.age.secrets.mcp-secrets.path;
  jq = "${pkgs.jq}/bin/jq";

  # Wrapper scripts: read secrets from agenix at runtime, then exec the MCP server
  githubMcp = pkgs.writeShellScript "github-mcp" ''
    [ -f "${secretsPath}" ] && . "${secretsPath}"
    export GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_PAT"
    exec docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server
  '';

  miroMcp = pkgs.writeShellScript "miro-mcp" ''
    [ -f "${secretsPath}" ] && . "${secretsPath}"
    export MIRO_ACCESS_TOKEN="$MIRO_TOKEN"
    exec npx -y @k-jarzyna/mcp-miro
  '';

  datadogLocalMcp = pkgs.writeShellScript "datadog-local-mcp" ''
    [ -f "${secretsPath}" ] && . "${secretsPath}"
    export DD_API_KEY DD_APP_KEY DD_SITE="datadoghq.com"
    exec npx -y datadog-mcp
  '';

  affineMcp = pkgs.writeShellScript "affine-mcp" ''
    [ -f "${secretsPath}" ] && . "${secretsPath}"
    exec npx -y supergateway \
      --streamableHttp "https://rpi5.gate-mintaka.ts.net:3010/api/workspaces/35d244cd-e6d5-4b3d-b1c2-fa50cab50621/mcp" \
      --oauth2Bearer "$AFFINE_TOKEN"
  '';

  # Shared MCP server definitions (no plaintext secrets)
  mcpServers = {
    # Public — no secrets
    Linear              = { type = "sse"; url = "https://mcp.linear.app/sse"; };
    "trusk-k8s"         = { type = "http"; url = "http://gateway-mcp.dev-tools.svc.cluster.local:8080/mcp"; };
    "trusk-argocd"      = { type = "http"; url = "http://gateway-mcp.dev-tools.svc.cluster.local:3000/mcp"; };
    "trusk-grafana"     = { type = "http"; url = "http://gateway-mcp.dev-tools.svc.cluster.local:8000/mcp"; };
    "trusk-datadog"     = { type = "http"; url = "http://gateway-mcp.dev-tools.svc.cluster.local:9000/mcp"; };
    "trusk-github"      = { type = "sse";  url = "http://supergateway-mcp.dev-tools.svc.cluster.local:7001/sse"; };
    "trusk-context7"    = { type = "sse";  url = "http://supergateway-mcp.dev-tools.svc.cluster.local:7002/sse"; };
    "trusk-steampipe"   = { type = "sse";  url = "http://steampipe-mcp-server.dev-tools.svc.cluster.local:9194/sse"; };
    "trusk-searxncrawl" = { type = "sse";  url = "http://searxncrawl-mcp.dev-tools.svc.cluster.local:7010/sse"; };

    # Private — secrets loaded at runtime via wrapper scripts
    GitHub  = { command = "${githubMcp}"; };
    Miro    = { command = "${miroMcp}"; };
    datadog = { command = "${datadogLocalMcp}"; };
    affine  = { command = "${affineMcp}"; };
  };

  # Pre-built JSON for Cursor (Nix-generated, no secrets in the file)
  cursorMcpBase = pkgs.writeText "cursor-mcp-base.json"
    (builtins.toJSON { inherit mcpServers; });
in
{
  # Claude Code: declarative MCP via home-manager plugin mechanism
  programs.claude-code.mcpServers = mcpServers;

  # Cursor: write ~/.cursor/mcp.json as a real file (Cursor can't follow symlinks),
  # injecting AFFiNE's auth header from agenix at activation time
  home.activation.cursor-mcp = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    MCP=$(cat ${cursorMcpBase})

    SECRETS_FILE="${secretsPath}"
    if [ -f "$SECRETS_FILE" ]; then
      . "$SECRETS_FILE"
      AFFINE=$(${jq} -n --arg token "$AFFINE_TOKEN" '{
        "affine_workspace_35d244cd-e6d5-4b3d-b1c2-fa50cab50621": {
          type: "streamable-http",
          url: "https://rpi5.gate-mintaka.ts.net:3010/api/workspaces/35d244cd-e6d5-4b3d-b1c2-fa50cab50621/mcp",
          note: "Read docs from AFFiNE workspace \"Nico\"",
          headers: { Authorization: ("Bearer " + $token) }
        }
      }')
      MCP=$(echo "$MCP" | ${jq} --argjson a "$AFFINE" '.mcpServers += $a')

      # Also inject AFFiNE into Claude's user-level config (~/.claude.json)
      CLAUDE_USER="$HOME/.claude.json"
      if [ -f "$CLAUDE_USER" ]; then
        ${jq} --argjson a "$AFFINE" '.mcpServers += $a' "$CLAUDE_USER" > "$CLAUDE_USER.tmp" \
          && mv "$CLAUDE_USER.tmp" "$CLAUDE_USER"
      else
        ${jq} -n --argjson a "$AFFINE" '{mcpServers: $a}' > "$CLAUDE_USER"
      fi
    fi

    mkdir -p "$HOME/.cursor"
    echo "$MCP" > "$HOME/.cursor/mcp.json"
  '';
}
