{
  config,
  pkgs,
  inputs,
  ...
}:
let
  # pkgs.home-assistant and pkgs.buildHomeAssistantComponent are both overridden
  # in overlays.nix to use the dedicated nixpkgs-hass input, keeping HA current
  # and preventing the "cannot downgrade" startup failure when the data dir was
  # written by a newer release than the binary.
  #
  # The two custom components take HA's own python set so their deps match the
  # ABI of the HA binary — hence the explicit python3Packages argument.
  haPython = config.services.home-assistant.package.python3Packages;
  haVoltalis = pkgs.callPackage ../../pkgs/home-assistant/ha-voltalis.nix { python3Packages = haPython; };
  haIntratone = pkgs.callPackage ../../pkgs/home-assistant/ha-intratone.nix { python3Packages = haPython; };
  haLinky = pkgs.callPackage ../../pkgs/home-assistant/ha-linky.nix { };

  # Lovelace registration block appended once to the (otherwise unmanaged)
  # configuration.yaml. Kept as a writeText file so the activation script can
  # `cat` it in verbatim — avoids heredoc/Nix-interpolation quoting pitfalls.
  lovelaceInclude = pkgs.writeText "nic-os-lovelace.yaml" ''

    # nic-os-managed: lovelace-dashboards
    lovelace:
      dashboards:
        mine-dashboard:
          mode: yaml
          title: Mine
          icon: mdi:account
          show_in_sidebar: true
          filename: dashboards/mine.yaml
  '';
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
    customComponents = [ haVoltalis haIntratone ];
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

  # Versioned "Mine" dashboard: load the repo-tracked YAML dashboard in YAML
  # mode. The dashboard file is symlinked into the config dir at a stable path
  # so the store hash can change on rebuild without editing configuration.yaml,
  # and the lovelace registration is injected once (marker-guarded, same idiom
  # as the automation include above). configuration.yaml stays otherwise
  # unmanaged — if the user has already added a `lovelace:` key by hand we skip
  # rather than create a duplicate mapping key.
  system.activationScripts.hassVersionedDashboards.text = ''
    if [ ! -d /var/lib/hass ]; then
      exit 0
    fi

    install -d -o hass -g hass /var/lib/hass/dashboards
    ln -fns ${./home-assistant/dashboards/mine.yaml} /var/lib/hass/dashboards/mine.yaml

    cfg=/var/lib/hass/configuration.yaml
    if [ -e "$cfg" ] && ! grep -q 'nic-os-managed: lovelace-dashboards' "$cfg"; then
      if grep -Eq '^[[:space:]]*lovelace:' "$cfg"; then
        echo "hass: existing 'lovelace:' key in configuration.yaml; skipping managed dashboard block" >&2
      else
        cat ${lovelaceInclude} >> "$cfg"
        chown hass:hass "$cfg"
      fi
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
      # After=home-assistant.service only waits for the unit to be marked
      # active, not for the Python app to bind :8123 (~30s on the Pi). Poll
      # until HA actually accepts connections so the first start doesn't race.
      ExecStartPre = pkgs.writeShellScript "wait-for-ha" ''
        for _ in $(${pkgs.coreutils}/bin/seq 1 60); do
          if ${pkgs.curl}/bin/curl -fsS --connect-timeout 2 -o /dev/null \
              http://127.0.0.1:8123/manifest.json 2>/dev/null; then
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 2
        done
        echo "ha-linky: timed out waiting for Home Assistant on :8123" >&2
        exit 1
      '';
      ExecStart = "${haLinky}/bin/ha-linky";
      TimeoutStartSec = "180";
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

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.home-assistant = {
    backup        = [ "unit" ];
    backupUnits   = [ "hass-backup.service" ];   # backups.nix
    heavyUnits    = [ "home-assistant.service" ];
    heavyPriority = 20;

    public = {
      order   = 160;
      port    = 8123;
      backend = "http://127.0.0.1:8123";
      tile = {
        name        = "Home Assistant";
        icon        = "home-assistant.svg";
        category    = "Apps";
        description = "Home automation";
        # Deep-link the tile straight to the "Mine" Lovelace dashboard (url_path
        # "mine-dashboard" above) instead of HA's root. Cosmetic only — HA is not
        # behind the path-mux, so this is not a muxPath.
        deepLink    = "/mine-dashboard/";
        # Routed through the homepage-stats aggregator (:8087, daily-cached) like the
        # other tiles rather than the native `homeassistant` widget that polls HA
        # every 60s. Figures can be up to the aggregator's REFRESH_INTERVAL (24h)
        # stale — acceptable for a glanceable tile; the aggregator holds the HA
        # token, so no key is exposed here.
        #
        # Electricity, not entity counts. The previous three fields were
        # people_home / lights_on / switches_on, two of which could not move: one
        # `person.` entity makes "Home" a boolean, and there is not a single
        # `light.` entity on this install, so "Lights" was a permanent 0. What
        # replaced them each carry a comparison — see fetch_homeassistant.
        #
        # `format = "text"`, like Sure and Wealthfolio: the fetcher returns a
        # pre-formatted string with its delta already in brackets, because homepage
        # only renders an additionalField in `display: list` and drops it silently
        # in the default block renderer.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/homeassistant";
          refreshInterval = 3600000;
          mappings = [
            # The last day Enedis actually reported (~2 days back), against the
            # mean of the seven before it.
            { field = "day";     label = "Yesterday"; format = "text"; }
            { field = "cost";    label = "30 days";   format = "text"; }
            # Voltalis heaters: consumed so far today, and how many rooms are on
            # right now — the one live figure on the tile.
            { field = "heating"; label = "Heating";   format = "text"; }
          ];
        };
      };
    };
  };
}
