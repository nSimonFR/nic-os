{
  config,
  lib,
  pkgs,
  inputs,
  telegramChatId,
  tinyLlmGateUrl,
  clawBackend,
  ...
}:
# Hermes Agent home-manager module — A/B alternative to PicoClaw.
#
# Deliberately mirrors rpi5/picoclaw/picoclaw.nix so the two agents are
# symmetric: both run as `nsimon` user services, share the same exec PATH,
# skills, documents and agenix secrets, and both target the local tiny-llm-gate
# (:4001). Only one may poll the shared Telegram bot at a time — `clawBackend`
# (flake.nix) picks the boot default and `claw-switch` flips them live.
#
# Unlike PicoClaw (Go, ~8MB), Hermes is a Python+Node runtime: expect hundreds
# of MB resident, hence MemoryMax=1G. This is a comparison deployment, not a
# permanent replacement.
#
# Config surface — all VERIFIED against the built hermes 0.19.0 binary:
#   - Runner is `hermes gateway run` (foreground); config/state live in $HERMES_HOME.
#   - A custom OpenAI-compatible endpoint is selected by making `model` a DICT
#     ({provider=custom, base_url, model, api_key}) PLUS a matching entry in the
#     top-level `custom_providers` list (hermes_cli/main.py _save_custom_provider
#     + _active_custom_key_from_base_url). The `providers:` map from the docs did
#     NOT register as an active provider on 0.19.0.
#   - `api_mode = "chat"` forces /v1/chat/completions, dodging the Ollama-native
#     probe hang (upstream #26489).
#   - context_length ≥64k is required or hermes rejects the model at startup;
#     gpt-5.6-terra (via the gate) is declared at 131072.
#   - Telegram auto-enables from TELEGRAM_BOT_TOKEN in $HERMES_HOME/.env
#     (gateway/config.py:1721); TELEGRAM_ALLOWED_USERS is the sender allowlist.
#   - The gate needs no auth, so api_key="unused" is a non-secret placeholder;
#     the only real secret (bot token) is written into .env at start (0600),
#     never into the Nix store.
#
# Runtime layout:
#   ~/.hermes/config.yaml   — generated below, overwritten on restart
#   ~/.hermes/.env          — bot token + allowlist, written 0600 from /run/agenix
#   ~/.hermes/skills/       — SKILL.md skills (shared, reused from picoclaw)
#   ~/.hermes/*.md          — SOUL.md / IDENTITY.md / USER.md (reused from picoclaw)
#   ~/.hermes/…             — SQLite memory + agent state (Hermes-managed)
let
  hermes = inputs.hermes-agent.packages.${pkgs.system}.messaging;

  hermesHome = "/home/nsimon/.hermes";

  # tiny-llm-gate exposes an OpenAI-compatible API at :4001 (loopback, no auth).
  # Reach it directly rather than via Aperture for reliability (no tailnet hop).
  gateBase = "${tinyLlmGateUrl}/v1";
  # gpt-5.6-terra (the balanced GPT-5.6 coding tier) has a >64k context window;
  # the small gemma models don't, and hermes rejects sub-64k models at startup.
  # Match PicoClaw's default (`terra`) so the A/B compares the two agents on the
  # SAME model, not different ones. Alternatives on the gate: gpt-5.6-sol
  # (flagship), gpt-5.6-luna (high-volume), gpt-5.5. Bump this one line to switch.
  gateModel = "gpt-5.6-terra";

  # Reuse the exact skills + persona docs PicoClaw uses, so an A/B compares the
  # agents (and migrated cron jobs run) against the same skill set, not a subset.
  # Mirrors picoclaw.nix's skillsSource: shared cross-agent skills + picoclaw's
  # local skills (dawarich, immich-memories, caldav-calendar, …) that several
  # migrated jobs depend on. Both descend from OpenClaw's SKILL.md format so most
  # port directly (some may need edits).
  skillsSource = pkgs.runCommand "hermes-skills" { } ''
    mkdir -p $out
    cp -r ${../../shared/skills}/. $out/
    cp -rf ${../picoclaw/skills}/. $out/
  '';
  documentsSource = ../picoclaw/documents;

  hermesConfig = {
    # A dict-form `model` with provider=custom is how hermes 0.19 selects a
    # user-defined OpenAI-compatible endpoint (see header note).
    model = {
      provider = "custom";
      base_url = gateBase;
      model = gateModel;
      api_key = "unused";
    };
    custom_providers = [
      {
        name = "tiny-llm-gate";
        base_url = gateBase;
        model = gateModel;
        api_mode = "chat";
        models.${gateModel}.context_length = 131072;
      }
    ];

    # Local shell backend so the agent can shell out to system tools (mirrors
    # picoclaw's restrict_to_workspace=false trust model: safety comes from the
    # single-chat-ID Telegram allowlist, not workspace isolation).
    terminal = {
      backend = "local";
      cwd = "${hermesHome}/workspace";
    };

    compression = {
      enabled = true;
      threshold = 0.85;
    };

    # External memory provider. `holographic` is the local, zero-API-key store
    # (SQLite + FTS5 full-text search + fact extraction + consolidation) — a real
    # upgrade over the built-in flat markdown recall, and it needs no cloud key.
    # NOTE: true dense-vector semantic recall would need an embedding endpoint;
    # the gate advertises embedding models but currently routes them to beast
    # (502 when beast is asleep), so holographic runs in its always-available
    # local/FTS5 mode here rather than depending on that intermittent upstream.
    memory.provider = "holographic";
  };

  configFile = pkgs.writeText "hermes-config.yaml" (builtins.toJSON hermesConfig);

  # ExecStartPre: materialise config.yaml + .env + skills/documents into
  # $HERMES_HOME. Runs on every restart, keeping state in sync with the Nix
  # store. The bot token is read from /run/agenix at start time and written into
  # .env (0600) so it never lands in the world-readable Nix store.
  setupScript = pkgs.writeShellScript "hermes-setup" ''
    set -eu
    ${pkgs.coreutils}/bin/mkdir -p ${hermesHome} ${hermesHome}/workspace ${hermesHome}/skills
    ${pkgs.coreutils}/bin/install -m 0644 ${configFile} ${hermesHome}/config.yaml

    # .env — bot token (secret) + sender allowlist. TELEGRAM_BOT_TOKEN presence
    # auto-enables the Telegram platform. Reuse picoclaw's bot + allowlist
    # (nSimon + Alfie) for a true A/B on the same channel.
    tg_tok="$(${pkgs.coreutils}/bin/cat /run/agenix/telegram-bot-token)"
    umask 077
    # TELEGRAM_HOME_CHANNEL pins where Hermes delivers cron results + proactive
    # messages (gateway/config.py:1741) — nSimon's DM (chat_id == user id for a
    # private chat). Set declaratively rather than via /sethome, which would be
    # wiped when this setup script regenerates config.yaml on the next restart.
    ${pkgs.coreutils}/bin/cat > ${hermesHome}/.env <<EOF
    TELEGRAM_BOT_TOKEN=$tg_tok
    TELEGRAM_ALLOWED_USERS=${toString telegramChatId},8627259779
    TELEGRAM_HOME_CHANNEL=${toString telegramChatId}
    TELEGRAM_HOME_CHANNEL_NAME=nSimon
    EOF
    ${pkgs.coreutils}/bin/chmod 0600 ${hermesHome}/.env

    # Skills + persona docs (copy, not symlink, so realpath stays inside HOME).
    # NOTE: deliberately NO --delete here. Hermes writes its own self-authored
    # skills into this same dir (see hermes-skill-promote below); --delete would
    # wipe them on every restart before they can be reviewed. The cost is that a
    # skill removed from the repo lingers in the runtime dir until manually
    # cleaned (Hermes' own `curator prune` archives idle ones anyway).
    ${pkgs.rsync}/bin/rsync -aL --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r \
      "${skillsSource}/" "${hermesHome}/skills/"
    ${pkgs.rsync}/bin/rsync -aL --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r \
      "${documentsSource}/" "${hermesHome}/"
  '';

  # ExecStart wrapper: source shared skill creds, set HERMES_HOME, and give the
  # agent the same PATH an interactive nsimon shell (and picoclaw) sees so its
  # local terminal backend can shell out to firefly/gh/HA tools. ripgrep is a
  # hermes code-search dependency (see `hermes postinstall`), so ensure it's on
  # PATH. HERMES_ACCEPT_HOOKS=1 auto-approves shell hooks in this headless
  # service (no TTY to prompt on).
  execWrapper = pkgs.writeShellScript "hermes-exec" ''
    set -a
    . /run/agenix/picoclaw-env
    set +a
    export HOME="/home/nsimon"
    export HERMES_HOME="${hermesHome}"
    export HERMES_ACCEPT_HOOKS=1
    export PATH="${pkgs.rtk}/bin:${pkgs.ripgrep}/bin:$HOME/.local/state/nix/profiles/home-manager/home-path/bin:/etc/profiles/per-user/nsimon/bin:/run/current-system/sw/bin:/run/wrappers/bin:$HOME/.nix-profile/bin:$PATH"
    exec ${hermes}/bin/hermes gateway run
  '';

  # Bridge Hermes' self-authored skills back into the repo for manual
  # versioning. Hermes writes generated skills into ~/.hermes/skills/; this
  # copies any that aren't builtin/seeded into the canonical checkout's
  # shared/skills/ as UNTRACKED files, then nudges via Telegram. It never runs
  # git — a human reviews and commits. Logic lives in hermes-skill-promote.sh
  # (kept out of Nix per the repo's no-inline-scripts convention).
  nicosRepo = "/home/nsimon/nic-os";
  promoteWrapper = pkgs.writeShellScript "hermes-skill-promote-wrapper" ''
    export HOME="/home/nsimon"
    export HERMES_SKILLS_DIR="${hermesHome}/skills"
    export DEST_SKILLS="${nicosRepo}/shared/skills"
    export PICOCLAW_SKILLS="${nicosRepo}/rpi5/picoclaw/skills"
    export TG_CHAT_ID="${toString telegramChatId}"
    export TG_TOKEN_FILE="/run/agenix/telegram-bot-token"
    export PATH="${
      lib.makeBinPath [
        hermes
        pkgs.systemd
        pkgs.rsync
        pkgs.curl
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.findutils
      ]
    }:$PATH"
    exec ${pkgs.bash}/bin/bash ${./hermes-skill-promote.sh}
  '';
