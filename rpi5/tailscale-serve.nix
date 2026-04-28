{ pkgs, lib, tailnetFqdn, ... }:
let
  registry = import ./services-registry.nix { };
  inherit (registry) serveEntries funnelEntries;

  ts = "${pkgs.tailscale}/bin/tailscale";

  serveUp   = lib.concatMapStringsSep "\n  " (e: "${ts} serve   --bg --https=${toString e.port} ${e.backend}") serveEntries;
  funnelUp  = lib.concatMapStringsSep "\n  " (e: "${ts} funnel  --bg --https=${toString e.port} ${e.backend}") funnelEntries;
  serveDown = lib.concatMapStringsSep "\n  " (e: "${ts} serve  --https=${toString e.port} off || true") serveEntries;
  funnelDown= lib.concatMapStringsSep "\n  " (e: "${ts} funnel --https=${toString e.port} off || true") funnelEntries;
in
{
  systemd.services.tailscale-serve = {
    description = "Tailscale Serve + Funnel";
    after    = [ "network-online.target" "tailscaled.service" "tailscale-autoconnect.service" ];
    wants    = [ "network-online.target" "tailscaled.service" "tailscale-autoconnect.service" ];
    requires = [ "tailscale-autoconnect.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "10s";
    };
    script = ''
      sleep 2
      ${ts} serve reset || true
      ${serveUp}
      ${funnelUp}
      # /mnt/data/cloud is a bind-mount of Nextcloud's user-files dir
      # (see rpi5/nextcloud.nix systemd.mounts) — share that so clients see
      # a clean view of the user's files, not Nextcloud's config/, data/,
      # appdata_* internals.
      # `drive share <name> <path>` silently no-ops if a share with the
      # same name already exists at a different path — unshare first so
      # path changes always take effect on rebuild.
      ${ts} drive unshare cloud || true
      ${ts} drive share cloud /mnt/data/cloud || true
    '';
    preStop = ''
      ${serveDown}
      ${funnelDown}
      ${ts} drive unshare cloud || true
    '';
  };
}
