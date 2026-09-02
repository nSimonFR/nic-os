{ config, pkgs, lib, telegramChatId, ... }:
let
  beszelHubPort = 8090;
  beszelAgentPort = 45876;

  # Self-updating Telegram alerter. Usage:
  #   printf '%s' "$body" | ''${telegramAlert} <state-key> "<title>"
  # An empty body means "cleared". See shared/notify.nix for the seam and
  # hosts/rpi5/scripts/telegram-alert.sh for the send-once / edit-in-place / resolve
  # behaviour.
  telegramAlert = (import ../../shared/notify.nix { inherit pkgs; }).alert {
    tokenFile = config.age.secrets.telegram-bot-token.path;
    chatId = telegramChatId;
  };
in
{
  # ── Beszel Hub ───────────────────────────────────────────────────────────────
  systemd.services.beszel-hub = {
    description = "Beszel monitoring hub";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.beszel}/bin/beszel-hub serve --http 127.0.0.1:${toString beszelHubPort}";
      DynamicUser = true;
      StateDirectory = "beszel-hub";
      WorkingDirectory = "/var/lib/beszel-hub";
      Restart = "on-failure";
      RestartSec = "5s";
      Environment = [ "GOMAXPROCS=2" ];
    };
  };

  # ── Beszel Agent ─────────────────────────────────────────────────────────────
  systemd.services.beszel-agent = {
    description = "Beszel monitoring agent";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "beszel-hub.service" ];
    wants = [ "network-online.target" ];
    # smartctl on PATH so Beszel can collect SMART data from /dev/sda + /dev/sdb.
    path = [ pkgs.smartmontools ];
    unitConfig.ConditionPathExists = "/var/lib/beszel-hub/agent.env";
    serviceConfig = {
      ExecStart = "${pkgs.beszel}/bin/beszel-agent";
      DynamicUser = true;
      EnvironmentFile = "/var/lib/beszel-hub/agent.env";
      Restart = "on-failure";
      RestartSec = "10s";
      Environment = [
        "PORT=${toString beszelAgentPort}"
        "FILESYSTEM=/dev/sdb1,/dev/sdb2,/dev/sda1"
        "BESZEL_AGENT_PRIMARY_SENSOR=cpu_thermal"
        # Pin SMART devices (smartctl --scan confirms these types):
        #   /dev/sda — Hitachi HDD over USB-SATA bridge → SAT translation
        #   /dev/sdb — HP SSD EX900 (NVMe) in Realtek USB-NVMe enclosure → sntrealtek
        "SMART_DEVICES=/dev/sda:sat,/dev/sdb:sntrealtek"
        "SMART_INTERVAL=1h"
      ];
      ProtectProc = "default";
      # SMART access: CAP_SYS_RAWIO for SG_IO ioctls (SATA), CAP_SYS_ADMIN for
      # NVMe admin passthrough (none present today but cheap to have).
      # Ambient caps required because DynamicUser=true means beszel-agent runs
      # as an unprivileged user; bounding-set alone would be insufficient.
      AmbientCapabilities    = [ "CAP_SYS_RAWIO" "CAP_SYS_ADMIN" ];
      CapabilityBoundingSet  = [ "CAP_SYS_RAWIO" "CAP_SYS_ADMIN" ];
      # Allow read access to the raw block devices.
      DeviceAllow            = [ "/dev/sda r" "/dev/sdb r" ];
      SupplementaryGroups    = [ "disk" ];
    };
  };

  # ── Alert: systemd failed units ──────────────────────────────────────────────
  systemd.services.systemd-failed-alert = {
    description = "Alert on failed systemd units";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "systemd-failed-alert" ''
        # Three sources, because the system manager only knows about the first:
        # a failed USER unit is invisible to it (hermes-skill-promote failed
        # hourly for eight days unnoticed), and a user manager that is *stopped*
        # rather than failed is in neither list (that hid Hermes down for 31h).
        FAILED=$({
          ${pkgs.systemd}/bin/systemctl list-units --state=failed --no-legend
          ${pkgs.systemd}/bin/systemctl --machine=nsimon@.host --user list-units \
            --state=failed --no-legend 2>/dev/null | ${pkgs.gnused}/bin/sed 's/^/[user] /'
          ${pkgs.systemd}/bin/systemctl is-active --quiet user@1001.service \
            || echo "[user] user@1001.service NOT ACTIVE"
        })
        printf '%s' "$FAILED" | ${telegramAlert} systemd-failed "systemd units failed on rpi5"
      '';
    };
  };
  systemd.timers.systemd-failed-alert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "2m";
    };
  };

  # ── Alert: earlyoom kills ────────────────────────────────────────────────────
  systemd.services.earlyoom-alert = {
    description = "Alert on earlyoom OOM kills";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "earlyoom-alert" ''
        KILL_LINE=$(${pkgs.systemd}/bin/journalctl -u earlyoom --since=-3min --no-pager -q 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep "sending SIG" \
          | ${pkgs.coreutils}/bin/tail -n 1 || true)

        BODY=""
        if [ -n "$KILL_LINE" ]; then
          PROC=$(${pkgs.gnused}/bin/sed -n 's/.*process \([0-9]\+\).*"\([^"]\+\)".*/\2/p' <<< "$KILL_LINE")
          PID=$(${pkgs.gnused}/bin/sed -n 's/.*process \([0-9]\+\).*/\1/p' <<< "$KILL_LINE")
          RSS=$(${pkgs.gnused}/bin/sed -n 's/.*VmRSS \([0-9]\+ MiB\).*/\1/p' <<< "$KILL_LINE")
          CMD=$(${pkgs.gnused}/bin/sed -n 's/.*cmdline "\([^"]*\)".*/\1/p' <<< "$KILL_LINE" | ${pkgs.coreutils}/bin/cut -c1-160)

          if [ -n "$PROC" ]; then
            BODY="killed <code>$PROC</code>"
          else
            BODY="killed a process"
          fi
          [ -n "$PID" ] && BODY="$BODY
- pid: <code>$PID</code>"
          [ -n "$RSS" ] && BODY="$BODY
- rss: <code>$RSS</code>"
          [ -n "$CMD" ] && BODY="$BODY
- cmd: <code>$CMD</code>"
        fi

        printf '%s' "$BODY" | ${telegramAlert} earlyoom "earlyoom OOM kill on rpi5"
      '';
    };
  };
  systemd.timers.earlyoom-alert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "2m";
    };
  };

  # ── Alert: read-only filesystem ──────────────────────────────────────────────
  systemd.services.filesystem-ro-alert = {
    description = "Alert on read-only filesystems";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "filesystem-ro-alert" ''
        RO_FS=$(${pkgs.gnugrep}/bin/grep -E 'ext4|xfs|btrfs' /proc/mounts \
                | ${pkgs.gnugrep}/bin/grep -v '/nix/store' \
                | ${pkgs.gnugrep}/bin/grep ' ro[, ]' || true)
        BODY=""
        [ -n "$RO_FS" ] && BODY="<code>$RO_FS</code>"
        printf '%s' "$BODY" | ${telegramAlert} filesystem-ro "Read-only filesystem on rpi5"
      '';
    };
  };
  systemd.timers.filesystem-ro-alert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "5m";
    };
  };

  # ── Alert: Sure AutoCategorizeJob failures ───────────────────────────────────
  # Catches both known failure modes (LLM_CONTEXT_WINDOW too small, codex-proxy
  # OAuth expiry) plus anything else that makes the job error out — see
  # hosts/rpi5/sure.nix sureLlmEnv and the "Failed to auto-categorize" log line in
  # app/models/family#auto_categorize_transactions.
  systemd.services.sure-autocategorize-alert = {
    description = "Alert on Sure AutoCategorizeJob failures";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "sure-autocategorize-alert" ''
        FAILURES=$(${pkgs.systemd}/bin/journalctl -u sure-worker --since=-16min --no-pager -q 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep "Failed to auto-categorize" \
          | ${pkgs.coreutils}/bin/cut -c1-300 \
          | ${pkgs.coreutils}/bin/tail -n 5 || true)

        BODY=""
        [ -n "$FAILURES" ] && BODY="<code>$FAILURES</code>"
        printf '%s' "$BODY" | ${telegramAlert} sure-autocategorize "Sure auto-categorization failing on rpi5"
      '';
    };
  };
  systemd.timers.sure-autocategorize-alert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "15m";
    };
  };

  # ── Beszel SMART refresh (workaround for henrygd/beszel#1800) ───────────────
  # TODO(beszel#1800): DELETE THIS WHOLE BLOCK (service + timer) once Beszel
  #   0.19.0+ with a verified fix lands in nixpkgs and a natural background
  #   SMART fetch is observed in the hub _logs. Issue:
  #   https://github.com/henrygd/beszel/issues/1800
  #
  # Beszel 0.18.x's background SMART fetcher in update() doesn't reliably fire
  # on SMART_INTERVAL — data.Details.SmartInterval isn't transmitted over SSH
  # correctly, the hub falls back to a 1h default + cooldown that effectively
  # blocks subsequent fetches. The manual refresh endpoint bypasses the
  # cooldown and reliably populates `smart_devices`.
  #
  # IMPORTANT: `POST /api/beszel/smart/refresh` requires a regular `users`
  # token, not a `_superusers` token — the handler calls `system.HasUser(auth.Id)`
  # against the system's `users` field, which contains user IDs from the `users`
  # collection. A superuser ID is not in that field, so the handler returns 404
  # ("The requested resource wasn't found"). Workaround: auth as superuser, then
  # use PocketBase's impersonate endpoint to mint a token for the first regular
  # user that actually owns the systems.
  systemd.services.beszel-smart-refresh = {
    description = "Refresh Beszel SMART data for all systems (workaround for beszel#1800)";
    after = [ "beszel-hub.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "beszel-smart-refresh" ''
        set -eu
        CURL="${pkgs.curl}/bin/curl"
        JQ="${pkgs.jq}/bin/jq"
        HUB=http://127.0.0.1:${toString beszelHubPort}

        SU_TOKEN=$($CURL -sf -X POST "$HUB/api/collections/_superusers/auth-with-password" \
          -H 'Content-Type: application/json' \
          -d '{"identity":"homepage@nic-os.local","password":"homepage-widget-pass"}' \
          | $JQ -r .token)

        # Disable PocketBase's built-in "new login location" email alert on the
        # _superusers collection. Otherwise our hourly login triggers a sendmail
        # call that fails (no MTA configured) and logs a recordAuthResponse
        # error each run. Idempotent — safe to run every tick.
        $CURL -sf -X PATCH "$HUB/api/collections/_superusers" \
          -H "Authorization: $SU_TOKEN" -H 'Content-Type: application/json' \
          -d '{"authAlert":{"enabled":false}}' > /dev/null \
          && echo "authAlert disabled on _superusers" \
          || echo "WARN: failed to disable authAlert" >&2

        # Pick the first regular user and impersonate them so the refresh
        # handler's HasUser check passes (see comment block above).
        USER_ID=$($CURL -sf -H "Authorization: $SU_TOKEN" \
          "$HUB/api/collections/users/records?perPage=1&fields=id" \
          | $JQ -r '.items[0].id // empty')
        if [ -z "$USER_ID" ]; then
          echo "ERROR: no regular user found in users collection — cannot refresh SMART" >&2
          exit 1
        fi
        USER_TOKEN=$($CURL -sf -X POST -H "Authorization: $SU_TOKEN" \
          -H 'Content-Type: application/json' -d '{"duration":3600}' \
          "$HUB/api/collections/users/impersonate/$USER_ID" \
          | $JQ -r .token)

        # Iterate over every registered system and kick its manual SMART refresh.
        SYSTEMS=$($CURL -sf -H "Authorization: $SU_TOKEN" \
          "$HUB/api/collections/systems/records?perPage=100&fields=id,name,status" \
          | $JQ -r '.items[] | select(.status=="up") | .id')

        for id in $SYSTEMS; do
          $CURL -sf -X POST -H "Authorization: $USER_TOKEN" \
            "$HUB/api/beszel/smart/refresh?system=$id" > /dev/null \
            && echo "refreshed SMART for system=$id" \
            || echo "WARN: refresh failed for system=$id" >&2
        done
      '';
    };
  };
  systemd.timers.beszel-smart-refresh = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Wait 3m after boot so beszel-hub has time to accept the initial SSH
      # handshake from beszel-agent and populate the systems list.
      OnBootSec = "3m";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  # Beszel's public face lived in services-registry.nix while its state never
  # answered the backup question at all — this closes both.
  nic.services.beszel = {
    backup     = [ "none" ];
    backupNote =
      "monitoring history only. The PocketBase DB sits under "
      + "/var/lib/private/beszel-hub (DynamicUser + StateDirectory), outside "
      + "restic's /mnt/data scope, and is deliberately not dumped: a fresh hub "
      + "re-registers the agent and starts collecting again.";
    # Not in the heavy list today, and left that way here so this registration
    # changes no behaviour. The hub idles small; the agent must keep running to
    # collect during a rebuild anyway.
    heavyUnits = [ ];

    public = {
      order   = 140;
      port    = 3000;
      backend = "http://127.0.0.1:${toString beszelHubPort}";
      tile = {
        name        = "Beszel";
        icon        = "beszel.svg";
        category    = "Apps";
        description = "System monitoring";
        # Was the native `beszel` widget, which needed a Beszel superuser password
        # in plaintext in the registry (and could only render two stats without
        # pinning the tile to one systemId). The aggregator reads Beszel's
        # PocketBase SQLite read-only instead — the homepage@nic-os.local
        # superuser created above is no longer used by this tile.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/beszel";
          refreshInterval = 3600000;
          # `Systems` was a 2 fixed by the fleet being rpi5 + beast, so it went in
          # favour of the hottest the CPU has been in 24h. Beszel samples
          # cpu_thermal every minute already and the dashboard never showed it,
          # which on a Pi 5 whose documented failure mode is thermal throttling
          # into an OOM/watchdog reset is the wrong thing to omit. `Up` still
          # carries the fleet size implicitly — it reads 1 whenever beast is
          # suspended, which is normal and most of the time.
          mappings = [
            { field = "up";        label = "Up";        format = "number"; }
            { field = "alerts";    label = "Alerts";    format = "number"; }
            # float + suffix, not `number`: this carries a decimal (56.0 °C) and
            # `number` would drop it — same reason freereps' km/kg are floats.
            { field = "peak_temp"; label = "Peak 24h";  format = "float"; suffix = " °C"; }
          ];
        };
      };
    };
  };
}
