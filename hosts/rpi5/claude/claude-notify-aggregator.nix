# Central debounced Telegram notifier for agent notifications.
#
# All agent notification hooks across every machine (Claude Code `Notification`
# hook + Pi `agent_end` extension, on rpi5/BeAsT/nBookPro) POST to this service
# over the tailnet. It pools them into one shared stream and sends a single
# Telegram digest only after a quiet period (or at most every MAX seconds),
# replacing the old per-machine /tmp coalescing that fired immediately and
# spammed thousands of messages a day. See the `claude-notify-aggregator`
# entry point of the nicos-scripts package (hosts/rpi5/scripts/lib/).
#
# Bound to 127.0.0.1:8088; exposed tailnet-wide via Tailscale Serve
# (nic.services.claude-notify below — no tile, so nothing renders on the
# dashboard).
{
  pkgs,
  telegramChatId,
  ...
}:
{
  systemd.services.claude-notify-aggregator = {
    description = "Debounced Telegram notifier for Claude/Pi agent notifications (:8088)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "on-failure";
      RestartSec = "10s";
      # Runs as root to read the root-owned /run/agenix/telegram-bot-token,
      # matching the monitoring.nix alert timers.
      ExecStart = "${pkgs.nicos-scripts}/bin/claude-notify-aggregator";
      NoNewPrivileges = true;
      ProtectHome = true;
      Environment = [
        "NOTIFY_PORT=8088"
        "NOTIFY_QUIET_SECONDS=300"
        "NOTIFY_MAX_SECONDS=900"
        "NOTIFY_CHAT_ID=${builtins.toString telegramChatId}"
        "NOTIFY_TOKEN_PATH=/run/agenix/telegram-bot-token"
      ];
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.claude-notify = {
    backup     = [ "none" ];
    backupNote =
      "no persistent state — the debounce pool is in memory, and a restart at "
      + "worst drops one pending digest";
    heavyUnits = [ ];

    # No tile: an ingest endpoint for agent hooks, nothing to visit.
    public = {
      order   = 260;
      port    = 8088;
      backend = "http://127.0.0.1:8088";
    };
  };
}
