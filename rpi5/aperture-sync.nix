# aperture-sync — pushes the Aperture AI gateway config on every rebuild.
#
# Derives the model list from tiny-llm-gate's settings (models + aliases keys)
# so there is a single source of truth. The JSON config is baked into the Nix
# store at eval time and PUT to Aperture's /api/config endpoint at boot.
#
# Aperture is a Tailscale-managed proxy on the tailnet — it is NOT self-hosted.
# Auth comes from Tailscale identity (the RPi5 node is an admin via grants).
{ config, pkgs, lib, apertureUrl, tailnetFqdn, ... }:
let
  gateCfg = config.services.tiny-llm-gate.settings;

  # Collect every model name a client might send: canonical models + aliases.
  modelNames = builtins.attrNames (gateCfg.models or { });
  aliasNames = builtins.attrNames (gateCfg.aliases or { });
  allModels = lib.unique (modelNames ++ aliasNames);

  apertureConfig = builtins.toJSON {
    providers = {
      rpi5-gate = {
        baseurl = "https://${tailnetFqdn}:4001";
        apikey = "unused";
        models = allModels;
        compatibility = { openai_chat = true; };
        name = "tiny-llm-gate (RPi5)";
      };
    };
    grants = [
      {
        src = [ "*" ];
        app = {
          "tailscale.com/cap/aperture" = [
            { role = "admin"; }
            { models = "**"; }
          ];
        };
      }
    ];
  };

  configFile = pkgs.writeText "aperture-config.json" apertureConfig;

  isEnabled = apertureUrl != "http://127.0.0.1:4001";
in
{
  systemd.services.aperture-config-sync = lib.mkIf isEnabled {
    description = "Sync Aperture config with tiny-llm-gate model list";
    after = [ "network-online.target" "tiny-llm-gate.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "aperture-sync" ''
        set -eu
        CURL="${pkgs.curl}/bin/curl"

        # Aperture may take a moment to become reachable after tailscaled starts.
        # Retry up to 5 times with 5s delay.
        for i in 1 2 3 4 5; do
          if $CURL -sf -X PUT \
            "${apertureUrl}/api/config" \
            -H "Content-Type: application/json" \
            -d @${configFile} > /dev/null; then
            echo "Aperture config synced successfully (attempt $i)"
            exit 0
          fi
          echo "Aperture unreachable, retrying in 5s (attempt $i/5)..." >&2
          sleep 5
        done

        echo "WARN: failed to sync Aperture config after 5 attempts" >&2
        exit 1
      '';
    };
  };
}
