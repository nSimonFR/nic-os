{
  config,
  pkgs,
  apertureUrl,
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
    # Self-hosted MCP servers (notes, sure, wealthfolio, airtrail, trains,
    # freereps), aggregated by Aperture (hosts/rpi5/agents/aperture-sync.nix); access
    # is by tailnet identity.
    aperture = {
      type = "http";
      url = "${apertureUrl}/v1/mcp";
    };
    # OAuth sign-in happens in the client (/mcp); no token in config.
    calcom = {
      type = "http";
      url = "https://mcp.cal.com/mcp";
    };
  };

  home.file.".local/libexec/mcp-env".source = mcpEnv;
}
