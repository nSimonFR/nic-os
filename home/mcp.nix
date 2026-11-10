{
  config,
  pkgs,
  tailnetFqdn,
  ...
}:
let
  secretsPath = config.nic.userSecrets.mcp-secrets;

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
in
{
  # Linear, Miro and GitHub come from the claude.ai connectors.
  programs.claude-code.mcpServers = {
    # Notes (hosts/rpi5/knowledge/open-knowledge.nix): OpenKnowledge's own streamable-HTTP
    # MCP over the markdown notes folder. Unauthenticated; reachable on the tailnet only.
    notes = {
      type = "http";
      url = "https://${tailnetFqdn}:3980/mcp";
    };
    # OAuth sign-in happens in the client (/mcp); no token in config.
    calcom = {
      type = "http";
      url = "https://mcp.cal.com/mcp";
    };
  };

  home.file.".local/libexec/mcp-env".source = mcpEnv;
}
