{
  config,
  pkgs,
  apertureUrl,
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
  # Miro and GitHub come from the claude.ai connectors.
  programs.claude-code.mcpServers = {
    # Every MCP server, aggregated by Aperture (the `connectors` list in
    # hosts/rpi5/agents/aperture-sync.nix); access is by tailnet identity.
    aperture = {
      type = "http";
      url = "${apertureUrl}/v1/mcp";
    };
    # SSH sessions approved by passkey on the phone (hosts/rpi5/security/shellwatch.nix).
    # Not via Aperture: the OAuth token is the human's, per client.
    shellwatch = {
      type = "http";
      url = "https://${tailnetFqdn}:3995/mcp";
    };
  };

  home.file.".local/libexec/mcp-env".source = mcpEnv;
}
