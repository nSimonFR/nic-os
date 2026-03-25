{
  config,
  lib,
  pkgs,
  unstablePkgs,
  inputs,
  ...
}:
let
  # Use unstablePkgs so HA version matches (or exceeds) the .HA_VERSION written
  # by the previous Docker container. nixpkgs 25.11 ships 2025.11.x; the Docker
  # stable image had already advanced to 2026.x — HA refuses to start on downgrade.
  # Run `nix flake lock --update-input nixpkgs-unstable` to pull in the latest release.
  haVoltalis = unstablePkgs.buildHomeAssistantComponent rec {
    owner = "jdelahayes";
    domain = "voltalis";
    version = "master";
    src = unstablePkgs.fetchFromGitHub {
      owner = "jdelahayes";
      repo = "ha-voltalis";
      rev = "master";
      sha256 = "sha256-lCqXtVEkhwmLYosWycO2GbECglEp9wfFFaIDuSFUBBk=";
    };
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
    package = unstablePkgs.home-assistant.overrideAttrs (_: {
      doInstallCheck = false;
    });
    customComponents = [ haVoltalis ];
    extraComponents = [
      # Already in the module's aarch64 defaults: default_config, met, esphome, rpi_power
      "homekit"    # HomeKit bridge — uses zeroconf/mDNS
      "prometheus" # Metrics endpoint scraped by Prometheus
    ];
  };

  # One-shot migration: chown /var/lib/hass from the Docker-era owner to hass.
  # Safe to leave in place — idempotent after the first rebuild.
  system.activationScripts.hassMigrateOwnership.text = ''
    if [ -d /var/lib/hass ]; then
      chown -R hass:hass /var/lib/hass
    fi
  '';

  # ── ha-linky: Linky → HA bridge (standalone, no NixOS package) ────────
  virtualisation.oci-containers = {
    backend = "docker";

    containers.ha-linky = {
      image = "ha-linky:latest";
      environment = {
        TZ = "Europe/Paris";
      };
      environmentFiles = [ "/etc/ha-linky/ha-linky.env" ];
      volumes = [
        "/etc/home-assistant/ha-linky:/config"
        "/etc/home-assistant/ha-linky:/data"
      ];
      extraOptions = [ "--network=host" ];
    };
  };

  systemd.services.ha-linky-build = {
    description = "Build ha-linky Docker image";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "docker.service"
    ];
    wants = [
      "network-online.target"
      "docker.service"
    ];
    path = [
      pkgs.git
      pkgs.docker
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.docker}/bin/docker build https://github.com/bokub/ha-linky.git -f standalone.Dockerfile -t ha-linky";
    };
  };

  systemd.services."docker-ha-linky".requires = [ "ha-linky-build.service" ];
  systemd.services."docker-ha-linky".after = [ "ha-linky-build.service" ];

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
