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
#     gpt-5.5 (codex, via the gate) is declared at 131072.
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
  # gpt-5.5 (codex-backed) has a >64k context window; the small gemma models do
  # not, and hermes rejects sub-64k models at startup — so only gpt-5.5 here.
  # (picoclaw's default moved to the gpt-5.6 terra/sol/luna tiers; keep hermes on
  # a gate model verified to answer — bump this one line if the gate drops 5.5.)
  gateModel = "gpt-5.5";

  # Reuse the exact skills + persona docs PicoClaw uses, so an A/B compares the
  # agents, not two different skill sets. Both descend from OpenClaw's SKILL.md
  # format so most port directly (some may need edits).
  skillsSource = pkgs.runCommand "hermes-skills" { } ''
    mkdir -p $out
    cp -r ${../../shared/skills}/. $out/
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
    ${pkgs.coreutils}/bin/cat > ${hermesHome}/.env <<EOF
    TELEGRAM_BOT_TOKEN=$tg_tok
    TELEGRAM_ALLOWED_USERS=${toString telegramChatId},8627259779
    EOF
    ${pkgs.coreutils}/bin/chmod 0600 ${hermesHome}/.env

    # Skills + persona docs (copy, not symlink, so realpath stays inside HOME).
    ${pkgs.rsync}/bin/rsync -aL --delete --chmod=Du+rwx,Dgo+rx,Fu+rw,Fgo+r \
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
}
