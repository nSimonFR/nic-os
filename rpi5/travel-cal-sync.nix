# Event-driven travel-booking → Nextcloud calendar sync.
#
# A persistent daemon (scripts/travel-cal-sync.py) reads Proton over the local
# hydroxide IMAP bridge (same creds as papra-proton-poll), detects travel
# bookings with the local tiny-llm-gate, and writes each as a VEVENT into a
# Nextcloud calendar over CalDAV. It holds an IMAP IDLE connection, so a new
# booking lands on the calendar within minutes of arriving — no polling timer.
# Each booking has a stable UID, so the PUT is idempotent (no duplicates).
#
# Runs as root (like papra-proton-poll) so it can read all three secrets:
#   /run/agenix/protonmail-bridge-password   (Proton IMAP, hydroxide:hydroxide 0440)
#   /run/agenix/nextcloud-homepage-password  (Nextcloud app-password, reused; nsimon 0400)
#   /run/agenix/telegram-bot-token           (summary alerts, nsimon:for-sure 0440)
# No new secret: the existing Nextcloud app-password (also used by the homepage
# dashboard widget) is a full user token, so it authenticates CalDAV writes too.
# The mailbox is opened read-only and never mutated. Crash-loops surface via the
# existing systemd-failed Telegram alert in monitoring.nix.
{ pkgs, telegramChatId, tinyLlmGateUrl, tailnetFqdn, ... }:
{
  systemd.services.travel-cal-sync = {
    description = "Event-driven Proton -> Nextcloud travel-booking calendar sync";
    wantedBy = [ "multi-user.target" ];
    after = [ "hydroxide.service" "network-online.target" ];
    wants = [ "hydroxide.service" "network-online.target" ];
    path = [ pkgs.python3 ];
    environment = {
      TINY_LLM_GATE_URL = tinyLlmGateUrl;
      # Local-only extraction: pin to a local model (runs on the beast GPU host,
      # stays on-prem) rather than `auto`, which could fall back to a cloud model.
      # Booking emails (addresses, names) therefore never leave your hardware.
      # e4b (not 26b): 26b is a slow reasoning model — poor fit for a per-email
      # daemon; e4b is fast and extracts these bookings correctly.
      MODEL = "gemma4:e4b";
      LOOKBACK_DAYS = "365";
      TELEGRAM_CHAT_ID = toString telegramChatId;
      NEXTCLOUD_CALDAV_URL = "https://${tailnetFqdn}/nextcloud/remote.php/dav/calendars/nsimon/";
      NEXTCLOUD_PASS_FILE = "/run/agenix/nextcloud-homepage-password";
      # Calendar collection URI to write into (from `--list-calendars`): "Personal".
      NEXTCLOUD_CAL = "personal";
    };
    serviceConfig = {
      Type = "simple";
      User = "root";
      Restart = "always";
      RestartSec = 30;
      StateDirectory = "travel-cal-sync"; # -> /var/lib/travel-cal-sync
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/travel-cal-sync.py}";
    };
  };
}
