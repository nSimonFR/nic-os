# rpi5/lib/socket-activate.nix
#
# Put HTTP services behind `systemd-socket-proxyd --exit-idle-time=` so they
# only run while traffic is flowing. Saves RSS on memory-pressured hosts.
#
# Lifecycle per service:
#   1. <name>-proxy.socket listens on cfg.listen (e.g. 127.0.0.1:3100).
#   2. First connection activates <name>-proxy.service.
#   3. <name>-proxy.service Requires/After realUnit (and an optional ready
#      probe), then exec systemd-socket-proxyd → cfg.backend.
#   4. After cfg.idleSec without an active connection, the proxy exits.
#   5. realUnit becomes unneeded (unitConfig.StopWhenUnneeded = true) and stops.
#   6. The socket re-arms; next connection repeats from step 2.
#
# v1 is intentionally constrained:
#   - exactly one `listen` entry per service (option type lifts later)
#   - no TLS, no warmupSchedule (option name reserved)
#   - workers may only specify policy = sleepWith | keepAwake
{ config, lib, pkgs, ... }:

let
  cfg = config.services.socketActivate;

  serviceModule = lib.types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkEnableOption "socket-activated idle-sleep for ${name}";

      realUnit = lib.mkOption {
        type = lib.types.str;
        description = ''
          systemd unit (with .service suffix) put behind the proxy. No default —
          half the targets here are not <name>.service (paperless-web,
          sure-web, …). Explicit > implicit.
        '';
        example = "forgejo.service";
      };

      listen = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          systemd ListenStream= specs. v1 accepts exactly one entry; the option
          shape stays a list so future versions can lift this without breaking
          existing configs.
        '';
        example = [ "127.0.0.1:3100" ];
      };

      backend = lib.mkOption {
        type = lib.types.str;
        description = ''
          Where systemd-socket-proxyd forwards. host:port for TCP, /path for
          a Unix socket. No "+1 from listen" convention — every service file
          is explicit about its bind change.
        '';
        example = "127.0.0.1:3101";
      };

      idleSec = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = 600;
        description = ''
          Seconds without an active connection before the proxy exits. null
          disables idle-stop entirely (lazy-start only; realUnit stays up
          once warm). Use null for auth-critical flows where a mid-session
          cold-start would break things.
        '';
      };

      readyProbe = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.str;
              description = "HTTP URL polled until ready (typically against the realUnit's bind).";
              example = "http://127.0.0.1:3101/up";
            };
            expectStatus = lib.mkOption {
              type = lib.types.int;
              default = 200;
              description = "HTTP status code that counts as ready.";
            };
            timeoutSec = lib.mkOption {
              type = lib.types.ints.positive;
              default = 60;
              description = "Total seconds to wait before failing the probe.";
            };
          };
        });
        default = null;
        description = ''
          Optional readiness gate inserted between the proxy and the realUnit.
          Required for Rails/Django/Sidekiq stacks whose listen socket binds
          ~30s after systemd considers the unit active. null = forward on
          first systemd "active" (fine for Go services).
        '';
      };

      workers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options.policy = lib.mkOption {
            type = lib.types.enum [ "sleepWith" "keepAwake" ];
            description = ''
              sleepWith → wantedBy = realUnit + partOf = realUnit. Worker
                          starts with the web tier and stops alongside it.
                          Use for Sidekiq / Celery queue workers.
              keepAwake → module emits nothing for the worker; existing
                          lifecycle preserved. Use for cron-like schedulers
                          (Celery beat) where missed ticks are unacceptable.
            '';
          };
        });
        default = {};
        description = ''
          Sibling systemd units associated with this service and their sleep
          policy. Keys are unit names with .service suffix.
        '';
        example = lib.literalExpression ''
          {
            "sure-worker.service".policy = "sleepWith";
          }
        '';
      };

      warmupSchedule = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          RESERVED for v2 — OnCalendar spec for predictable pre-warm curls.
          Not yet implemented; option name claimed so v2 stays backwards-
          compatible with v1 configs.
        '';
      };
    };
  });

  enabled = lib.filterAttrs (_: c: c.enable) cfg;

  unitKey = u: lib.removeSuffix ".service" u;

  proxyExec = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd";

  readyName = name: "${name}-ready";

  proxyService = name: c:
    let
      probeUnit = "${readyName name}.service";
      reqs = [ c.realUnit ] ++ lib.optional (c.readyProbe != null) probeUnit;
      idleFlag = lib.optionalString (c.idleSec != null) "--exit-idle-time=${toString c.idleSec}s ";
    in {
      description = "Socket-activation proxy for ${name} (→ ${c.realUnit})";
      requires = reqs;
      after    = reqs;
      serviceConfig = {
        ExecStart = "${proxyExec} ${idleFlag}${c.backend}";
        Restart = "no";
      };
    };

  proxySocket = name: c: {
    description = "Listening socket for ${name} (→ ${c.realUnit})";
    wantedBy = [ "sockets.target" ];
    listenStreams = c.listen;
    socketConfig = {
      Accept = false;
    };
  };

  readyService = name: c: {
    description = "Readiness probe for ${name} (${c.readyProbe.url})";
    requires = [ c.realUnit ];
    after    = [ c.realUnit ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "socket-activate-${name}-ready" ''
        set -eu
        deadline=$(( $(${pkgs.coreutils}/bin/date +%s) + ${toString c.readyProbe.timeoutSec} ))
        code=""
        while [ "$(${pkgs.coreutils}/bin/date +%s)" -lt "$deadline" ]; do
          code=$(${pkgs.curl}/bin/curl -sS -o /dev/null -w '%{http_code}' \
                 --max-time 5 ${lib.escapeShellArg c.readyProbe.url} 2>/dev/null || true)
          if [ "$code" = "${toString c.readyProbe.expectStatus}" ]; then
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
        echo "readyProbe ${name} timed out after ${toString c.readyProbe.timeoutSec}s (last code: $code)" >&2
        exit 1
      '';
    };
  };

