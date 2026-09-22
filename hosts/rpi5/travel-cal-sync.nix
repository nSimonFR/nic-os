# Event-driven travel-booking → Nextcloud calendar sync.
#
# A persistent daemon (the `travel-cal-sync` entry point of the nicos-scripts
# package, hosts/rpi5/scripts/lib/) reads Proton over the local
# hydroxide IMAP bridge (same creds as papra-proton-poll), detects travel
# bookings through tiny-llm-gate, and writes each as a VEVENT into a
# Nextcloud calendar over CalDAV. It holds an IMAP IDLE connection, so a new
# booking lands on the calendar within minutes of arriving — no polling timer.
# Each booking has a stable UID, so the PUT is idempotent (no duplicates).
#
# It also files document attachments into Papra's ingestion drop-zone: a trip's
# tickets and vouchers, and any other mail whose PDF a second LLM call judges
# worth keeping (invoices, payslips, tax: yes; brochures: no).
#
# Runs as root (like papra-proton-poll) so it can read all three secrets:
#   /run/agenix/protonmail-bridge-password   (Proton IMAP, hydroxide:hydroxide 0440)
#   /run/agenix/nextcloud-homepage-password  (Nextcloud app-password, reused; nsimon 0400)
#   /run/agenix/telegram-bot-token           (summary alerts, nsimon:for-sure 0440)
# No new secret: the existing Nextcloud app-password (also used by the homepage
# dashboard widget) is a full user token, so it authenticates CalDAV writes too.
# The mailbox is opened read-only and never mutated. Crash-loops surface via the
# existing systemd-failed Telegram alert in monitoring.nix.
{ config, pkgs, telegramChatId, tinyLlmGateUrl, tailnetFqdn, ... }:
let
  # One-shot seam (shared/notify.nix): a booking summary is an event, not a
  # condition that later resolves.
  telegramSend = (import ../../shared/notify.nix { inherit pkgs; }).send {
    tokenFile = config.age.secrets.telegram-bot-token.path;
    chatId = telegramChatId;
    name = "travel-cal-sync-telegram-send";
  };
in
{
  systemd.services.travel-cal-sync = {
    description = "Event-driven Proton -> Nextcloud travel-booking calendar sync";
    wantedBy = [ "multi-user.target" ];
    after = [ "hydroxide.service" "network-online.target" ];
    wants = [ "hydroxide.service" "network-online.target" ];
    environment = {
      TINY_LLM_GATE_URL = tinyLlmGateUrl;
      # Cloud, on the ChatGPT plan: the beast-only gemma4:e4b stalled every scan
      # from 2026-09-05 while beast was down. So candidate email bodies (names,
      # addresses, and with PAPRA_FILE_ALL_MAIL any mail carrying a PDF) now go
      # to OpenAI. Luna = the 5.6 extraction tier; a plan 429 backs off 15 min.
      MODEL = "gpt-5.6-luna";
      LOOKBACK_DAYS = "365";
      TELEGRAM_SEND = "${telegramSend}";
      NEXTCLOUD_CALDAV_URL = "https://${tailnetFqdn}/nextcloud/remote.php/dav/calendars/nsimon/";
      NEXTCLOUD_PASS_FILE = "/run/agenix/nextcloud-homepage-password";
      # Calendar collection URI to write into (from `--list-calendars`): "Personal".
      NEXTCLOUD_CAL = "personal";
      # Same drop-zone as papra-proton-poll, read off its unit so papra.nix stays
      # the only place the org id is written.
      PAPRA_DEST = config.systemd.services.papra-proton-poll.environment.PAPRA_PROTON_DEST;
      PAPRA_POLL_STATE = "/var/lib/papra-proton-poll/seen";
      PAPRA_FILE_ALL_MAIL = "1";
    };
    serviceConfig = {
      Type = "simple";
      User = "root";
      Restart = "always";
      RestartSec = 30;
      StateDirectory = "travel-cal-sync"; # -> /var/lib/travel-cal-sync
      ExecStart = "${pkgs.nicos-scripts}/bin/travel-cal-sync";
    };
  };
}
