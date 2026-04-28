{ username, ... }:
{
  # WS bridge onto a single `pi --mode rpc` process, with a permission-gate
  # extension that surfaces every tool call as an extension_ui_request the
  # mobile client must approve. Loopback only — exposed on the tailnet via
  # services-registry.nix entry (port 4344 → 127.0.0.1:8341).
  services.pi-mobile = {
    enable = true;
    port = 8341;
    user = username;
  };
}
