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
      # Already in the module's aarch64 defaults: default_config, met, esphome, rpi_power
      "homekit"    # HomeKit bridge — uses zeroconf/mDNS
      # Components whose Python deps were absent, causing default_config cascade failure:
      "conversation" # hassil — also required by mobile_app
      "dhcp"         # aiodhcpwatcher
      "ssdp"         # async_upnp_client
      "tts"          # mutagen
      "stream"       # av (PyAV)
      "usb"          # aiousbwatcher (required by default_config → bluetooth)
      # Configured integrations that also had missing deps:
      "met"          # metno
      "go2rtc"       # go2rtc_client
      "sfr_box"      # sfrbox_api
      "mobile_app"
      "google_translate" # gtts
      # Installs python-telegram-bot so the telegram_bot config-flow handler
      # loads in the UI. Configuration itself is done via Settings → Devices &
      # Services (YAML setup was removed in HA 2025.7).
      "telegram_bot"
    ];
  };

  # One-shot migration: chown /var/lib/hass from the Docker-era owner to hass.
  # Safe to leave in place — idempotent after the first rebuild.
  system.activationScripts.hassMigrateOwnership.text = ''
    if [ -d /var/lib/hass ]; then
      chown -R hass:hass /var/lib/hass
    fi
  '';

  # Ensure editor-created automations saved to automations.yaml are actually
  # loaded by Home Assistant. Existing user configuration is preserved; we only
  # append the include if it is missing.
  system.activationScripts.hassEnsureAutomationInclude.text = ''
    if [ ! -d /var/lib/hass ]; then
      exit 0
    fi

    if [ ! -e /var/lib/hass/configuration.yaml ]; then
      cat > /var/lib/hass/configuration.yaml <<'EOF'
    automation: !include automations.yaml
    EOF
    elif ! grep -Eq '^[[:space:]]*automation:[[:space:]]*!include[[:space:]]+automations\.yaml([[:space:]]|$)' /var/lib/hass/configuration.yaml; then
      printf '\nautomation: !include automations.yaml\n' >> /var/lib/hass/configuration.yaml
    fi

    if [ ! -e /var/lib/hass/automations.yaml ]; then
      : > /var/lib/hass/automations.yaml
    fi

    chown hass:hass /var/lib/hass/configuration.yaml /var/lib/hass/automations.yaml
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

  # ── Home Assistant RAM optimizations (RPi5 4 GB) ──────────────────────
  # Python/glibc creates one malloc arena per core by default; on a 4-core
  # RPi5 that wastes ~64 MB of virtual address space.  Cap at 2 arenas.
  systemd.services.home-assistant = {
    environment.MALLOC_ARENA_MAX = "2";
    serviceConfig.MemoryMax = "256M";
  };

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

        # Build options.json from agenix-managed secrets (use jq for safe JSON encoding)
        LINKY_TOKEN=$(cat /run/agenix/linky-token)
        LINKY_PRM=$(cat /run/agenix/linky-prm)
        ${pkgs.jq}/bin/jq -n \
          --arg token "$LINKY_TOKEN" \
          --arg prm "$LINKY_PRM" \
          '{meters:[{prm:$prm,token:$token,name:"Linky consumption",action:"sync",production:false}],costs:[{price:0.1261}]}' \
          > /etc/home-assistant/ha-linky/options.json
        chown ha-linky:ha-linky /etc/home-assistant/ha-linky/options.json
        chmod 0640 /etc/home-assistant/ha-linky/options.json
  '';

}
