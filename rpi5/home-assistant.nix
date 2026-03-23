{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
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
in
{
  # We run HA in a container; disable native service
  services.home-assistant.enable = false;

  virtualisation.oci-containers = {
    backend = "docker";

    containers.homeassistant = {
      image = "ghcr.io/home-assistant/home-assistant:stable";
      environment = {
        TZ = "Europe/Paris";
      };
      volumes = [
        "/var/lib/hass:/config"
        "/run/dbus:/run/dbus:ro"
        "/run/udev:/run/udev:ro"
      ];
      extraOptions = [
        "--network=host"
        "--cap-add=NET_ADMIN"
        "--cap-add=NET_RAW"
      ];
    };

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

  system.activationScripts.hassConfigDir.text = ''
    set -eu
    install -d -m 0755 /var/lib/hass
    install -d -m 0755 /var/lib/hass/custom_components
    if [ ! -f /var/lib/hass/configuration.yaml ]; then
      touch /var/lib/hass/configuration.yaml
      chmod 0644 /var/lib/hass/configuration.yaml
    fi
    # Enable the Prometheus integration (idempotent append)
    if ! grep -q "^prometheus:" /var/lib/hass/configuration.yaml 2>/dev/null; then
      printf '\nprometheus:\n' >> /var/lib/hass/configuration.yaml
    fi
    # Bind HA to localhost only — Tailscale Serve (100.x.x.x:8123) proxies external access.
    # Using 127.0.0.1 avoids conflicting with Tailscale's port binding and is more secure.
    if ! grep -q "server_host" /var/lib/hass/configuration.yaml 2>/dev/null; then
      sed -i 's/^http:$/http:\n  server_host: "127.0.0.1"/' /var/lib/hass/configuration.yaml || true
    fi
    # Ensure the ha-api-token directory exists (token itself is created manually)
    install -d -m 0755 /etc/home-assistant
    # Copy Voltalis custom component into config dir so it works inside the container
    rm -rf /var/lib/hass/custom_components/voltalis
    mkdir -p /var/lib/hass/custom_components
    cp -r ${haVoltalis}/custom_components/voltalis /var/lib/hass/custom_components/ || true
  '';

  # ── Prometheus scrape ────────────────────────────────────────────────
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

  # Home Assistant web UI
  networking.firewall.allowedTCPPorts = [ 8123 ];
  networking.firewall.allowedUDPPorts = [ 8123 ];
}
