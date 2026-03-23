{ config, lib, pkgs, telegramChatId, ... }:
let
  grafanaPort = 3000;

  # Prometheus datasource UID — set by the provisioned datasource below.
  promUid = "PBFA97CFB590B2093";

  # Fetch a community dashboard and patch it for standalone (non-Kubernetes) use:
  # - Replace ${DS_PROM}/${DS_PROMETHEUS} datasource placeholders with the real UID
  # - Replace ${VAR_BLOCKY_URL} with the local Blocky API URL
  # - Hide the 'pod' variable (Kubernetes label absent on standalone) and default to .*
  patchScript = pkgs.writeText "patch-dashboard.py" ''
    import json, sys, re

    uid   = sys.argv[2]
    raw   = open(sys.argv[1]).read()

    # Replace any datasource placeholder (DS_PROM, DS_PROMETHEUS, DS_SIGNCL-PROMETHEUS, etc.)
    raw = re.sub(r'\$\{DS_[^}]+\}', uid, raw)
    raw = raw.replace("''${VAR_BLOCKY_URL}", "http://localhost:4000")

    d = json.loads(raw)

    # Hide pod/namespace Kubernetes variables and set a catch-all default
    for v in d.get("templating", {}).get("list", []):
        if v.get("name") in ("pod", "namespace"):
            v["hide"]    = 2        # 2 = hidden from UI
            v["current"] = {"selected": True, "text": "All", "value": ".*"}
            v["options"] = [{"selected": True, "text": "All", "value": ".*"}]

    print(json.dumps(d))
  '';

  fetchDashboard = id: name:
    let
      raw = builtins.fetchurl {
        url = "https://grafana.com/api/dashboards/${toString id}/revisions/latest/download";
        name = "${name}-raw.json";
      };
    in
    pkgs.runCommand "${name}.json" { } ''
      ${pkgs.python3}/bin/python3 ${patchScript} ${raw} ${promUid} > $out
    '';

  dashboardsDir = pkgs.linkFarm "grafana-dashboards" [
    { name = "node-exporter.json";  path = fetchDashboard 1860  "node-exporter"; }
    { name = "postgres.json";       path = fetchDashboard 9628  "postgres";      }
    { name = "redis.json";          path = fetchDashboard 763   "redis";         }
    { name = "blocky.json";         path = fetchDashboard 13768 "blocky";        }
    { name = "blackbox.json";       path = fetchDashboard 7587  "blackbox";      }
    { name = "nginx.json";          path = fetchDashboard 12708 "nginx";         }
    { name = "rpi-docker.json";     path = fetchDashboard 15120 "rpi-docker";    }
    { name = "disk.json";           path = fetchDashboard 9852  "disk";          }
    { name = "systemd.json";        path = ./dashboards/systemd.json;            }
    { name = "home-assistant.json"; path = ./dashboards/home-assistant.json;     }
    { name = "fail2ban.json";       path = ./dashboards/fail2ban.json;           }
  ];
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
