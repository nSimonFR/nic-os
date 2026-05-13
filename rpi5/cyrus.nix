# Cyrus — Linear coding-agent dispatcher (cyrusagents/cyrus, Apache-2.0).
#
# Receives Linear webhooks, spawns Claude Code (via @anthropic-ai/claude-agent-sdk)
# against issues, opens PRs as the configured GitHub user. Public URL via
# Tailscale Funnel on :8443 → 127.0.0.1:3456.
#
# Aperture path: Claude SDK is pointed at tiny-llm-gate (127.0.0.1:4001) which
# proxies to api.anthropic.com using the rotated OAuth token at
# /run/claude-oauth/token. Cyrus itself does not see the real token; any value
# in ANTHROPIC_API_KEY works as long as the env var is set.
#
# Flip `services.cyrus.enable = true` in configuration.nix AFTER:
#   1. Creating the Linear OAuth app (see manual steps below).
#   2. Encrypting cyrus-linear-{client-id,client-secret,webhook-secret}.age.
#   3. Running `sudo -u cyrus gh auth login` for nSimonFR-ai.
#
# Manual: linear.app → Settings → API → OAuth Applications → New
#   Callback URL:  https://rpi5.gate-mintaka.ts.net:8443/callback
#   Webhook URL:   https://rpi5.gate-mintaka.ts.net:8443/linear-webhook
#   Scopes:        write, app:assignable, app:mentionable
#   Webhook event: "Agent session events"
{ config, lib, pkgs, ... }:
let
  cfg = config.services.cyrus;

  cyrusSrc = pkgs.fetchFromGitHub {
    owner = "cyrusagents";
    repo  = "cyrus";
    rev   = "5f3ed02a9590318fac4ea36188a41d397a917a0b";
    hash  = "sha256-j5+DjuTbjX5nUwS5D60IoLo6WcIUJUy8x+OTUrygX8E=";
  };

  cyrusPkg = pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "cyrus";
    version = "0.2.51-unstable-2026-05-11";
    src = cyrusSrc;

    # pnpm.fetchDeps materialises a fixed-output store path of the entire
    # node_modules closure (deterministic). When this hash mismatches, the
    # build prints the expected value; replace and rebuild.
    pnpmDeps = pkgs.pnpm_10.fetchDeps {
      inherit (finalAttrs) pname version src;
      # Initial value — replace with the hash Nix reports on first build.
      hash = lib.fakeHash;
    };

    nativeBuildInputs = [
      pkgs.nodejs_22
      pkgs.pnpm_10
      pkgs.pnpm_10.configHook
      pkgs.makeWrapper
      # Native compile toolchain for sqlite3, node-pty, tree-sitter-bash:
      pkgs.python3
      pkgs.gcc
      pkgs.gnumake
    ];

    buildPhase = ''
      runHook preBuild
      # The repo's build script excludes @cyrus/electron (desktop app we don't need).
      pnpm -r --filter='!@cyrus/electron' build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/cyrus $out/bin

      # Ship the whole repo (source + node_modules + dist) — Cyrus's runtime
      # paths resolve relative to the monorepo root (label prompt templates,
      # cyrus-skills-plugin assets, etc.).
      cp -r . $out/lib/cyrus/
      # Drop the build-time-only .git if it leaked in (fetchFromGitHub strips it
      # already, but be defensive).
      rm -rf $out/lib/cyrus/.git

      # The CLI entrypoint lives at apps/cli/dist/src/app.js.
      makeWrapper ${lib.getExe pkgs.nodejs_22} $out/bin/cyrus \
        --add-flags "$out/lib/cyrus/apps/cli/dist/src/app.js"

      runHook postInstall
    '';

    meta = with lib; {
      description = "Linear coding-agent dispatcher (Claude / Codex / Cursor / Gemini)";
      homepage = "https://github.com/cyrusagents/cyrus";
      license = licenses.asl20;
      mainProgram = "cyrus";
      platforms = platforms.linux;
    };
  });
