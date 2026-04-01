{ pkgs, ... }:
let
  # Prometheus datasource UID — set by the provisioned datasource in grafana.nix.
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
    raw = raw.replace("''${VAR_BLOCKY_URL}", "http://localhost:4000")  # must match blocky.nix ports.http

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
    { name = "disk.json";           path = fetchDashboard 9852  "disk";          }
    { name = "systemd.json";        path = ./dashboards/systemd.json;            }
    { name = "home-assistant.json"; path = ./dashboards/home-assistant.json;     }
    { name = "fail2ban.json";       path = ./dashboards/fail2ban.json;           }
  ];
in
{
  imports = [
    ./prometheus.nix
    ./fail2ban.nix
    ./earlyoom.nix
    ./grafana.nix
  ];

  services.prometheus.ruleFiles = [ ./alert-rules.yml ];

  _module.args.dashboardsDir = dashboardsDir;
}