in {
  options.services.socketActivate = lib.mkOption {
    type = lib.types.attrsOf serviceModule;
    default = {};
    description = ''
      Wrap HTTP services with systemd-socket-proxyd so they sleep when idle.
      See rpi5/lib/socket-activate.nix for the full lifecycle.
    '';
  };

  config = lib.mkIf (enabled != {}) {
    assertions = lib.mapAttrsToList (name: c: {
      assertion = builtins.length c.listen == 1;
      message = "services.socketActivate.${name}.listen must have exactly 1 entry in v1 (multi-listen is reserved for v2).";
    }) enabled;

    systemd.sockets = lib.mapAttrs'
      (name: c: lib.nameValuePair "${name}-proxy" (proxySocket name c))
      enabled;

    systemd.services = lib.mkMerge [
      # 1. Proxy services
      (lib.mapAttrs'
        (name: c: lib.nameValuePair "${name}-proxy" (proxyService name c))
        enabled)

      # 2. Ready-probe oneshot services
      (lib.mkMerge (lib.mapAttrsToList
        (name: c:
          lib.optionalAttrs (c.readyProbe != null) {
            ${readyName name} = readyService name c;
          })
        enabled))

      # 3. Real-unit patches: clear boot-time wantedBy; add StopWhenUnneeded
      #    when idle-stop is enabled.
      (lib.mkMerge (lib.mapAttrsToList
        (name: c: {
          ${unitKey c.realUnit} = lib.mkMerge [
            { wantedBy = lib.mkForce [ ]; }
            (lib.mkIf (c.idleSec != null) {
              unitConfig.StopWhenUnneeded = true;
            })
          ];
        })
        enabled))

      # 4. Worker patches: sleepWith → bound to realUnit's lifecycle.
      (lib.mkMerge (lib.concatMap
        (name:
          let c = enabled.${name}; in
          lib.mapAttrsToList
            (unit: w:
              if w.policy == "sleepWith" then {
                ${unitKey unit} = {
                  wantedBy = lib.mkForce [ c.realUnit ];
                  partOf   = [ c.realUnit ];
                  after    = [ c.realUnit ];
                };
              } else { })
            c.workers)
        (builtins.attrNames enabled)))
    ];
  };
}
