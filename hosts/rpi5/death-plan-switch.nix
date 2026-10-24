# hosts/rpi5/death-plan-switch.nix
#
# Death Plan Switch — weekly check-in email; if missed, asks the next of kin, then
# emails each contact the message written for them. PHP-FPM (ondemand, ~0 RAM at
# rest) behind the 443 path-mux at /switch, scheduler on a 15-min systemd timer.
#
# Contacts open their links from outside the tailnet, so only the contact-facing
# pages are public. The admin pages (index.php, install.php) answer 404 to funnel
# traffic: tailscaled strips a client-sent Tailscale-Funnel-Request and sets it
# itself on funnel requests only.
#
# ⚠ Upstream says host it apart from what it watches: a Pi or tailnet outage
#   silences it too. Point an outside uptime monitor at the secret health URL
#   (Settings) — that is the only alarm for that case.
#
# FIRST-TIME SETUP (from a tailnet device): open <publicUrl>/install.php. SMTP is
# hydroxide on 127.0.0.1:1025, no TLS, login = proton address, password = bridge
# password. Skip the installer's crontab step — the timer below already runs it.
{ config, pkgs, tailnetFqdn, username, ... }:
let
  name    = "death-plan-switch";
  dataDir = "/mnt/data/death-plan-switch";
  pkg     = pkgs.callPackage ../../pkgs/services/death-plan-switch.nix {
    inherit dataDir;
    vaultHook = "${bridgeBin}/bin/dps-ea-bridge";
  };
  appDir  = "${pkg}/share/switch";
  php     = pkgs.php;
  port    = 8094;  # backend vhost; the path-mux forwards /switch/* here unchanged
  socket  = config.services.phpfpm.pools.${name}.socket;

  fastcgi = ''
    include ${config.services.nginx.package}/conf/fastcgi.conf;
    fastcgi_param HTTPS on;
    fastcgi_pass unix:${socket};
  '';

  # Emergency Access bridge (nicos_scripts/vaultwarden/ea_bridge.py), as the
  # switch's user: it reads the switch's state and reuses its SMTP settings. The
  # switch calls it from PHP-FPM too, which clears the env, hence the wrapper.
  # One-time seed, with the grantee password on the Mac clipboard:
  #   pbpaste | sudo -u death-plan-switch dps-ea-bridge seed
  bridgeState = "/var/lib/dps-ea-bridge";
  bridgeBin = pkgs.writeShellApplication {
    name = "dps-ea-bridge";
    text = ''
      export SWITCH_DIR=${dataDir} STATE_DIR=${bridgeState} DRY_RUN=0
      export VAULT_URL=http://127.0.0.1:8222/vaultwarden
      export PUBLIC_URL=https://${tailnetFqdn}/vaultwarden
      export GRANTEE_EMAIL=${username}+ea@pm.me GRANTOR_EMAIL=${username}@pm.me
      exec ${pkgs.nicos-scripts}/bin/dps-ea-bridge "$@"
    '';
  };
  bridge = cmd: {
    description = "Death Plan Switch → Vaultwarden Emergency Access (${cmd})";
    unitConfig.RequiresMountsFor = [ dataDir ];
    serviceConfig = {
      Type = "oneshot";
      User = name;
      Group = name;
      ExecStart = "${bridgeBin}/bin/dps-ea-bridge ${cmd}";
    };
  };
in
{
  users.users.${name} = {
    isSystemUser = true;
    group = name;
  };
  users.groups.${name} = { };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0700 ${name} ${name} -"
    "d ${bridgeState} 0700 ${name} ${name} -"
  ];
  environment.systemPackages = [ bridgeBin ];

  services.phpfpm.pools.${name} = {
    user = name;
    group = name;
    phpPackage = php;
    settings = {
      "listen.owner" = config.services.nginx.user;
      "listen.group" = config.services.nginx.group;
      pm = "ondemand";
      "pm.max_children" = 2;
      "pm.process_idle_timeout" = "60s";
    };
  };
  systemd.services."phpfpm-${name}".unitConfig.RequiresMountsFor = [ dataDir ];

  services.nginx.virtualHosts.${name} = {
    listen = [ { addr = "127.0.0.1"; inherit port; ssl = false; } ];
    root = "${pkg}/share";
    extraConfig = ''
      index index.php;
      absolute_redirect off;
    '';
    # Regex locations match in file order, so the denies need the lower priority.
    locations = {
      "~ ^/switch/(data|app|cli|tests|docs)/" = { priority = 100; extraConfig = "deny all;"; };
      "~ /\\." = { priority = 100; extraConfig = "deny all;"; };
      "~ \\.(json|jsonl|bak|lock|md|example)$" = { priority = 100; extraConfig = "deny all;"; };
      # The web scheduler is redundant with the timer; config.local.php only defines DPS_DATA.
      "~ ^/switch/(config\\.local\\.php|tick\\.php|LICENSE)$" = { priority = 100; extraConfig = "deny all;"; };

      "~ ^/switch/(index|install)\\.php$" = {
        priority = 200;
        extraConfig = ''
          if ($http_tailscale_funnel_request) { return 404; }
          ${fastcgi}
        '';
      };
      "~ ^/switch/(checkin|confirm|respond|health)\\.php$" = {
        priority = 300;
        extraConfig = fastcgi;
      };
      "~ \\.php$" = { priority = 400; extraConfig = "return 404;"; };
    };
  };

  systemd.services."${name}-tick" = {
    description = "Death Plan Switch scheduler";
    unitConfig.RequiresMountsFor = [ dataDir ];
    serviceConfig = {
      Type = "oneshot";
      User = name;
      Group = name;
      ExecStart = "${php}/bin/php ${appDir}/cron.php";
    };
  };
  systemd.timers."${name}-tick" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = true;
    };
  };

  systemd.services.dps-ea-bridge = bridge "run";
  systemd.timers.dps-ea-bridge = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "*:0/5";
  };
  # Non-zero exit = the systemd-failed alert on Telegram.
  systemd.services.dps-ea-bridge-check = bridge "check";
  systemd.timers.dps-ea-bridge-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 10:00";
      Persistent = true;
    };
  };

  nic.services.${name} = {
    backup = [ "mnt-data" ];
    heavyUnits = [ ];

    public = {
      order   = 260;
      port    = 443;
      backend = "http://127.0.0.1:${toString port}";
      proxied = true;
      authenticated = true; # admin pages 404 to funnel; contact pages need their secret link
      muxPath = "/switch";
      tile = {
        name        = "Death Plan Switch";
        icon        = "mdi-timer-sand";
        category    = "Apps";
        description = "Dead man's switch";
        deepLink    = "/index.php?p=contacts";
      };
    };
  };
}
