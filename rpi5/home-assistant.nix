{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  # pkgs.home-assistant and pkgs.buildHomeAssistantComponent are both overridden
  # in overlays.nix to use nixpkgs-unstable, keeping HA current and preventing
  # the "cannot downgrade" startup failure when .HA_VERSION > binary version.
  haVoltalis = pkgs.buildHomeAssistantComponent rec {
    owner = "jdelahayes";
    domain = "voltalis";
    version = "master";
    src = pkgs.fetchFromGitHub {
      owner = "jdelahayes";
      repo = "ha-voltalis";
      rev = "master";
      sha256 = "sha256-lCqXtVEkhwmLYosWycO2GbECglEp9wfFFaIDuSFUBBk=";
    };
  };

  # ha-linky: TypeScript/Node.js Linky → Home Assistant bridge.
  # config.ts hardcodes /data/options.json; the service uses BindReadOnlyPaths
  # to mount /etc/home-assistant/ha-linky at /data inside the unit's namespace.
  # ha.ts reads WS_URL + SUPERVISOR_TOKEN from environment (EnvironmentFile).
  haLinky = pkgs.buildNpmPackage rec {
    pname = "ha-linky";
    version = "1.7.0";
    src = pkgs.fetchFromGitHub {
      owner = "bokub";
      repo = "ha-linky";
      rev = version;
      hash = "sha256-x8W/kR/L3uJ317MAayv3mUlPW3yw+Tnj4iD2c6CEnOQ=";
    };
    npmDepsHash = "sha256-y/64htlLa5RGemCIqXp9nxDgAK8zyVOq8kdW4azhY64=";
    # npm run build = tsc → dist/
    # Skip the default `npm install -g` install phase; we install manually.
    dontNpmInstall = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/{bin,lib/ha-linky}
      # node_modules must live next to dist/ for ESM relative-path resolution
      cp -r dist node_modules $out/lib/ha-linky/
      makeWrapper ${lib.getExe pkgs.nodejs} $out/bin/ha-linky \
        --add-flags "$out/lib/ha-linky/dist/index.js"
      runHook postInstall
    '';
  };
in
{
  # ── Native Home Assistant service ─────────────────────────────────────
  # Replaces the previous ghcr.io/home-assistant/home-assistant Docker container.
  # configDir defaults to /var/lib/hass — matches the existing Docker volume.
  # configuration.yaml is left unmanaged (no `config` attr) so HA can edit it.
  services.home-assistant = {
    enable = true;
    # null = leave configuration.yaml unmanaged; HA (and the user) owns it directly
    config = null;
    customComponents = [ haVoltalis ];
    extraComponents = [
      # default_config sub-dependencies that need Python packages
      "met"             # Weather (metno)
      "mobile_app"      # Companion app (home_assistant_intents)
      "stream"          # Camera streams (av)
      "go2rtc"          # go2rtc camera proxy (go2rtc_client)
      "conversation"    # Voice/NLU (hassil, home_assistant_intents)
      "assist_pipeline" # Voice pipeline (hassil)
      "dhcp"            # DHCP discovery (aiodhcpwatcher)
      "ssdp"            # UPnP/SSDP discovery (async_upnp_client)
      "usb"             # USB device detection (aiousbwatcher)
      "google_translate" # TTS (gtts)
      # Other integrations
      "homekit"         # HomeKit bridge — uses zeroconf/mDNS
      "prometheus"      # Metrics endpoint scraped by Prometheus
    ];
  };

  # One-shot migration: chown /var/lib/hass from the Docker-era owner to hass.
  # Safe to leave in place — idempotent after the first rebuild.
  system.activationScripts.hassMigrateOwnership.text = ''
    if [ -d /var/lib/hass ]; then
      chown -R hass:hass /var/lib/hass
    fi
  '';

  # Remove real directories under custom_components left by Docker-era HA.
  # The nixpkgs home-assistant pre-start uses `ln -fns` which cannot overwrite
  # real directories — only symlinks. This runs before the service starts.
  system.activationScripts.hassCleanCustomComponents.text = ''
    if [ -d /var/lib/hass/custom_components ]; then
      find /var/lib/hass/custom_components -maxdepth 1 -mindepth 1 -type d \
        -exec rm -rf {} +
    fi
  '';

  # ── ha-linky: native systemd service ──────────────────────────────────
  users.users.ha-linky = {
    isSystemUser = true;
    group = "ha-linky";
  };
  users.groups.ha-linky = {};

  systemd.services.ha-linky = {
    description = "ha-linky Linky → Home Assistant bridge";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "home-assistant.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${haLinky}/bin/ha-linky";
      Restart = "on-failure";
      RestartSec = "30";
      User = "ha-linky";
      Group = "ha-linky";
      # config.ts hardcodes /data/options.json; bind our real path read-only
      BindReadOnlyPaths = "/etc/home-assistant/ha-linky:/data";
      EnvironmentFile = "/etc/ha-linky/ha-linky.env";
    };
  };

  system.activationScripts.haLinkyBootstrap.text = ''
        set -eu
        install -d -m 0755 /etc/ha-linky
        install -d -m 0755 /etc/home-assistant/ha-linky

        # Build ha-linky.env from the agenix-managed secret
        SUPERVISOR_TOKEN=$(cat /run/agenix/supervisor-token)
        cat > /etc/ha-linky/ha-linky.env <<EOF
    SUPERVISOR_TOKEN=$SUPERVISOR_TOKEN
    WS_URL=ws://127.0.0.1:8123/api/websocket
    EOF
        chown ha-linky:ha-linky /etc/ha-linky/ha-linky.env
        chmod 0640 /etc/ha-linky/ha-linky.env

        # Build options.json from agenix-managed secrets
        LINKY_TOKEN=$(cat /run/agenix/linky-token)
        LINKY_PRM=$(cat /run/agenix/linky-prm)
        cat > /etc/home-assistant/ha-linky/options.json <<EOF
    {
      "meters": [
        {
          "prm": "$LINKY_PRM",
          "token": "$LINKY_TOKEN",
          "name": "Linky consumption",
          "action": "sync",
          "production": false
        }
      ],
      "costs": [
        {
          "price": 0.1261
        }
      ]
    }
    EOF
        chown ha-linky:ha-linky /etc/home-assistant/ha-linky/options.json
        chmod 0640 /etc/home-assistant/ha-linky/options.json
  '';

  # ── Prometheus scrape ─────────────────────────────────────────────────
  # bearer_token_file is populated manually after first deploy:
  #   echo TOKEN | sudo tee /etc/home-assistant/ha-api-token && sudo chmod 640 /etc/home-assistant/ha-api-token
  systemd.tmpfiles.rules = [
    "f /etc/home-assistant/ha-api-token 0640 root prometheus - -"
  ];

  services.prometheus.scrapeConfigs = [{
    job_name          = "home_assistant";
    static_configs    = [{ targets = [ "127.0.0.1:8123" ]; }];
    metrics_path      = "/api/prometheus";
    bearer_token_file = "/etc/home-assistant/ha-api-token";
  }];
}
