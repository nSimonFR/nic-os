# aperture-sync — pushes the Aperture AI gateway config on every rebuild.
#
# Derives the model list from tiny-llm-gate's settings (models + aliases keys)
# so there is a single source of truth. The JSON config is baked into the Nix
# store at eval time and PUT to Aperture's /api/config endpoint at boot.
#
# Aperture API format:
#   GET  /api/config → {"config": "<jsonc-string>", "exists": bool, "hash": "<hex>"}
#   PUT  /api/config ← {"config": "<json-string>", "hash": "<current-hash>"}
# The hash field provides optimistic concurrency (must match current value).
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

  # Claude models served by the Anthropic passthrough provider.
  # OAuth tokens can't query /v1/models (returns "OAuth authentication is
  # currently not supported"), so we hardcode the current model list here.
  # Update when Anthropic releases new models.
  anthropicModels = [
    "claude-opus-4-7"
    "claude-opus-4-6"
    "claude-sonnet-4-6"
    "claude-sonnet-4-5-20250929"
    "claude-haiku-4-5-20251001"
    "claude-haiku-4-5"
  ];

  # The inner config that Aperture manages — this gets JSON-encoded into a
  # string value inside the PUT envelope.
  apertureConfig = builtins.toJSON {
    providers = {
      rpi5-gate = {
        baseurl = "https://${tailnetFqdn}:4001";
        apikey = "unused";
        models = allModels;
        compatibility = { openai_chat = true; gemini_generate_content = true; };
        name = "tiny-llm-gate (RPi5)";
      };
      rpi5-gate-anthropic = {
        baseurl = "https://${tailnetFqdn}:4001";
        apikey = "unused";
        models = anthropicModels;
        compatibility = { anthropic_messages = true; };
        name = "Claude Code (Anthropic passthrough)";
      };
    };
    grants = [
      {
        src = [ "*" ];
        app = {
          "tailscale.com/cap/aperture" = [
            { role = "admin"; }
          ];
        };
      }
      {
        src = [ "*" ];
        app = {
          "tailscale.com/cap/aperture" = [
            { role = "user"; models = "**"; }
          ];
        };
      }
    ];
  };

  # Write the inner config JSON to a file for the script to read.
  configFile = pkgs.writeText "aperture-inner-config.json" apertureConfig;

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
        JQ="${pkgs.jq}/bin/jq"
        API="${apertureUrl}/api/config"

        # Aperture may take a moment to become reachable after tailscaled starts.
        # Retry up to 5 times with 5s delay.
        for i in 1 2 3 4 5; do
          # 1. Get current hash (optimistic concurrency)
          CURRENT=$($CURL -sf "$API" 2>/dev/null) || {
            echo "Aperture unreachable, retrying in 5s (attempt $i/5)..." >&2
            sleep 5
            continue
          }
          HASH=$(echo "$CURRENT" | $JQ -r .hash)

          # 2. Build the PUT envelope: {"config": "<json-string>", "hash": "<hash>"}
          INNER_CONFIG=$(cat ${configFile})
          PAYLOAD=$($JQ -n --arg config "$INNER_CONFIG" --arg hash "$HASH" \
            '{config: $config, hash: $hash}')

          # 3. PUT the config
          RESULT=$($CURL -sf -X PUT "$API" \
            -H "Content-Type: application/json" \
            -d "$PAYLOAD" 2>/dev/null) || {
            echo "PUT failed, retrying in 5s (attempt $i/5)..." >&2
            sleep 5
            continue
          }

          SUCCESS=$(echo "$RESULT" | $JQ -r '.success // false')
          if [ "$SUCCESS" = "true" ]; then
            NEW_HASH=$(echo "$RESULT" | $JQ -r .hash)
            echo "Aperture config synced successfully (hash $HASH → $NEW_HASH)"
            exit 0
          fi

          MSG=$(echo "$RESULT" | $JQ -r '.error.message // .message // "unknown error"')
          echo "Aperture rejected config: $MSG, retrying in 5s (attempt $i/5)..." >&2
          sleep 5
        done

        echo "WARN: failed to sync Aperture config after 5 attempts" >&2
        exit 1
      '';
    };
  };
}