in
{
  options.services.cyrus = {
    enable = lib.mkEnableOption "cyrus — Linear coding-agent dispatcher";

    package = lib.mkOption {
      type = lib.types.package;
      default = cyrusPkg;
      description = "Cyrus package to use.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "cyrus";
      description = ''
        System user the service runs as. Needs its own $HOME for ~/.cyrus
        (config + state) and ~/.config/gh (for nSimonFR-ai PAT).
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3456;
      description = "Internal HTTP port. Public URL on Tailscale Funnel :8443.";
    };

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://rpi5.gate-mintaka.ts.net:8443";
      description = "Public URL Linear webhooks reach (Tailscale Funnel).";
    };

    anthropicBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:4001";
      description = ''
        Where the Claude Agent SDK sends /v1/messages. Default points at
        tiny-llm-gate (which injects the rotated OAuth token from
        /run/claude-oauth/token). Set to "" / unset to talk to Anthropic
        directly (requires real ANTHROPIC_API_KEY).
      '';
    };

    repos = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "https://github.com/nSimonFR/nic-os" "https://github.com/nSimonFR/for-sure" ];
      description = ''
        Repos Cyrus will consider. Added at first run via `cyrus self-add-repo`
        — this list is for documentation only; the canonical state lives in
        ~/.cyrus/config.json (Cyrus writes it).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = "/var/lib/cyrus";
      createHome = true;
      shell = pkgs.bashInteractive;  # needed for `gh auth login` interactive flow
      description = "Cyrus Linear agent";
    };
    users.groups.${cfg.user} = {};

    age.secrets.cyrus-linear-client-id = {
      file  = ./secrets/cyrus-linear-client-id.age;
      owner = cfg.user;
      mode  = "0400";
    };
    age.secrets.cyrus-linear-client-secret = {
      file  = ./secrets/cyrus-linear-client-secret.age;
      owner = cfg.user;
      mode  = "0400";
    };
    age.secrets.cyrus-linear-webhook-secret = {
      file  = ./secrets/cyrus-linear-webhook-secret.age;
      owner = cfg.user;
      mode  = "0400";
    };

    # Pre-service oneshot writes /run/cyrus/env from agenix-backed values plus
    # the rotated Claude OAuth token. Same pattern as affine-mcp-env.
    systemd.services.cyrus-env = {
      description = "Generate cyrus environment file with secrets";
      wantedBy = [ "multi-user.target" ];
      before = [ "cyrus.service" ];
      after = [ "claude-oauth-extract.service" ];
      wants = [ "claude-oauth-extract.service" ];
      restartTriggers = [
        config.age.secrets.cyrus-linear-client-id.file
        config.age.secrets.cyrus-linear-client-secret.file
        config.age.secrets.cyrus-linear-webhook-secret.file
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /run/cyrus
        cat > /run/cyrus/env <<ENVEOF
        LINEAR_CLIENT_ID=$(cat ${config.age.secrets.cyrus-linear-client-id.path})
        LINEAR_CLIENT_SECRET=$(cat ${config.age.secrets.cyrus-linear-client-secret.path})
        LINEAR_WEBHOOK_SECRET=$(cat ${config.age.secrets.cyrus-linear-webhook-secret.path})
        CYRUS_BASE_URL=${cfg.baseUrl}
        CYRUS_SERVER_PORT=${toString cfg.port}
        CYRUS_HOME=/var/lib/cyrus/.cyrus
        ANTHROPIC_BASE_URL=${cfg.anthropicBaseUrl}
        ANTHROPIC_API_KEY=injected-by-tiny-llm-gate
        NODE_ENV=production
        ENVEOF
        chown ${cfg.user}:${cfg.user} /run/cyrus/env
        chmod 0400 /run/cyrus/env
      '';
    };

    systemd.services.cyrus = {
      description = "Cyrus — Linear coding-agent dispatcher";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "cyrus-env.service" "tiny-llm-gate.service" ];
      wants = [ "network-online.target" ];
      requires = [ "cyrus-env.service" ];
      restartTriggers = [
        config.age.secrets.cyrus-linear-client-id.file
        config.age.secrets.cyrus-linear-client-secret.file
        config.age.secrets.cyrus-linear-webhook-secret.file
      ];
      # gh / git / claude / codex are shelled out by Cyrus's executor.
      # claude-code is what the agent SDK invokes for the "claude" runner;
      # codex-cli only needed if a repo configures the codex runner.
      path = [
        pkgs.git
        pkgs.gh
        pkgs.openssh
        pkgs.nodejs_22
      ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.user;
        WorkingDirectory = "/var/lib/cyrus";
        EnvironmentFile = "/run/cyrus/env";
        ExecStart = "${cfg.package}/bin/cyrus start";
        Restart = "on-failure";
        RestartSec = 10;
        MemoryMax = "768M";  # claude-agent-sdk holds prompts; bump if OOM

        # Cyrus needs to write worktrees + state in $HOME. No ProtectHome,
        # but ProtectSystem=strict keeps it from touching the rest of the FS.
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/cyrus" ];
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      };
    };
  };
}