in
{
  home.packages = [ hermes ];

  systemd.user.services.hermes = {
    Unit = {
      Description = "Hermes Agent gateway (PicoClaw A/B alternative)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      ExecStartPre = "${setupScript}";
      ExecStart = "${execWrapper}";
      Restart = "on-failure";
      RestartSec = 5;
      # Python runtime — hundreds of MB expected, vs picoclaw's <20MB. 1G cap.
      MemoryMax = "1G";
    };
    # Only autostart when Hermes is the selected backend (see picoclaw.nix).
    Install.WantedBy = lib.optionals (clawBackend == "hermes") [ "default.target" ];
  };

  # Promote Hermes self-authored skills into the repo (untracked) for manual
  # versioning. Oneshot driven by an hourly timer; the script no-ops when Hermes
  # is inactive, so it's safe to leave the timer enabled regardless of backend.
  systemd.user.services.hermes-skill-promote = {
    Unit = {
      Description = "Promote Hermes self-authored skills into nic-os (untracked, for manual versioning)";
      After = [ "hermes.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${promoteWrapper}";
    };
  };
  systemd.user.timers.hermes-skill-promote = {
    Unit.Description = "Hourly promotion of Hermes self-authored skills into nic-os";
    Timer = {
      OnBootSec = "10min";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
