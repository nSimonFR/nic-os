{ username, config, lib, ... }:
{
  # amarre — agent-agnostic WS harness for CLI coding agents. Two named
  # instances run side-by-side on the same port (selected per-session via
  # POST /sessions { instanceId }):
  #   * `pi`          — pi-coding-agent with the existing permission-gate
  #                     extension. Exact backwards-compat with the old
  #                     pi-mobile service for the Expo client.
  #   * `claude-code` — Anthropic claude CLI driven by the SDK broker; this
  #                     is the instance that gets mirrored to claude.ai/code
  #                     when remoteClaude.enable is on (PROTOCOL §14).
  # Loopback only — exposed on the tailnet via services-registry.nix entry
  # (port 4344 → 127.0.0.1:8341).
  services.amarre = {
    enable = true;
    user = username;
    port = 8341;
    instances = {
      pi = { agent = "pi"; };
      claude-code = {
        agent = "claude-code";
        env = {
          # Token-bearer file written by claude-remote-control.service; the
          # broker's Remote Claude layer reads it via tokenPath below.
          CLAUDE_BIN = "/home/${username}/.local/state/nix/profiles/home-manager/home-path/bin/claude";
        };
      };
    };

    # PROTOCOL §14 — also expose every claude-code session at claude.ai/code
    # for dual-control. amarre stays the primary control plane; both surfaces
    # feed the same SDK Query.
    remoteClaude = {
      enable = true;
      tokenPath = "/run/claude-oauth/token";
      titlePrefix = config.networking.hostName;
      tags = [ "amarre" "rpi5" ];
    };
  };
}
