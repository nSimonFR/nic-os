{ config, pkgs, tailnetFqdn, ... }:
let
  secretsPath = config.age.secrets.mcp-secrets.path;

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

  affineMcp = pkgs.writeShellScript "affine-mcp" ''
    [ -f "${secretsPath}" ] && . "${secretsPath}"
    export AFFINE_BASE_URL="https://${tailnetFqdn}:3010"
    export AFFINE_EMAIL AFFINE_PASSWORD
    exec npx -y affine-mcp-server
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
    affine  = { command = "${affineMcp}"; };
  };

  # Pre-built JSON for Cursor (Nix-generated, no secrets in the file)
  cursorMcpBase = pkgs.writeText "cursor-mcp-base.json"
    (builtins.toJSON { inherit mcpServers; });
in
{
  # Claude Code: declarative MCP via home-manager plugin mechanism
  programs.claude-code.mcpServers = mcpServers;

  # Cursor: write ~/.cursor/mcp.json as a real file (Cursor can't follow symlinks)
  # Also sync the affine command entry into ~/.claude.json (user-level Claude Code config)
  home.activation.cursor-mcp = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.cursor"
    cat ${cursorMcpBase} > "$HOME/.cursor/mcp.json"

    # Keep ~/.claude.json affine entry pointing to the current Nix store script
    CLAUDE_USER="$HOME/.claude.json"
    AFFINE_CMD="${affineMcp}"
    if [ -f "$CLAUDE_USER" ]; then
      ${pkgs.jq}/bin/jq \
        --arg cmd "$AFFINE_CMD" \
        'del(.mcpServers["affine_workspace_35d244cd-e6d5-4b3d-b1c2-fa50cab50621"])
         | .mcpServers.affine = {type:"stdio", command:$cmd}' \
        "$CLAUDE_USER" > "$CLAUDE_USER.tmp" && mv "$CLAUDE_USER.tmp" "$CLAUDE_USER"
    fi
  '';
}
