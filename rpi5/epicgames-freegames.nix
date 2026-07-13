# epicgames-freegames-node: auto-claim the Epic Games Store weekly free games.
#
# Design — "run at night, zero idle RAM":
#   The upstream tool's Docker image runs a resident process that self-schedules
#   via an internal cron. We do NOT use that. `node dist/src/index.js` performs
#   exactly ONE redeem pass and then `process.exit(0)` (the scheduling lives only
#   in the Docker entrypoint.sh, which we skip). So we run it as a systemd
#   `oneshot` driven by a timer: the process — and the Chromium it spawns — only
#   exist for the ~1-3 min of a run, then fully exit. Nothing stays resident.
#
# Auth (one-time manual step, then headless):
#   v5 uses Epic device-code login (no password stored). The first run needs you
#   to approve a device code once (epicgames.com/activate, link sent to Telegram);
#   the session is then persisted under the state dir (device-auths.json + cookies)
#   and refreshed automatically on later runs. If Epic occasionally forces an
#   hCaptcha, the tool spins up a portal (loopback :3211, exposed tailnet-only on
#   :3700 — see services-registry.nix) and sends you a link to solve it.
{ config, pkgs, lib, telegramChatId, tailnetFqdn, ... }:
let
  # ── Tunables ───────────────────────────────────────────────────────────────
  # Epic account email is injected from agenix at render time (not a secret, but
  # this repo is public → kept out of git): /run/agenix/epicgames-account-email.

  stateDir = "/var/lib/epicgames-freegames"; # = CONFIG_DIR (config.json + session)
  configFile = "${stateDir}/config.json";

  # Device/captcha web portal: bound to loopback here, exposed tailnet-only via
  # Tailscale Serve in services-registry.nix (external 3700 → 127.0.0.1:3211).
  portalPort = 3211;
  portalUrl = "https://${tailnetFqdn}:3700";

  # Pinned to master HEAD (2026-06-21): the tagged v5.1.0 release is from 2024;
  # master carries ~2 years of Epic-API fixes since. Bump rev + both hashes to update.
  epicgames-freegames = pkgs.buildNpmPackage {
    pname = "epicgames-freegames-node";
    version = "5.1.0-unstable-2026-06-21";
    src = pkgs.fetchFromGitHub {
      owner = "claabs";
      repo = "epicgames-freegames-node";
      rev = "53fde0c27477338296ef3657658f5c63f1e5c380";
      hash = "sha256-G/S0bLVm1WUDdRbfcUVsfDQ/bCy1OkYW4Q8eV7ET6yY=";
    };
    npmDepsHash = "sha256-Y3ORxC+STTK3YNlPRIDH/CP4LVQimVaS59MPYepZv6w=";

    # Puppeteer must NOT download its bundled Chromium during `npm ci`; we point
    # it at the system chromium via PUPPETEER_EXECUTABLE_PATH at runtime instead.
    PUPPETEER_SKIP_DOWNLOAD = "true";
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD = "true";

    # `npm run build` = rimraf dist && tsc → dist/src/index.js (ESM).
    # Skip the default global-install phase; we install manually like ha-linky.
    dontNpmInstall = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/{bin,lib/epicgames-freegames}
      # node_modules must sit next to dist/ for ESM relative-path resolution.
      cp -r dist node_modules package.json $out/lib/epicgames-freegames/
      makeWrapper ${lib.getExe pkgs.nodejs_22} $out/bin/epicgames-freegames \
        --add-flags "--enable-source-maps" \
        --add-flags "$out/lib/epicgames-freegames/dist/src/index.js"
      runHook postInstall
    '';

    meta = {
      description = "Auto-redeem Epic Games Store weekly free games";
      homepage = "https://github.com/claabs/epicgames-freegames-node";
      license = lib.licenses.mit;
      mainProgram = "epicgames-freegames";
    };
  };

  # Direct Telegram alert for systemd job failure (the tool's own notifier
  # handles game/captcha events). Mirrors monitoring.nix's telegramNotify.
  telegramNotify = pkgs.writeShellScript "efg-telegram-notify" ''
    TOKEN=$(< /run/agenix/telegram-bot-token)
    ${pkgs.curl}/bin/curl -sf -X POST \
      "https://api.telegram.org/bot$TOKEN/sendMessage" \
      -d chat_id=${toString telegramChatId} \
      -d parse_mode=HTML \
      --data-urlencode "text=$1" >/dev/null || true
  '';
