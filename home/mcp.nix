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

  # Runs an MCP server with the agenix secrets loaded and uv on PATH. A fixed path,
  # so configs outside this repo (the private trusk checkout's mcp.json) can use it.
  # set -a: the secrets file has bare KEY=value lines, which must reach the child.
  mcpEnv = pkgs.writeShellScript "mcp-env" ''
    set -a
    [ -f "${secretsPath}" ] && . "${secretsPath}"
    set +a
    export PATH=${pkgs.uv}/bin''${PATH:+:$PATH}
    exec "$@"
  '';

  # AFFiNE MCP — write-capable. tiny-llm-gate exposes an SSE bridge at
  # tailnet :7020 that proxies to affine-mcp.service (DAWNCR0W) on the rpi5.
  # See hosts/rpi5/affine-mcp.nix and hosts/rpi5/tiny-llm-gate.nix.
  #
  # `tailnetFqdn` is the rpi5's MagicDNS name and is passed to all three
  # home-manager configs (it was previously passed and never read here, with the
  # name spelled out as a literal instead). Note this stays the *public* tailnet
  # URL even on the rpi5 itself, where it means the box reaches its own MCP by
  # going out to its own name and back: the :7020 listener is a `tailscale serve`
  # mapping (nic.services.affine-mcp.public), so it is bound on the tailnet address
  # only and has no loopback equivalent at that port. Short-circuiting it means
  # pointing at tiny-llm-gate's backend route directly — a behaviour change worth
  # its own commit, not a side effect of this one.
  affineMcpUrl = "https://${tailnetFqdn}:7020/sse";

  # Notes (hosts/rpi5/notes.nix): OpenKnowledge's own streamable-HTTP MCP over the
  # markdown notes folder. Unauthenticated; reachable on the tailnet only.
  notesMcpUrl = "https://${tailnetFqdn}:3980/mcp";

  # Shared MCP server definitions (no plaintext secrets)
  mcpServers = {
    # Public — no secrets
    Linear              = { type = "sse"; url = "https://mcp.linear.app/sse"; };
    # Private — secrets loaded at runtime via wrapper scripts
    GitHub  = { command = "${githubMcp}"; };
    Miro    = { command = "${miroMcp}"; };
    affine  = { type = "sse"; url = affineMcpUrl; };
    notes   = { type = "http"; url = notesMcpUrl; };
  };

  # Pre-built JSON for Cursor (Nix-generated, no secrets in the file)
  cursorMcpBase = pkgs.writeText "cursor-mcp-base.json"
    (builtins.toJSON { inherit mcpServers; });
in
{
  # Claude Code: declarative MCP via home-manager plugin mechanism
  programs.claude-code.mcpServers = mcpServers;

  home.file.".local/libexec/mcp-env".source = mcpEnv;

  # Cursor: write ~/.cursor/mcp.json as a real file (Cursor can't follow symlinks)
  # Also sync the affine command entry into ~/.claude.json (user-level Claude Code config)
  home.activation.cursor-mcp = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p "$HOME/.cursor"
    TRUSK_MCP="$HOME/MyDocuments/TRUSK/trusk/mcp.json"
    if [ -r "$TRUSK_MCP" ]; then
      ${pkgs.jq}/bin/jq -s '.[0].mcpServers += .[1].mcpServers | .[0]' \
        ${cursorMcpBase} "$TRUSK_MCP" > "$HOME/.cursor/mcp.json"
    else
      cat ${cursorMcpBase} > "$HOME/.cursor/mcp.json"
    fi

    # Keep ~/.claude.json affine entry pointing to shared SSE gateway
    CLAUDE_USER="$HOME/.claude.json"
    if [ -f "$CLAUDE_USER" ]; then
      ${pkgs.jq}/bin/jq \
        --arg url "${affineMcpUrl}" \
        'del(.mcpServers["affine_workspace_35d244cd-e6d5-4b3d-b1c2-fa50cab50621"])
         | .mcpServers.affine = {type:"sse", url:$url}' \
        "$CLAUDE_USER" > "$CLAUDE_USER.tmp" && mv "$CLAUDE_USER.tmp" "$CLAUDE_USER"
    fi
  '';
}
