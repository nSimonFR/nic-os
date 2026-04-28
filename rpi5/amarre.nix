{ username, ... }:
{
  # amarre — agent-agnostic WS harness for CLI coding agents. Loads the
  # `pi` adapter at startup, which spawns `pi --mode rpc` with a permission-
  # gate extension that surfaces every tool call as an extension_ui_request
  # the mobile client must approve. Loopback only — exposed on the tailnet
  # via services-registry.nix entry (port 4344 → 127.0.0.1:8341).
  services.amarre = {
    enable = true;
    agent = "pi";
    port = 8341;
    user = username;
  };
}
