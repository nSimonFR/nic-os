# Cyrus — Linear coding-agent dispatcher (cyrusagents/cyrus, Apache-2.0).
#
# Receives Linear webhooks, spawns Claude Code (via @anthropic-ai/claude-agent-sdk)
# against issues, opens PRs as the configured GitHub user. Public URL via
# Tailscale Funnel on :8443 → 127.0.0.1:3456.
#
# Packaging: source is vendored as a fixed-output derivation (fetchFromGitHub).
# A one-shot `cyrus-build.service` copies the source into /var/lib/cyrus/src and
# runs `pnpm install --frozen-lockfile && pnpm -r build` on first start (or when
# the pinned rev changes). Pure-Nix packaging via `pnpm.fetchDeps` was tried and
# OOM'd downloading platform-binary deps (win32/musl/etc.) on the rpi5 sandbox.
# The activation approach trades reproducibility for working software — the
# build runs once per source rev, marker file at /var/lib/cyrus/.built-rev
# prevents redundant rebuilds.
#
# Aperture path: ANTHROPIC_BASE_URL points at tiny-llm-gate (127.0.0.1:4001).
# Cyrus's ANTHROPIC_API_KEY is a placeholder; tiny-llm-gate injects the real
# rotated OAuth token from /run/claude-oauth/token per request.
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

  cyrusRev = "5f3ed02a9590318fac4ea36188a41d397a917a0b";

  cyrusSrc = pkgs.fetchFromGitHub {
    owner = "cyrusagents";
    repo  = "cyrus";
    rev   = cyrusRev;
    hash  = "sha256-j5+DjuTbjX5nUwS5D60IoLo6WcIUJUy8x+OTUrygX8E=";
  };
in
{
  options.services.cyrus = {
    enable = lib.mkEnableOption "cyrus — Linear coding-agent dispatcher";

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
        /run/claude-oauth/token).
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

    # ── One-shot source build ──────────────────────────────────────────────
    # Copies the pinned Cyrus source to /var/lib/cyrus/src, runs pnpm install
    # + build. Skips work if the marker file matches the pinned rev. Native
    # toolchain (gcc/make/python3) is on PATH for sqlite3 / node-pty.
    systemd.services.cyrus-build = {
      description = "Vendor + build Cyrus source on first run / rev change";
      wantedBy = [ "multi-user.target" ];
      before = [ "cyrus.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = [
        # CRITICAL: pnpm spawns `sh` to run install-script shell pipelines
        # (e.g. `prebuild-install -r napi || node-gyp rebuild`). Without
        # bash on PATH every child install fails with `spawn sh ENOENT`,
        # surfacing through pnpm as the opaque `exit code -2`.
        pkgs.bash
        pkgs.nodejs_22
        pkgs.pnpm_10
        pkgs.git
        pkgs.gcc
        pkgs.gnumake
        pkgs.python311
        pkgs.coreutils
        pkgs.findutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.user;
        WorkingDirectory = "/var/lib/cyrus";
        Environment = [
          "HOME=/var/lib/cyrus"
          "PNPM_HOME=/var/lib/cyrus/.pnpm"
          # Cyrus's package.json has a `prepare` lifecycle script that runs
          # husky. We don't want git hooks installed at service-build time
          # (no .git here), and husky's exit code is non-deterministic.
          "HUSKY=0"
        ];
        TimeoutStartSec = "20min";
      };
      script = ''
        set -e
        MARKER=/var/lib/cyrus/.built-rev
        WANT=${cyrusRev}
        if [ -f "$MARKER" ] && [ "$(cat $MARKER)" = "$WANT" ] && [ -f /var/lib/cyrus/src/apps/cli/dist/src/app.js ]; then
          echo "Cyrus already built for rev $WANT — skipping"
          exit 0
        fi
        echo "Building Cyrus rev $WANT"
        rm -rf /var/lib/cyrus/src
        cp -r ${cyrusSrc} /var/lib/cyrus/src
        chmod -R u+w /var/lib/cyrus/src
        cd /var/lib/cyrus/src
        # Strip the workspace-root `prepare` script (husky). Both `pnpm install`
        # and `pnpm rebuild` run it; husky's pnpm-shim spawn fails with exit
        # code -2 in this systemd context (no .git, no interactive TTY), and
        # we don't want git hooks at service-build time anyway.
        ${pkgs.jq}/bin/jq 'del(.scripts.prepare)' package.json > package.json.new \
          && mv package.json.new package.json
        # --child-concurrency=1 is defensive against rpi5 memory pressure:
        # default 5 spawns parallel postinstall scripts that thrash swap.
        pnpm install --frozen-lockfile --child-concurrency=1
        pnpm -r --filter='!@cyrus/electron' --workspace-concurrency=1 build
        echo "$WANT" > $MARKER
        echo "Build complete."
      '';
    };

    # ── Env file generator ─────────────────────────────────────────────────
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
      after = [
        "network-online.target"
        "cyrus-env.service"
        "cyrus-build.service"
        "tiny-llm-gate.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "cyrus-env.service" "cyrus-build.service" ];
      restartTriggers = [
        config.age.secrets.cyrus-linear-client-id.file
        config.age.secrets.cyrus-linear-client-secret.file
        config.age.secrets.cyrus-linear-webhook-secret.file
      ];
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
        ExecStart = "${pkgs.nodejs_22}/bin/node /var/lib/cyrus/src/apps/cli/dist/src/app.js start";
        Restart = "on-failure";
        RestartSec = 10;
        MemoryMax = "768M";

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
