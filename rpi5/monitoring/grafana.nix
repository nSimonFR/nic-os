{ config, pkgs, telegramChatId, dashboardsDir, ... }:
let
  grafanaPort = 3000;
in
{
  # ── Grafana ─────────────────────────────────────────────────────────────────
  services.grafana = {
    enable = true;

    settings = {
      server = {
        # Bind to loopback only — Tailscale Serve handles the external HTTPS.
        http_addr = "127.0.0.1";
        http_port = grafanaPort;
        domain    = "rpi5";
        root_url  = "https://rpi5:${toString grafanaPort}/";
      };
      analytics = {
        reporting_enabled        = false;
        check_for_updates        = false;
        check_for_plugin_updates = false;
      };
    };

    provision = {
      enable = true;

      datasources.settings = {
        apiVersion  = 1;
        datasources = [{
          name      = "Prometheus";
          type      = "prometheus";
          url       = "http://127.0.0.1:${toString config.services.prometheus.port}";
          isDefault = true;
          access    = "proxy";
        }];
      };

      dashboards.settings = {
        apiVersion = 1;
        providers  = [{
          name                  = "community";
          orgId                 = 1;
          type                  = "file";
          disableDeletion       = true;
          updateIntervalSeconds = 60;
          options.path          = toString dashboardsDir;
        }];
      };

      alerting = {
        contactPoints.settings = {
          apiVersion    = 1;
          contactPoints = [{
            orgId     = 1;
            name      = "telegram";
            receivers = [{
              uid  = "telegram-primary";
              type = "telegram";
              settings = {
                # $__env{VAR} is Grafana's env-var interpolation syntax for provisioning.
                # chatid is a plain integer in flake.nix; not sensitive — embed directly.
                # Providing it as a Nix string ensures remarshal/ruamel.yaml quotes it,
                # preventing YAML from misinterpreting the numeric value as an integer
                # (which would cause Grafana's Go unmarshal to fail on a string field).
                bottoken = "$__env{TELEGRAM_BOT_TOKEN}";
                chatid   = toString telegramChatId;
                message  = ''
                  {{ len .Alerts.Firing }} firing / {{ len .Alerts.Resolved }} resolved
                  {{ range .Alerts }}• [{{ .Labels.severity | upper }}] {{ .Annotations.summary }}
                  {{ end }}'';
              };
            }];
          }];
        };

        policies.settings = {
          apiVersion = 1;
          policies   = [{
            orgId             = 1;
            receiver          = "telegram";
            group_by          = [ "alertname" "instance" ];
            group_wait        = "30s";
            group_interval    = "5m";
            repeat_interval   = "4h";
          }];
        };
      };
    };
  };

  # Inject Telegram secrets into Grafana before it starts.
  # Without RemainAfterExit the service goes inactive after each run;
  # partOf ensures it is stopped+restarted whenever grafana (re)starts,
  # so the env file is always regenerated with the current agenix secret.
  systemd.services.grafana-secrets = {
    description = "Prepare Grafana secret environment file";
    before      = [ "grafana.service" ];
    wantedBy    = [ "grafana.service" ];
    partOf      = [ "grafana.service" ];
    serviceConfig = {
      Type = "oneshot";
      # (+) runs as root to read the agenix secret
      ExecStart = "+${pkgs.writeShellScript "grafana-inject-telegram-secrets" ''
        token=$(< ${config.age.secrets.telegram-bot-token.path})
        printf 'TELEGRAM_BOT_TOKEN=%s\n' "$token" > /run/grafana-telegram.env
        chown root:grafana /run/grafana-telegram.env
        chmod 640 /run/grafana-telegram.env
      ''}";
    };
  };

  systemd.services.grafana = {
    after    = [ "grafana-secrets.service" ];
    requires = [ "grafana-secrets.service" ];
    serviceConfig.EnvironmentFile = "/run/grafana-telegram.env";
  };
}
