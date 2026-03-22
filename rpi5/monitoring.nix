{ config, lib, pkgs, telegramChatId, ... }:
let
  prometheusPort = 9090;
  grafanaPort    = 3000;

  # Fetch community dashboards at eval time (requires --impure or network sandbox).
  # IDs: node-exporter-full=1860, postgres=9628, redis=763, blocky=13768, scrutiny=20393
  fetchDashboard = id: name: builtins.fetchurl {
    url = "https://grafana.com/api/dashboards/${toString id}/revisions/latest/download";
    name = "${name}.json";
  };

  dashboardsDir = pkgs.linkFarm "grafana-dashboards" [
    { name = "node-exporter.json"; path = fetchDashboard 1860 "node-exporter"; }
    { name = "postgres.json";      path = fetchDashboard 9628 "postgres";      }
    { name = "redis.json";         path = fetchDashboard 763  "redis";         }
    { name = "blocky.json";        path = fetchDashboard 13768 "blocky";       }
    { name = "scrutiny.json";      path = fetchDashboard 20393 "scrutiny";     }
  ];

  alertRules = pkgs.writeText "alert-rules.yml" (builtins.toJSON {
    groups = [
      {
        name = "system";
        rules = [
          {
            alert = "InstanceDown";
            expr  = "up == 0";
            for   = "5m";
            labels.severity = "critical";
            annotations.summary = "Instance {{ $labels.instance }} is down";
          }
          {
            alert = "HighCpuLoad";
            expr  = "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > 85";
            for   = "5m";
            labels.severity = "warning";
            annotations.summary = "High CPU on {{ $labels.instance }}: {{ $value | printf \"%.1f\" }}%";
          }
          {
            alert = "HighMemoryUsage";
            expr  = "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90";
            for   = "5m";
            labels.severity = "warning";
            annotations.summary = "High memory on {{ $labels.instance }}: {{ $value | printf \"%.1f\" }}%";
          }
          {
            alert = "DiskAlmostFull";
            expr  = "(1 - (node_filesystem_avail_bytes{fstype!~\"tmpfs|devtmpfs|squashfs\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|devtmpfs|squashfs\"})) * 100 > 85";
            for   = "10m";
            labels.severity = "warning";
            annotations.summary = "Disk almost full on {{ $labels.instance }} ({{ $labels.mountpoint }}): {{ $value | printf \"%.1f\" }}%";
          }
          {
            alert = "ServiceDown";
            expr  = "probe_success == 0";
            for   = "5m";
            labels.severity = "critical";
            annotations.summary = "Service {{ $labels.instance }} is unreachable";
          }
          {
            alert = "HighLoadAverage";
            expr  = "node_load5 > 4";
            for   = "10m";
            labels.severity = "warning";
            annotations.summary = "High load average on {{ $labels.instance }}: {{ $value | printf \"%.2f\" }}";
          }
        ];
      }
    ];
  });
