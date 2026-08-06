{
  config,
  lib,
  pkgs,
  inputs,
  telegramChatId,
  apertureUrl,
  ...
}:
# Hermes Agent home-manager module — the rpi5 Telegram agent.
#
# Runs as an `nsimon` user service polling the Telegram bot and reaching
# tiny-llm-gate through Aperture. It succeeded PicoClaw (retired 2026-07): the
# shared cross-agent skills, the local agent skills (./skills), the persona
# documents (./documents) and the agenix agent-env secret all moved here when
# the A/B ended.
#
# Hermes is a Python+Node runtime: expect hundreds of MB resident, hence
# MemoryMax=1G.
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
#   - No failover is configured (see the gateModel note below): a plan-cap 429
#     on the primary takes Hermes offline until the quota resets.
#   - Telegram auto-enables from TELEGRAM_BOT_TOKEN in $HERMES_HOME/.env
#     (gateway/config.py:1721); TELEGRAM_ALLOWED_USERS is the sender allowlist.
#   - Neither Aperture nor the gate behind it needs a real credential, so
#     api_key="unused" is a non-secret placeholder; the only real secret (bot
#     token) is written into .env at start (0600), never into the Nix store.
#
# Runtime layout:
#   ~/.hermes/config.yaml   — generated below, overwritten on restart
#   ~/.hermes/.env          — bot token + allowlist, written 0600 from /run/agenix
#   ~/.hermes/skills/       — SKILL.md skills (shared/skills + ./skills)
#   ~/.hermes/*.md          — SOUL.md / IDENTITY.md / USER.md (from ./documents)
#   ~/.hermes/…             — SQLite memory + agent state (Hermes-managed)
let
  hermes = inputs.hermes-agent.packages.${pkgs.system}.messaging;

  hermesHome = "/home/nsimon/.hermes";

  # Route through Aperture (tailnet) rather than the gate's loopback :4001, so
  # Hermes' LLM usage, cost and full request/response bodies land on the
  # observability dashboard alongside Sure and claude-cli — Hermes was the last
  # significant client still invisible there. Aperture forwards to tiny-llm-gate
  # and needs no real credential, so api_key stays the "unused" placeholder.
  #
  # Tradeoff (deliberate, reversed from the original design): Aperture is a
  # separate tailnet node, so Hermes' inference now depends on tailscaled being
  # healthy. To revert to the loopback path, swap this back to
  # `${tinyLlmGateUrl}/v1` and re-add tinyLlmGateUrl to the module arguments.
  #
  # Aperture rejects /v1/embeddings — harmless here because memory.provider is
  # `holographic`, which runs on local SQLite/FTS5 and needs no embeddings.
  gateBase = "${apertureUrl}/v1";
  # gpt-5.6-terra (the balanced GPT-5.6 coding tier) has a >64k context window;
  # the small gemma models don't, and hermes rejects sub-64k models at startup.
  # Alternatives on the gate: gpt-5.6-sol (flagship), gpt-5.6-luna (high-volume),
  # gpt-5.5. Bump this one line to switch.
  gateModel = "gpt-5.6-terra";

  # NO Anthropic fallback here, deliberately — do not re-add one without
  # funding Extra Usage first (claude.ai/settings/usage).
  #
  # The gate's `claude` model works for other clients, but Anthropic rejects
  # THIS one: it fingerprints third-party clients by request CONTENT, and
  # Hermes' system prompt or its 18-tool set each trip it alone, with
  # HTTP 400 "Third-party apps now draw from your extra usage, not your plan
  # limits." Verified 2026-08-05 against both pooled OAuth accounts (acct1
  # team, acct2 max) — so the gate's sticky-until-429 failover cannot route
  # around it — and across every transport: the OpenAI-translated `claude`
  # route, the gate's native /v1/messages passthrough (the exact path Claude
  # Code uses, sentinel included), and api.anthropic.com directly. Switching
  # Hermes to `api_mode = "anthropic_messages"` therefore changes nothing;
  # only the payload's content matters, and only trivial Claude-Code-shaped
  # requests pass on plan limits alone.
  #
  # Cyrus (rpi5/cyrus.nix) shares this Anthropic path and is unaffected — it
  # drives the real Claude Code SDK, so it is not a third-party client.

  # Skill set = shared cross-agent skills (shared/skills) + Hermes' local skills
  # (dawarich, immich-memories, caldav-calendar, gog, protonmail, …) that several
  # cron jobs depend on. These local skills moved here from the retired PicoClaw
  # module (rpi5/hermes/skills). All descend from OpenClaw's SKILL.md format.
  #
  # The MTG Commander pair lives in shared/mtg-skills instead: it is shared with
  # the Mac's `claude-mtg` CLI (home/claude-mtg.nix) but must stay OUT of
  # shared/skills, which home/claude.nix auto-wires into every general-purpose
  # agent. Kept under mtg/ here so the runtime layout is unchanged.
  #
  # This list is the single declaration of what the repo seeds into
  # ~/.hermes/skills; hermes-skill-promote below derives its exclusion set from
  # it, so the two cannot drift.
  skillTree = import ../../shared/skill-tree.nix { inherit lib; };
  skillLineages = [
    { source = ../../shared/skills; }
    { source = ./skills; }
    { source = ../../shared/mtg-skills; prefix = "mtg"; }
  ];
  skillsSource = skillTree.tree {
    inherit pkgs;
    name = "hermes-skills";
    lineages = skillLineages;
  };
  documentsSource = ./documents;

  # Workspace scripts the cron jobs shell out to (daily pending digest, weekly
  # job-alerts). These were agent-authored under the retired PicoClaw's
  # ~/.picoclaw/workspace and lived only there (untracked runtime); versioning
  # them here + seeding into ~/.hermes/workspace makes the cron jobs reproducible
  # and removes the last dependency on the retired agent's home. Runtime state
  # (job-alerts/.seen_jobs.json, scratch tmp/) is deliberately NOT tracked and
  # survives restarts because the seed rsync below omits --delete.
  workspaceSource = ./workspace;

  # Weekly tabletop events: the app lives in the seeded Hermes workspace so its
  # SQLite snapshot persists outside the Nix store.  It runs silently when
  # nothing changes; non-empty stdout is delivered verbatim by Hermes cron.
  weeklyEventsScript = pkgs.writeShellScript "weekly-events" ''
    set -euo pipefail
    export TELEGRAM_CHAT_ID="${toString telegramChatId}"
    cd ${hermesHome}/workspace/weekly-events
    exec ${pkgs.python3}/bin/python3 -m weekly_events.app \
      --config sources.json --state data/events.sqlite3 --send --log-level WARNING
  '';

  # mtg-mcp — native MCP server exposing Magic: The Gathering / Commander tools
  # (Scryfall card search + pricing + rulings + legality, deck validation,
  # Moxfield/Archidekt deck import, EDHREC recs/combos, comprehensive rules).
  # All public data — no auth or API keys. Hermes' built-in MCP client
  # (mcp_servers, below) launches it over stdio and registers its tools as
  # mcp__mtg__* in every conversation. The package definition moved to
  # pkgs/agents/mtg-mcp.nix when the Mac's `claude-mtg` CLI started sharing it, and is
  # now exposed as `pkgs.mtg-mcp` (pkgs/overlay.nix) so both share one eval.
  mtgMcp = pkgs.mtg-mcp;

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

    # Native MCP client: launch mtg-mcp over stdio at startup and auto-register
    # its tools (mcp__mtg__search_cards, __validate_deck, __get_card_price,
    # __get_edhrec_recommendations, …) into every platform toolset. Public MTG
    # data only, so no `env`/secrets are passed to the subprocess. Requires the
    # `mcp` Python package, which the hermes-agent env already bundles.
    mcp_servers.mtg.command = "${mtgMcp}/bin/mtg-mcp";

    # Local shell backend so the agent can shell out to system tools (mirrors
    # picoclaw's restrict_to_workspace=false trust model: safety comes from the
    # single-chat-ID Telegram allowlist, not workspace isolation).
    terminal = {
      backend = "local";
      cwd = "${hermesHome}/workspace";
      # gog (Google Workspace CLI, Work/Gmail) unlocks its encrypted file
      # keyring non-interactively from GOG_KEYRING_PASSWORD. Hermes' execute_code
      # /terminal sandbox scrubs any env var whose NAME contains a secret
      # substring (KEY/TOKEN/SECRET/PASSWORD/…) before spawning agent
      # subprocesses (code_execution_tool.py `_scrub_child_env`), so in the cron
      # mail-digest the Work inbox failed with "no TTY … set GOG_KEYRING_PASSWORD"
      # while interactive turns (plain terminal path, no substring strip) worked.
      # `env_passthrough` is the intended opt-in escape hatch, checked BEFORE the
      # scrub — it lets these non-provider names through so gog can decrypt its
      # keyring headlessly. GOG_ACCOUNT isn't a secret but is passed too so the
      # skill needn't repeat --account.
      env_passthrough = [
        "GOG_KEYRING_PASSWORD"
        "GOG_ACCOUNT"
      ];
    };

    compression = {
      enabled = true;
      threshold = 0.85;
    };

    # Stream replies progressively by editing a Telegram message as tokens arrive.
    # This is the documented transport for Hermes 0.19.0.
    gateway.streaming = {
      enabled = true;
      transport = "edit";
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
    # auto-enables the Telegram platform. Allowlist = nSimon + Alfie.
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

    # Cron workspace scripts (executable). Same NO --delete rule: the workspace
    # also holds live runtime state (kanban.db, sandboxes, job-alerts/.seen_jobs.json)
    # that must survive restarts, so only add/refresh the tracked scripts.
    ${pkgs.rsync}/bin/rsync -aL --chmod=Du+rwx,Dgo+rx,Fu+rwx,Fgo+rx \
      "${workspaceSource}/" "${hermesHome}/workspace/"
  '';

  # ExecStart wrapper: source shared skill creds, set HERMES_HOME, and give the
  # agent the same PATH an interactive nsimon shell (and picoclaw) sees so its
  # local terminal backend can shell out to firefly/gh/HA tools. ripgrep is a
  # hermes code-search dependency (see `hermes postinstall`), so ensure it's on
  # PATH. HERMES_ACCEPT_HOOKS=1 auto-approves shell hooks in this headless
  # service (no TTY to prompt on).
  execWrapper = pkgs.writeShellScript "hermes-exec" ''
    set -a
    . /run/agenix/agent-env
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
  # One-shot seam (shared/notify.nix). Note this is the *agenix* bot token, not
  # the one in $HERMES_HOME/.env that Hermes itself runs on: this nudge is
  # nic-os telling a human to review a promoted skill, not Hermes talking.
  # Hardcoded path because this is a home-manager module — no age.secrets here.
  promoteNotify = (import ../../shared/notify.nix { inherit pkgs; }).send {
    tokenFile = "/run/agenix/telegram-bot-token";
    chatId = telegramChatId;
    name = "hermes-skill-promote-notify";
  };
  promoteWrapper = pkgs.writeShellScript "hermes-skill-promote-wrapper" ''
    export HOME="/home/nsimon"
    export HERMES_SKILLS_DIR="${hermesHome}/skills"
    export DEST_SKILLS="${nicosRepo}/shared/skills"
    # From skillLineages above, so the exclusion set covers every lineage —
    # mtg-skills and its `mtg/` dir included, which the old listing missed.
    export SEEDED_SKILL_NAMES="${lib.concatStringsSep ":" (skillTree.names skillLineages)}"
    export TELEGRAM_SEND="${promoteNotify}"
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
      Description = "Hermes Agent gateway (Telegram agent)";
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
    # Hermes is the sole Telegram agent (PicoClaw retired), so always autostart.
    Install.WantedBy = [ "default.target" ];
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
  systemd.user.services.weekly-tabletop-events = {
    Unit = {
      Description = "Weekly tabletop events Telegram digest";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${weeklyEventsScript}";
    };
  };
  systemd.user.timers.weekly-tabletop-events = {
    Unit.Description = "Weekly tabletop events digest";
    Timer = {
      OnCalendar = "Mon *-*-* 09:00:00 Europe/Paris";
      Persistent = true;
    };
    Install.WantedBy = [ "timers.target" ];
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
