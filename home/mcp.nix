{
  config,
  lib,
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

  # Aperture's MCP behind Code Mode (search + execute), with the send tools left out;
  # on PATH for clients configured by hand (Codex / ChatGPT Work).
  apertureCodemode = pkgs.writeShellScriptBin "aperture-codemode" ''
    export APERTURE_MCP_URL=${apertureUrl}/v1/mcp
    export CODEMODE_EXCLUDE=${lib.concatStringsSep "," (import ../shared/aperture-send-tools.nix)}
    exec ${lib.getExe pkgs.aperture-codemode}
  '';

  # Code Mode limited to messaging_send_message: every `execute` is a send, so the `ask`
  # rule in claude-settings.json shows its code (room and text) before anything goes out.
  # The `aperture` server above keeps the send tools hidden.
  apertureSend = pkgs.writeShellScriptBin "aperture-send" ''
    export APERTURE_MCP_URL=${apertureUrl}/v1/mcp
    export CODEMODE_INCLUDE=messaging_send_message
    exec ${lib.getExe pkgs.aperture-codemode}
  '';
in
{
  # Miro and GitHub come from the claude.ai connectors.
  programs.claude-code.mcpServers = {
    # Every MCP server, aggregated by Aperture (the `connectors` list in
    # hosts/rpi5/agents/aperture-sync.nix); access is by tailnet identity.
    aperture = {
      type = "stdio";
      command = lib.getExe apertureCodemode;
    };
    aperture-send = {
      type = "stdio";
      command = lib.getExe apertureSend;
    };
  };

  home.file.".local/libexec/mcp-env".source = mcpEnv;
  home.packages = [ apertureCodemode ];
}