in
{
  # ── Prometheus ──────────────────────────────────────────────────────────────
  services.prometheus = {
    enable         = true;
    port           = prometheusPort;
    listenAddress  = "127.0.0.1";
    retentionTime  = "30d";

    globalConfig = {
      scrape_interval     = "15s";
      evaluation_interval = "15s";
    };

    ruleFiles = [ alertRules ];

    scrapeConfigs = [
      # Prometheus self-monitoring
      {
        job_name       = "prometheus";
        static_configs = [{ targets = [ "127.0.0.1:${toString prometheusPort}" ]; }];
      }
      # System metrics
      {
        job_name       = "node";
        static_configs = [{ targets = [ "127.0.0.1:9100" ]; }];
      }
      # Nginx
      {
        job_name       = "nginx";
        static_configs = [{ targets = [ "127.0.0.1:9113" ]; }];
      }
      # PostgreSQL (Ghostfolio)
      {
        job_name       = "postgres";
        static_configs = [{ targets = [ "127.0.0.1:9187" ]; }];
      }
      # Redis (Ghostfolio)
      {
        job_name       = "redis";
        static_configs = [{ targets = [ "127.0.0.1:9121" ]; }];
      }
      # Blocky DNS — already has a native /metrics endpoint on port 4000
      {
        job_name       = "blocky";
        static_configs = [{ targets = [ "127.0.0.1:4000" ]; }];
        metrics_path   = "/metrics";
      }
      # Scrutiny disk SMART
      {
        job_name       = "scrutiny";
        static_configs = [{ targets = [ "127.0.0.1:9099" ]; }];
        metrics_path   = "/api/metrics";
      }
      # Blackbox HTTP probes: up/down for services without native exporters
      {
        job_name     = "blackbox";
        metrics_path = "/probe";
        params       = { module = [ "http_2xx" ]; };
        static_configs = [{
          targets = [
            "http://127.0.0.1:8082"    # firefly-iii
            "http://127.0.0.1:13333"   # ghostfolio
            "http://127.0.0.1:8123"    # home-assistant
            "http://127.0.0.1:18789"   # openclaw
            "http://127.0.0.1:8081"    # truelayer2firefly
          ];
        }];
        relabel_configs = [
          { source_labels = [ "__address__" ]; target_label = "__param_target"; }
          { source_labels = [ "__param_target" ]; target_label = "instance"; }
          { target_label = "__address__"; replacement = "127.0.0.1:9115"; }
        ];
      }
    ];
  };

  # ── Exporters ───────────────────────────────────────────────────────────────
  services.prometheus.exporters = {
    # System: CPU, memory, disk, network, filesystem, systemd units
    node = {
      enable            = true;
      port              = 9100;
      listenAddress     = "127.0.0.1";
      enabledCollectors = [ "systemd" ]; # adds to the default set
    };

    # Nginx via stub_status (see nginx-portal.nix for the stub_status vhost on 9080)
    nginx = {
      enable        = true;
      port          = 9113;
      listenAddress = "127.0.0.1";
      scrapeUri     = "http://127.0.0.1:9080/nginx_status";
    };

    # PostgreSQL — run as the postgres OS user so peer auth works without a password
    postgres = {
      enable             = true;
      port               = 9187;
      listenAddress      = "127.0.0.1";
      runAsLocalSuperUser = true; # peer auth as postgres superuser; no extra role needed
    };

    # Redis (Ghostfolio instance on 6379)
    redis = {
      enable        = true;
      port          = 9121;
      listenAddress = "127.0.0.1";
      extraFlags    = [ "--redis.addr redis://127.0.0.1:6379" ];
    };

    # Blackbox: HTTP probes for services without native Prometheus endpoints
    blackbox = {
      enable        = true;
      port          = 9115;
      listenAddress = "127.0.0.1";
      configFile    = pkgs.writeText "blackbox.yml" ''
        modules:
          http_2xx:
            prober: http
            timeout: 10s
            http:
              valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
              valid_status_codes: []
              follow_redirects: true
              preferred_ip_protocol: "ip4"
      '';
    };
  };

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
        reporting_enabled  = false;
        check_for_updates  = false;
        check_for_plugin_updates = false;
      };
    };

    provision = {
      enable = true;

      # Auto-provision Prometheus as the default datasource
      datasources.settings = {
        apiVersion = 1;
        datasources = [{
          name      = "Prometheus";
          type      = "prometheus";
          url       = "http://127.0.0.1:${toString prometheusPort}";
          isDefault = true;
          access    = "proxy";
        }];
      };

      # Serve community dashboards from the Nix store (read-only, fetched at build time)
      dashboards.settings = {
        apiVersion = 1;
        providers = [{
          name                   = "community";
          orgId                  = 1;
          type                   = "file";
          disableDeletion        = true;
          updateIntervalSeconds  = 60;
          options.path           = toString dashboardsDir;
        }];
      };

      # Alerting: Telegram contact point with secrets injected via env vars at runtime
      alerting = {
        contactPoints.settings = {
          apiVersion = 1;
          contactPoints = [{
            orgId     = 1;
            name      = "telegram";
            receivers = [{
              uid  = "telegram-primary";
              type = "telegram";
              settings = {
                # $__env{VAR} is Grafana's env-var interpolation syntax for provisioning
                bottoken = "$__env{TELEGRAM_BOT_TOKEN}";
                chatid   = "$__env{TELEGRAM_CHAT_ID}";
                message  = ''
                  {{ len .Alerts.Firing }} firing / {{ len .Alerts.Resolved }} resolved
                  {{ range .Alerts }}• [{{ .Labels.severity | upper }}] {{ .Annotations.summary }}
                  {{ end }}'';
              };
            }];
          }];
        };

        # Route all alerts to Telegram
        policies.settings = {
          apiVersion = 1;
          policies = [{
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
  # The bot token comes from agenix (owned by root at this point);
  # the chat ID is a plain integer, not sensitive.
  # The (+) prefix runs this as root so it can read the agenix secret file.
  systemd.services.grafana.serviceConfig.ExecStartPre = lib.mkBefore [
    ("+${pkgs.writeShellScript "grafana-inject-telegram-secrets" ''
      token=$(< ${config.age.secrets.telegram-bot-token.path})
      printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CHAT_ID=%s\n' \
        "$token" "${toString telegramChatId}" \
        > /run/grafana/telegram.env
      # Mode 640 + group grafana: root owns the file, grafana can read it.
      chown root:grafana /run/grafana/telegram.env
      chmod 640 /run/grafana/telegram.env
    ''}")
  ];
  systemd.services.grafana.serviceConfig.EnvironmentFile = lib.mkAfter [
    "/run/grafana/telegram.env"
  ];
}
