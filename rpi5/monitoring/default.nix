{ pkgs, ... }:
let
  # Prometheus datasource UID — set by the provisioned datasource in grafana.nix.
  promUid = "PBFA97CFB590B2093";

  # Patch a community dashboard (stored as *-raw.json) for standalone (non-Kubernetes) use:
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

  patchDashboard = name:
    pkgs.runCommand "${name}.json" { } ''
      ${pkgs.python3}/bin/python3 ${patchScript} ${./dashboards/${name}-raw.json} ${promUid} > $out
    '';

  dashboardsDir = pkgs.linkFarm "grafana-dashboards" [
    { name = "node-exporter.json";  path = patchDashboard "node-exporter"; }
    { name = "postgres.json";       path = patchDashboard "postgres";      }
    { name = "redis.json";          path = patchDashboard "redis";         }
    { name = "blocky.json";         path = patchDashboard "blocky";        }
    { name = "blackbox.json";       path = patchDashboard "blackbox";      }
    { name = "nginx.json";          path = patchDashboard "nginx";         }
    { name = "disk.json";           path = patchDashboard "disk";          }
    { name = "systemd.json";        path = ./dashboards/systemd.json;            }
    { name = "home-assistant.json"; path = ./dashboards/home-assistant.json;     }
  ];
in
{
  imports = [
    ./prometheus.nix
    ./earlyoom.nix
    ./grafana.nix
  ];

  services.prometheus.ruleFiles = [ ./alert-rules.yml ];

  _module.args.dashboardsDir = dashboardsDir;
}
