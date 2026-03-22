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

  # Custom Fail2ban dashboard — uses textfile-collector metrics written by
  # the fail2ban-metrics systemd timer defined further below.
  # Custom Home Assistant dashboard — shows entity states from the HA Prometheus integration.
  # Requires bearer token at /etc/home-assistant/ha-api-token (see scrape config comment).
  haDashboard = pkgs.writeText "home-assistant.json" (builtins.toJSON {
    title   = "Home Assistant";
    uid     = "home-assistant-entities";
    tags    = [ "home-assistant" "iot" ];
    refresh = "30s";
    time    = { from = "now-24h"; to = "now"; };
    panels  = [
      # Sensor count stat
      { id = 1; type = "stat"; title = "Active Sensors";
        gridPos = { x=0; y=0; w=4; h=4; };
        datasource = { type = "prometheus"; uid = promUid; };
        options.colorMode = "none";
        options.reduceOptions.calcs = [ "lastNotNull" ];
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "count(homeassistant_sensor_state)";
          refId = "A"; instant = true; }];
      }
      # All numeric sensors over time
      { id = 2; type = "timeseries"; title = "Numeric Sensors";
        gridPos = { x=0; y=4; w=24; h=10; };
        datasource = { type = "prometheus"; uid = promUid; };
        options.tooltip.mode = "multi";
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "homeassistant_sensor_state";
          legendFormat = "{{friendly_name}} ({{unit_of_measurement}})";
          refId = "A"; }];
      }
      # Energy sensors (kWh) — Linky integration
      { id = 3; type = "timeseries"; title = "Energy Consumption (kWh)";
        gridPos = { x=0; y=14; w=24; h=10; };
        datasource = { type = "prometheus"; uid = promUid; };
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "homeassistant_sensor_state{unit_of_measurement=\"kWh\"}";
          legendFormat = "{{friendly_name}}";
          refId = "A"; }];
      }
      # Binary sensors table
      { id = 4; type = "table"; title = "Binary Sensor States";
        gridPos = { x=0; y=24; w=24; h=8; };
        datasource = { type = "prometheus"; uid = promUid; };
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "homeassistant_binary_sensor_state";
          refId = "A"; instant = true; format = "table"; }];
        transformations = [
          { id = "filterFieldsByName";
            options.include.names = [ "entity_id" "friendly_name" "Value" ]; }
          { id = "organize";
            options.renameByName = { entity_id = "Entity"; friendly_name = "Name"; Value = "State"; }; }
        ];
      }
    ];
    schemaVersion = 38;
  });

  fail2banDashboard = pkgs.writeText "fail2ban.json" (builtins.toJSON {
    title   = "Fail2ban";
    uid     = "fail2ban-security";
    tags    = [ "fail2ban" "security" ];
    refresh = "1m";
    time    = { from = "now-24h"; to = "now"; };
    panels  = [
      { id = 1; type = "stat"; title = "Currently Banned";
        gridPos = { x=0; y=0; w=6; h=4; };
        datasource = { type = "prometheus"; uid = promUid; };
        options.colorMode = "background";
        options.reduceOptions.calcs = [ "lastNotNull" ];
        fieldConfig.defaults.thresholds = {
          mode = "absolute";
          steps = [ { color = "green"; value = null; } { color = "orange"; value = 1; } { color = "red"; value = 5; } ];
        };
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "sum(fail2ban_banned_ips) or vector(0)"; refId = "A"; instant = true; }];
      }
      { id = 2; type = "stat"; title = "Total Banned (All Time)";
        gridPos = { x=6; y=0; w=6; h=4; };
        datasource = { type = "prometheus"; uid = promUid; };
        options.colorMode = "none";
        options.reduceOptions.calcs = [ "lastNotNull" ];
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "sum(fail2ban_total_banned) or vector(0)"; refId = "A"; instant = true; }];
      }
      { id = 3; type = "stat"; title = "Failed Attempts (Current)";
        gridPos = { x=12; y=0; w=6; h=4; };
        datasource = { type = "prometheus"; uid = promUid; };
        options.colorMode = "none";
        options.reduceOptions.calcs = [ "lastNotNull" ];
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "sum(fail2ban_failed_current) or vector(0)"; refId = "A"; instant = true; }];
      }
      { id = 4; type = "timeseries"; title = "Banned IPs Over Time";
        gridPos = { x=0; y=4; w=24; h=8; };
        datasource = { type = "prometheus"; uid = promUid; };
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "fail2ban_banned_ips"; legendFormat = "{{jail}}"; refId = "A"; }];
      }
      { id = 5; type = "timeseries"; title = "Failed Auth Rate (per 5 min)";
        gridPos = { x=0; y=12; w=24; h=8; };
        datasource = { type = "prometheus"; uid = promUid; };
        targets = [{ datasource = { type = "prometheus"; uid = promUid; };
          expr = "increase(fail2ban_total_failed[5m])"; legendFormat = "{{jail}}"; refId = "A"; }];
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
    { name = "grafana.json";       path = fetchDashboard 3590  "grafana";       }
    { name = "home-assistant.json"; path = haDashboard;                          }
    { name = "fail2ban.json";      path = fail2banDashboard;                    }
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
    # Disable build-time config validation: bearer_token_file for Home Assistant
    # points to a runtime secret that doesn't exist in the Nix build sandbox.
    checkConfig    = false;

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
      # Grafana self-monitoring (metrics enabled by default, no auth required on loopback)
      {
        job_name       = "grafana";
        static_configs = [{ targets = [ "127.0.0.1:${toString grafanaPort}" ]; }];
        metrics_path   = "/metrics";
      }
      # Home Assistant entity states (all sensors, binary sensors, etc.)
      # Requires a Long-Lived Access Token in bearer_token_file.
      # To create: HA UI → Profile → Security → Long-lived access tokens → Create token
      # Then: echo TOKEN | sudo tee /etc/home-assistant/ha-api-token && sudo chmod 640 /etc/home-assistant/ha-api-token
      {
        job_name          = "home_assistant";
        static_configs    = [{ targets = [ "127.0.0.1:8123" ]; }];
        metrics_path      = "/api/prometheus";
        bearer_token_file = "/etc/home-assistant/ha-api-token";
      }
      # Docker container metrics via cAdvisor
      {
        job_name       = "cadvisor";
        static_configs = [{ targets = [ "127.0.0.1:9338" ]; }];
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
      enabledCollectors = [ "systemd" "textfile" ]; # adds to the default set
      extraFlags        = [ "--collector.textfile.directory=/var/lib/node-exporter-textfile" ];
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

  # ── Textfile collector directory (for fail2ban and future scripts) ──────────
  # World-readable so the node_exporter DynamicUser can read .prom files;
  # root-owned so only privileged services can write here.
  # Also creates the HA bearer token placeholder so prometheus config validation passes at
  # build time (the Nix sandbox checks bearer_token_file existence).
  # Populate with the real token to activate HA scraping (see scrape config comment).
  systemd.tmpfiles.rules = [
    "d /var/lib/node-exporter-textfile 0755 root root -"
    "f /etc/home-assistant/ha-api-token 0640 root prometheus - -"
  ];

  # ── Fail2ban metrics (textfile collector) ───────────────────────────────────
  # Runs as root to query fail2ban's unix socket, writes metrics for node_exporter.
  systemd.services.fail2ban-metrics = {
    description = "Export fail2ban ban statistics for node_exporter";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "fail2ban-metrics" ''
        set -euo pipefail
        OUTFILE=/var/lib/node-exporter-textfile/fail2ban.prom
        TMP=$(mktemp)
        trap 'rm -f "$TMP"' EXIT
        {
          printf '# HELP fail2ban_banned_ips Currently banned IPs per jail\n'
          printf '# TYPE fail2ban_banned_ips gauge\n'
          printf '# HELP fail2ban_total_banned Total IPs ever banned per jail (cumulative)\n'
          printf '# TYPE fail2ban_total_banned counter\n'
          printf '# HELP fail2ban_failed_current Current failed auth attempts per jail\n'
          printf '# TYPE fail2ban_failed_current gauge\n'
          printf '# HELP fail2ban_total_failed Total failed auth attempts per jail (cumulative)\n'
          printf '# TYPE fail2ban_total_failed counter\n'
          for jail in $(${pkgs.fail2ban}/bin/fail2ban-client status \
                        | ${pkgs.gawk}/bin/awk -F: '/Jail list/{gsub(/[ \t]/,""); print $2}' \
                        | tr ',' '\n'); do
            status=$(${pkgs.fail2ban}/bin/fail2ban-client status "$jail" 2>/dev/null) || continue
            banned=$(printf '%s' "$status"       | ${pkgs.gawk}/bin/awk '/Currently banned/{print $NF}')
            total_banned=$(printf '%s' "$status" | ${pkgs.gawk}/bin/awk '/Total banned/{print $NF}')
            failed=$(printf '%s' "$status"       | ${pkgs.gawk}/bin/awk '/Currently failed/{print $NF}')
            total_failed=$(printf '%s' "$status" | ${pkgs.gawk}/bin/awk '/Total failed/{print $NF}')
            printf 'fail2ban_banned_ips{jail="%s"} %s\n'   "$jail" "''${banned:-0}"
            printf 'fail2ban_total_banned{jail="%s"} %s\n' "$jail" "''${total_banned:-0}"
            printf 'fail2ban_failed_current{jail="%s"} %s\n' "$jail" "''${failed:-0}"
            printf 'fail2ban_total_failed{jail="%s"} %s\n'   "$jail" "''${total_failed:-0}"
          done
        } > "$TMP"
        mv "$TMP" "$OUTFILE"
        chmod 644 "$OUTFILE"
      '';
    };
  };

  systemd.timers.fail2ban-metrics = {
    wantedBy  = [ "timers.target" ];
    timerConfig = {
      OnBootSec      = "30s";
      OnUnitActiveSec = "1m";
      Unit           = "fail2ban-metrics.service";
    };
  };

  # ── cAdvisor (Docker container metrics) ────────────────────────────────────
  # services.cadvisor is separate from prometheus.exporters.
  # Port 8080 (default) conflicts with nginx; use 9338 instead.
  services.cadvisor = {
    enable        = true;
    port          = 9338;
    listenAddress = "127.0.0.1";
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
    # PartOf ensures this service is stopped+restarted whenever grafana is restarted,
    # so the env file is always regenerated with a fresh token after agenix rotations.
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

  # grafana.service reads the env file prepared by grafana-secrets.service
  systemd.services.grafana = {
    after    = [ "grafana-secrets.service" ];
    requires = [ "grafana-secrets.service" ];
    serviceConfig.EnvironmentFile = "/run/grafana-telegram.env";
  };
}