in
{
  users.users.epicgames-freegames = {
    isSystemUser = true;
    group = "epicgames-freegames";
    home = stateDir;
  };
  users.groups.epicgames-freegames = { };

  # ── Render config.json ───────────────────────────────────────────────────
  # Runs as root because the Telegram bot token is group-restricted (0440,
  # group for-sure) and the service user isn't in that group. Writes config.json
  # into the state dir, owned by the service user, 0400. Same shape as
  # reactive-resume-env. Re-runs when the token rotates.
  systemd.services.epicgames-freegames-config = {
    description = "Render epicgames-freegames config.json (inject Telegram token)";
    before = [ "epicgames-freegames.service" ];
    restartTriggers = [
      config.age.secrets.telegram-bot-token.file
      config.age.secrets.epicgames-account-email.file
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 0750 -o epicgames-freegames -g epicgames-freegames ${stateDir}
      token=$(cat /run/agenix/telegram-bot-token)
      email=$(cat /run/agenix/epicgames-account-email)
      ${pkgs.jq}/bin/jq -n \
        --arg email "$email" \
        --arg token "$token" \
        --arg chatId "${toString telegramChatId}" \
        --arg baseUrl "${portalUrl}" \
        --argjson port ${toString portalPort} \
        '{
          logLevel: "info",
          webPortalConfig: { baseUrl: $baseUrl, listenOpts: { port: $port, host: "127.0.0.1" } },
          accounts: [ { email: $email } ],
          notifiers: [ { type: "telegram", token: $token, chatId: $chatId } ]
        }' > ${configFile}
      chown epicgames-freegames:epicgames-freegames ${configFile}
      chmod 0400 ${configFile}
    '';
  };

  # ── Redeem run (oneshot: one pass, then process.exit(0) → zero idle RAM) ────
  systemd.services.epicgames-freegames = {
    description = "Claim Epic Games Store free games (single run)";
    after = [
      "network-online.target"
      "epicgames-freegames-config.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "epicgames-freegames-config.service" ];
    onFailure = [ "epicgames-freegames-failure.service" ];
    environment = {
      CONFIG_DIR = stateDir;
      PUPPETEER_EXECUTABLE_PATH = lib.getExe pkgs.chromium;
      TZ = "Europe/Paris";
      NODE_ENV = "production";
      # This Pi boots with cgroup_disable=memory, so systemd MemoryMax/High are
      # silently ignored — don't rely on them. Cap the Node heap here; the
      # Chromium spike is bounded by running at 04:00 (idle) + earlyoom backstop.
      NODE_OPTIONS = "--max-old-space-size=384";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "epicgames-freegames";
      Group = "epicgames-freegames";
      WorkingDirectory = stateDir;
      ExecStart = lib.getExe epicgames-freegames;
      # Cap a stuck run (e.g. an unattended captcha/device-code wait at 04:00):
      # Epic's device code expires in ~10 min, so 15 min covers the happy path
      # and fails cleanly otherwise (→ Telegram alert, retries next Thu/Sun).
      TimeoutStartSec = "15min";
    };
  };

  systemd.timers.epicgames-freegames = {
    description = "Twice-weekly Epic free-games claim (Thu + Sun, 04:00)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Sun claims the current week's game with margin; Thu is the last-chance
      # grab of the previous game before it expires (~17:00 CET Thursdays).
      OnCalendar = "Thu,Sun *-*-* 04:00:00";
      Persistent = true; # catch up a missed run if the Pi was off
      RandomizedDelaySec = "45m"; # be polite to Epic; don't hit exactly on the hour
    };
  };

  # ── Failure alert → Telegram ───────────────────────────────────────────────
  systemd.services.epicgames-freegames-failure = {
    description = "Notify Telegram when the Epic free-games run fails";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''${telegramNotify} "⚠️ epicgames-freegames run failed on rpi5 — check: journalctl -u epicgames-freegames -e"'';
    };
  };
}
