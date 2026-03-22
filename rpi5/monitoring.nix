{ config, lib, pkgs, telegramChatId, ... }:
let
  prometheusPort = 9090;
  grafanaPort    = 3000;

  # Prometheus datasource UID — set by the provisioned datasource in this file.
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

  # Custom systemd services dashboard — shows failed/active/inactive unit counts
  # and a sortable table of all service units with colour-coded state.
  systemdDashboard = pkgs.writeText "systemd.json" (builtins.toJSON {
    title   = "Systemd Services";
    uid     = "systemd-services";
    tags    = [ "systemd" "linux" ];
    refresh = "30s";
    time    = { from = "now-1h"; to = "now"; };
    panels  = [
      # Row 1: stat panels for failed / active / inactive counts
      {
        id = 1; type = "stat"; title = "Failed Services"; gridPos = { x=0; y=0; w=4; h=4; };
        datasource = { type = "prometheus"; uid = promUid; };
        options.colorMode = "background";
        options.reduceOptions.calcs = [ "lastNotNull" ];
        fieldConfig.defaults.thresholds = {
          mode = "absolute";
          steps = [ { color = "green"; value = null; } { color = "red"; value = 1; } ];
        };
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "count(node_systemd_unit_state{state=\"failed\"} == 1) or vector(0)";
          refId = "A"; instant = true; }];
      }
      {
        id = 2; type = "stat"; title = "Active Services"; gridPos = { x=4; y=0; w=4; h=4; };
        datasource = { type = "prometheus"; uid = promUid; };
        options.colorMode = "background";
        options.reduceOptions.calcs = [ "lastNotNull" ];
        fieldConfig.defaults.color = { mode = "fixed"; fixedColor = "green"; };
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "count(node_systemd_unit_state{state=\"active\"} == 1)";
          refId = "A"; instant = true; }];
      }
      {
        id = 3; type = "stat"; title = "Inactive Services"; gridPos = { x=8; y=0; w=4; h=4; };
        datasource = { type = "prometheus"; uid = promUid; };
        options.colorMode = "background";
        options.reduceOptions.calcs = [ "lastNotNull" ];
        fieldConfig.defaults.color = { mode = "fixed"; fixedColor = "blue"; };
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "count(node_systemd_unit_state{state=\"inactive\"} == 1)";
          refId = "A"; instant = true; }];
      }
      # Row 2: failed services list (prominent, always visible)
      {
        id = 4; type = "table"; title = "Failed Services";
        gridPos = { x=0; y=4; w=24; h=6; };
        datasource = { type = "prometheus"; uid = promUid; };
        options.sortBy = [{ displayName = "Unit"; desc = false; }];
        fieldConfig.overrides = [{
          matcher = { id = "byName"; options = "State"; };
          properties = [{ id = "custom.displayMode"; value = "color-background"; }
                        { id = "color"; value = { mode = "fixed"; fixedColor = "red"; }; }];
        }];
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "node_systemd_unit_state{state=\"failed\"} == 1";
          refId = "A"; instant = true;
          format = "table"; }];
        transformations = [
          { id = "filterFieldsByName";
            options.include.names = [ "name" "type" "Value" ]; }
          { id = "organize";
            options.renameByName = { name = "Unit"; type = "Type"; Value = "State"; }; }
        ];
      }
      # Row 3: all service units table
      {
        id = 5; type = "table"; title = "All Service Units";
        gridPos = { x=0; y=10; w=24; h=16; };
        datasource = { type = "prometheus"; uid = promUid; };
        options.sortBy = [{ displayName = "State"; desc = false; }];
        fieldConfig.overrides = [
          { matcher = { id = "byName"; options = "active"; };
            properties = [{ id = "custom.displayMode"; value = "color-background"; }
                          { id = "color"; value = { mode = "fixed"; fixedColor = "green"; }; }]; }
          { matcher = { id = "byName"; options = "failed"; };
            properties = [{ id = "custom.displayMode"; value = "color-background"; }
                          { id = "color"; value = { mode = "fixed"; fixedColor = "red"; }; }]; }
        ];
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "node_systemd_unit_state{type=\"service\"} == 1";
          refId = "A"; instant = true;
          format = "table"; }];
        transformations = [
          { id = "filterFieldsByName";
            options.include.names = [ "name" "state" "Value" ]; }
          { id = "organize";
            options.renameByName = { name = "Unit"; state = "State"; }; }
        ];
      }
    ];
    schemaVersion = 38;
  });

  dashboardsDir = pkgs.linkFarm "grafana-dashboards" [
    { name = "node-exporter.json"; path = fetchDashboard 1860  "node-exporter"; }
    { name = "postgres.json";      path = fetchDashboard 9628  "postgres";      }
    { name = "redis.json";         path = fetchDashboard 763   "redis";         }
    { name = "blocky.json";        path = fetchDashboard 13768 "blocky";        }
    { name = "blackbox.json";      path = fetchDashboard 7587  "blackbox";      }
    { name = "nginx.json";         path = fetchDashboard 12708 "nginx";         }
    { name = "rpi-docker.json";    path = fetchDashboard 15120 "rpi-docker";    }
    { name = "disk.json";          path = fetchDashboard 9852  "disk";          }
    { name = "systemd.json";       path = systemdDashboard;                     }
  ];

  alertRules = pkgs.writeText "alert-rules.yml" (builtins.toJSON {
    groups = [
      {
        name = "system";
        rules = [
          # ── Availability ──────────────────────────────────────────────────
          {
            alert = "InstanceDown";
            expr  = "up == 0";
            for   = "5m";
            labels.severity = "critical";
            annotations.summary = "Prometheus target {{ $labels.instance }} is down";
          }
          {
            alert = "ServiceDown";
            expr  = "probe_success == 0";
            for   = "5m";
            labels.severity = "critical";
            annotations.summary = "Service {{ $labels.instance }} is unreachable";
          }
          {
            alert = "ServiceSlowResponse";
            expr  = "probe_duration_seconds > 5";
            for   = "5m";
            labels.severity = "warning";
            annotations.summary = "Service {{ $labels.instance }} responding slowly ({{ $value | printf \"%.1f\" }}s)";
          }
          # ── Systemd ───────────────────────────────────────────────────────
          {
            alert = "SystemdUnitFailed";
            expr  = "node_systemd_unit_state{state=\"failed\"} == 1";
            for   = "2m";
            labels.severity = "critical";
            annotations.summary = "Systemd unit {{ $labels.name }} is in failed state";
          }
          # ── CPU / Load ────────────────────────────────────────────────────
          {
            alert = "HighCpuLoad";
            expr  = "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > 85";
            for   = "5m";
            labels.severity = "warning";
            annotations.summary = "High CPU on {{ $labels.instance }}: {{ $value | printf \"%.1f\" }}%";
          }
          {
            alert = "HighLoadAverage";
            expr  = "node_load5 > 4";
            for   = "10m";
            labels.severity = "warning";
            annotations.summary = "High 5m load on {{ $labels.instance }}: {{ $value | printf \"%.2f\" }}";
          }
          # ── Memory ───────────────────────────────────────────────────────
          {
            alert = "HighMemoryUsage";
            expr  = "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90";
            for   = "5m";
            labels.severity = "warning";
            annotations.summary = "High memory on {{ $labels.instance }}: {{ $value | printf \"%.1f\" }}%";
          }
          # ── Disk ─────────────────────────────────────────────────────────
          {
            alert = "DiskAlmostFull";
            expr  = "(1 - (node_filesystem_avail_bytes{fstype!~\"tmpfs|devtmpfs|squashfs\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|devtmpfs|squashfs\"})) * 100 > 85";
            for   = "10m";
            labels.severity = "warning";
            annotations.summary = "Disk almost full on {{ $labels.instance }} ({{ $labels.mountpoint }}): {{ $value | printf \"%.1f\" }}%";
          }
          {
            alert = "DiskCritical";
            expr  = "(1 - (node_filesystem_avail_bytes{fstype!~\"tmpfs|devtmpfs|squashfs\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|devtmpfs|squashfs\"})) * 100 > 95";
            for   = "5m";
            labels.severity = "critical";
            annotations.summary = "Disk critically full on {{ $labels.instance }} ({{ $labels.mountpoint }}): {{ $value | printf \"%.1f\" }}%";
          }
          {
            alert = "FilesystemReadOnly";
            expr  = "node_filesystem_readonly{fstype!~\"tmpfs|devtmpfs|squashfs|iso9660\"} == 1";
            for   = "5m";
            labels.severity = "critical";
            annotations.summary = "Filesystem {{ $labels.mountpoint }} is read-only on {{ $labels.instance }} (possible corruption)";
          }
          # ── RAID ─────────────────────────────────────────────────────────
          {
            alert = "RAIDDegraded";
            expr  = "node_md_disks_active < node_md_disks";
            for   = "5m";
            labels.severity = "critical";
            annotations.summary = "RAID array {{ $labels.device }} is degraded: {{ $value }} of {{ printf `node_md_disks{device=\"%s\"}` $labels.device | query | first | value }} disks active";
          }
          # ── Temperature (RPi5) ───────────────────────────────────────────
          {
            alert = "HighCpuTemperature";
            expr  = "node_hwmon_temp_celsius{chip=~\".*thermal.*\",sensor=\"temp1\"} > 75";
            for   = "5m";
            labels.severity = "warning";
            annotations.summary = "RPi5 CPU temperature high: {{ $value | printf \"%.1f\" }}°C";
          }
          {
            alert = "CriticalCpuTemperature";
            expr  = "node_hwmon_temp_celsius{chip=~\".*thermal.*\",sensor=\"temp1\"} > 85";
            for   = "2m";
            labels.severity = "critical";
            annotations.summary = "RPi5 CPU temperature critical: {{ $value | printf \"%.1f\" }}°C — throttling imminent";
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
            "http://127.0.0.1:18789/health"   # openclaw
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
  # systemd loads EnvironmentFile before ExecStartPre runs, so the env file
  # must be created by a separate prerequisite oneshot service.
  # grafana-secrets: write the bot token to a file outside grafana's RuntimeDirectory.
  # grafana's RuntimeDirectory (/run/grafana) is cleaned up on every stop, so we use
  # /run/grafana-telegram.env instead. Without RemainAfterExit, the service goes
  # inactive after each run and systemd re-runs it whenever grafana (re)starts.
  systemd.services.grafana-secrets = {
    description = "Prepare Grafana secret environment file";
    before      = [ "grafana.service" ];
    wantedBy    = [ "grafana.service" ];
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

  # grafana.service reads the env file prepared by grafana-secrets.service
  systemd.services.grafana = {
    after    = [ "grafana-secrets.service" ];
    requires = [ "grafana-secrets.service" ];
    serviceConfig.EnvironmentFile = "/run/grafana-telegram.env";
  };
}
