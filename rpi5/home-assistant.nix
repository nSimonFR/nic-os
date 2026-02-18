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
      volumes = [ "/etc/home-assistant/ha-linky:/data" ];
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

        # Seed secret files with placeholders on first deploy
        if [ ! -f /etc/ha-linky/supervisor-token ]; then
          echo "CHANGE_ME" > /etc/ha-linky/supervisor-token
          chmod 0600 /etc/ha-linky/supervisor-token
        fi
        if [ ! -f /etc/ha-linky/linky-token ]; then
          echo "CHANGE_ME" > /etc/ha-linky/linky-token
          chmod 0600 /etc/ha-linky/linky-token
        fi

        # Build ha-linky.env from the secret file
        SUPERVISOR_TOKEN=$(cat /etc/ha-linky/supervisor-token)
        cat > /etc/ha-linky/ha-linky.env <<EOF
    SUPERVISOR_TOKEN=$SUPERVISOR_TOKEN
    WS_URL=ws://127.0.0.1:8123/api/websocket
    EOF
        chmod 0640 /etc/ha-linky/ha-linky.env

        # Build options.json from the secret file
        LINKY_TOKEN=$(cat /etc/ha-linky/linky-token)
        cat > /etc/home-assistant/ha-linky/options.json <<EOF
    {
      "meters": [
        {
          "prm": "07233719170885",
          "token": "$LINKY_TOKEN",
          "name": "Linky consumption",
          "action": "sync",
          "production": false
        },
        {
          "prm": "07233719170885",
          "token": "$LINKY_TOKEN",
          "name": "Linky production",
          "action": "sync",
          "production": true
        }
      ],
      "costs": [
        {
          "price": 0.0337
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
    # Copy Voltalis custom component into config dir so it works inside the container
    rm -rf /var/lib/hass/custom_components/voltalis
    mkdir -p /var/lib/hass/custom_components
    cp -r ${haVoltalis}/custom_components/voltalis /var/lib/hass/custom_components/ || true
  '';

  # Home Assistant web UI
  networking.firewall.allowedTCPPorts = [ 8123 ];
  networking.firewall.allowedUDPPorts = [ 8123 ];
}
