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
# Aperture path: ANTHROPIC_BASE_URL points at Aperture (ai.gate-mintaka.ts.net).
# Aperture forwards to tiny-llm-gate (127.0.0.1:4001) which injects the rotated
# OAuth token from /run/claude-oauth/token. Aperture logs every request +
# response for observability (/api/sessions). Cyrus's ANTHROPIC_API_KEY is a
# placeholder; tiny-llm-gate replaces the header before hitting Anthropic.
#
# Flip `services.cyrus.enable = true` in configuration.nix AFTER:
#   1. Creating the Linear OAuth app (see manual steps below).
#   2. Encrypting cyrus-linear-{client-id,client-secret,webhook-secret}.age.
#   3. Running `sudo -u cyrus gh auth login` for nSimonFR-ai.
#
# Manual: linear.app → Settings → API → OAuth Applications → New
#   Callback URL:  https://rpi5.gate-mintaka.ts.net:8443/callback
#                  (must be exact — cyrus hardcodes /callback, not /oauth/callback)
#   Webhook URL:   https://rpi5.gate-mintaka.ts.net:8443/linear-webhook
#                  (must be exact — cyrus mounts at /linear-webhook, NOT /webhooks/linear)
#   Scopes:        write, app:assignable, app:mentionable
#   Webhook event: "Agent session events"
{ config, lib, pkgs, unstablePkgs, apertureUrl, ... }:
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

    claudeDefaultModel = lib.mkOption {
      type = lib.types.str;
      default = "sonnet";
      description = ''
        Top-level `claudeDefaultModel` written to /var/lib/cyrus/.cyrus/config.json
        on each rebuild. Used by edge-worker when neither the session metadata
        nor the repo entry specifies a model. Accepts the same values the CLI
        does — "opus", "sonnet", "haiku", or a full model id like
        "claude-sonnet-4-6".
      '';
    };

    anthropicBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = apertureUrl;
      description = ''
        Where the Claude Agent SDK sends /v1/messages. Default points at
        Aperture (Tailscale-managed proxy with full session observability):
          cyrus → Aperture → tiny-llm-gate → api.anthropic.com
        tiny-llm-gate's Anthropic handler injects the rotated OAuth token
        from /run/claude-oauth/token, so Aperture stays out of credential
        management. See memory: project_claude_code_aperture.md.
      '';
    };

    repositories = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule ({ config, ... }: {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Local repo name.";
          };
          url = lib.mkOption {
            type = lib.types.str;
            description = "HTTPS clone URL; cyrus user uses gh credential helper.";
          };
          workspace = lib.mkOption {
            type = lib.types.str;
            default = "nSimon";
            description = "Linear workspace display name. Must match the workspace OAuth'd via `cyrus self-auth-linear`.";
          };
          routingLabels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ config.name ];
            defaultText = lib.literalExpression "[ name ]";
            description = ''
              Linear labels that route issues to this repo. Default is the
              repo name (matches cyrus `self-add-repo` default).

              Set to `[]` to make this repo a **catch-all**: any issue with
              no matching routing label / projectKey / teamKey / `[repo=...]`
              tag lands here instead of triggering cyrus's "Which repository
              should I work in?" comment. Only one repo can be catch-all
              (first one wins in RepositoryRouter).
            '';
          };
          catchAll = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Convenience flag — sets `routingLabels = []` so cyrus's
              RepositoryRouter treats this repo as the fallback for issues
              that don't match any other route.
            '';
          };
        };
      }));
      default = [];
      description = ''
        Repositories cyrus manages. Synced declaratively on activation by
        `cyrus-sync-repos.service`:
          - missing repos → `cyrus self-add-repo <url> <workspace> -l <labels>`
          - existing repos → routingLabels reconciled in place via jq

        Bootstrap order (one-time): create Linear OAuth app → encrypt
        cyrus-linear-*.age → `nixos-rebuild switch` → `sudo -u cyrus -H
        cyrus self-auth-linear` (interactive browser flow) → `nixos-rebuild
        switch` again (sync-repos picks up the workspace token).

        Removing a repo from the list does NOT remove it from cyrus's
        runtime config — that's a destructive op left to the operator.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Cyrus's agent clones user repos and runs whatever lint/test/build the
    # repo declares. Many npm packages ship per-platform prebuilt ELFs (biome,
    # esbuild, swc, prisma, sharp, ...) dynamically linked against
    # /lib/ld-linux-aarch64.so.1 + stock glibc. On NixOS those paths don't
    # exist and execve fails before the program starts. nix-ld provides the
    # loader shim at /lib/ld-linux-* and stages a library set under
    # LD_LIBRARY_PATH so generic-Linux binaries Just Work.
    programs.nix-ld = {
      enable = true;
      libraries = with pkgs; [
        stdenv.cc.cc.lib  # libstdc++, libgcc_s
        zlib
        openssl
        curl
        glib
        libgcc
      ];
    };

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
    age.secrets.cyrus-github-webhook-secret = {
      file  = ./secrets/cyrus-github-webhook-secret.age;
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
        # The @anthropic-ai/claude-agent-sdk pulls a per-platform optional dep
        # (`@anthropic-ai/claude-agent-sdk-linux-arm64`) that bundles a generic
        # dynamically-linked claude ELF — unrunnable on NixOS (no /lib64). The
        # SDK has no env override to point at the nixpkgs-patched binary, so we
        # overwrite the bundled file with a symlink to pkgs.claude-code/bin/claude
        # (cyrus's edge-worker doesn't surface pathToClaudeCodeExecutable).
        for bundled in node_modules/.pnpm/@anthropic-ai+claude-agent-sdk-linux-*/node_modules/@anthropic-ai/claude-agent-sdk-linux-*/claude; do
          if [ -e "$bundled" ]; then
            ln -sf ${unstablePkgs.claude-code}/bin/claude "$bundled"
            echo "Replaced bundled SDK claude with nixpkgs build: $bundled"
          fi
        done
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
      # Reads the GitHub PAT from cyrus's gh CLI keychain — same pattern as
      # forgejo.nix. No agenix entry needed; refresh by re-running
      # `sudo -u cyrus gh auth login`.
      path = [ pkgs.gh ];
      restartTriggers = [
        config.age.secrets.cyrus-linear-client-id.file
        config.age.secrets.cyrus-linear-client-secret.file
        config.age.secrets.cyrus-linear-webhook-secret.file
        config.age.secrets.cyrus-github-webhook-secret.file
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /run/cyrus
        # gh stores its token under cyrus's HOME; without HOME set, gh looks
        # at /root/.config/gh and errors out with "not logged in".
        GH_TOKEN=$(HOME=/var/lib/cyrus ${pkgs.gh}/bin/gh auth token)
        cat > /run/cyrus/env <<ENVEOF
        LINEAR_CLIENT_ID=$(cat ${config.age.secrets.cyrus-linear-client-id.path})
        LINEAR_CLIENT_SECRET=$(cat ${config.age.secrets.cyrus-linear-client-secret.path})
        LINEAR_WEBHOOK_SECRET=$(cat ${config.age.secrets.cyrus-linear-webhook-secret.path})
        # We self-host the OAuth/webhook endpoint (Tailscale Funnel), so Linear
        # POSTs directly. Without this flag cyrus defaults to "proxy mode" and
        # verifies signatures against CYRUS_API_KEY (the hosted proxy.atcyrus.com
        # path), which we don't use — every webhook would 401.
        LINEAR_DIRECT_WEBHOOKS=true
        CYRUS_BASE_URL=${cfg.baseUrl}
        CYRUS_SERVER_PORT=${toString cfg.port}
        CYRUS_HOME=/var/lib/cyrus/.cyrus
        ANTHROPIC_BASE_URL=${cfg.anthropicBaseUrl}
        ANTHROPIC_API_KEY=injected-by-tiny-llm-gate
        NODE_ENV=production
        # ── GitHub bot identity ──
        # GITHUB_BOT_USERNAME drives two behaviours in EdgeWorker.ts:
        #   1. Filters incoming PR comments to those that @mention the bot.
        #   2. Skips comments authored by the bot itself (loop prevention).
        # When unset, cyrus's tip text defaults to the literal "@cyrusagent"
        # (its hosted SaaS bot, irrelevant here), so the tip becomes a lie.
        GITHUB_BOT_USERNAME=nSimonFR-ai
        GITHUB_TOKEN=$GH_TOKEN
        # CYRUS_HOST_EXTERNAL=true + GITHUB_WEBHOOK_SECRET puts cyrus into
        # "signature verification" mode (verifies X-Hub-Signature-256 against
        # this secret directly). Without these, cyrus expects forwarded
        # webhooks via cyrus's hosted proxy and rejects ours.
        CYRUS_HOST_EXTERNAL=true
        GITHUB_WEBHOOK_SECRET=$(cat ${config.age.secrets.cyrus-github-webhook-secret.path})
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
        config.age.secrets.cyrus-github-webhook-secret.file
        cfg.claudeDefaultModel
      ];
      path = [
        pkgs.git
        pkgs.gh
        pkgs.openssh
        pkgs.nodejs_22
        # Many cyrus-managed repos use pnpm workspaces; agent shells need it
        # on PATH (corepack can't write into the read-only nix-store node).
        pkgs.pnpm_10
        # @anthropic-ai/claude-agent-sdk spawns the `claude` CLI as a child.
        # Without it the SDK exits 127 ("command not found") on every session.
        unstablePkgs.claude-code
        # Claude Code's sandbox uses these; missing them only emits warnings
        # (no fatal) but skipping them disables write-isolation.
        pkgs.socat
        pkgs.bubblewrap
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
        # Claude Code uses /tmp/claude-<uid>/ as a working/sandbox dir for
        # Bash tool execution. Without a private writable /tmp under
        # ProtectSystem=strict, every Bash tool call fails with EROFS and
        # the agent reports "read-only filesystem at the harness level".
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        # AF_NETLINK is needed for getifaddrs() — Fastify calls it on listen()
        # to log the bound addresses. Without it Node errors out with
        # `uv_interface_addresses returned Unknown system error 97`
        # (EAFNOSUPPORT) immediately after binding. AF_PACKET would also work
        # via SIOCGIFCONF, but AF_NETLINK is the modern path libuv prefers.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      };
    };

    # ── Default model sync ─────────────────────────────────────────────────
    # Writes `claudeDefaultModel` to config.json on each rebuild. config.json
    # is the runtime source of truth for the edge-worker; without this step
    # the default ("opus") sticks even after changing the Nix option.
    systemd.services.cyrus-set-model = {
      description = "Sync cyrus claudeDefaultModel into config.json";
      wantedBy = [ "multi-user.target" ];
      after = [ "cyrus-build.service" ];
      requires = [ "cyrus-build.service" ];
      before = [ "cyrus.service" ];
      path = [ pkgs.jq pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.user;
      };
      script = ''
        set -e
        CONFIG=/var/lib/cyrus/.cyrus/config.json
        if [ ! -f "$CONFIG" ]; then
          echo "config.json not present — run 'cyrus self-auth-linear' first"
          exit 0
        fi
        tmp=$(mktemp)
        jq --arg m '${cfg.claudeDefaultModel}' '.claudeDefaultModel = $m' "$CONFIG" > "$tmp"
        mv "$tmp" "$CONFIG"
        echo "Set claudeDefaultModel = ${cfg.claudeDefaultModel}"
      '';
    };

    # ── Declarative repo sync ──────────────────────────────────────────────
    # Reads services.cyrus.repositories, ensures each is in config.json by
    # invoking `cyrus self-add-repo` for any missing entry. No-op if Linear
    # OAuth hasn't been bootstrapped yet (linearWorkspaces empty).
    systemd.services.cyrus-sync-repos = lib.mkIf (cfg.repositories != []) {
      description = "Sync declared cyrus repositories with runtime config.json";
      wantedBy = [ "multi-user.target" ];
      after = [ "cyrus-build.service" "cyrus-env.service" ];
      requires = [ "cyrus-build.service" "cyrus-env.service" ];
      path = [
        pkgs.nodejs_22
        pkgs.git
        pkgs.gh
        pkgs.openssh
        pkgs.jq
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.user;
        EnvironmentFile = "/run/cyrus/env";
        Environment = [ "HOME=/var/lib/cyrus" ];
        # Restart cyrus.service iff sync actually mutated config.json. The
        # `+` prefix elevates to root so systemctl works; the script writes a
        # /run flag we check here. Without this, cyrus keeps stale routing
        # labels in memory after a rebuild that changed them.
        ExecStartPost = "+${pkgs.bash}/bin/bash -c '[ -f /var/lib/cyrus/.sync-changed ] && { rm /var/lib/cyrus/.sync-changed; ${pkgs.systemd}/bin/systemctl try-restart cyrus.service; } || true'";
      };
      script =
        let
          normalized = map (r: {
            inherit (r) name url workspace;
            routingLabels = if r.catchAll then [] else r.routingLabels;
          }) cfg.repositories;
          reposJson = builtins.toJSON normalized;
        in ''
          set -e
          CONFIG=/var/lib/cyrus/.cyrus/config.json
          CHANGED=0
          if [ ! -f "$CONFIG" ]; then
            echo "config.json not present — run 'cyrus self-auth-linear' first to bootstrap"
            exit 0
          fi
          # Skip if no Linear workspace OAuth'd yet (self-add-repo would fail).
          if [ "$(jq '.linearWorkspaces | length' "$CONFIG")" = "0" ]; then
            echo "linearWorkspaces empty — run 'cyrus self-auth-linear' first"
            exit 0
          fi
          declared='${reposJson}'
          existing=$(jq -r '.repositories[].name' "$CONFIG")
          # Process-substitution (not pipe) so CHANGED survives the loop:
          # piped while-loops run in a subshell and lose parent-scope vars.
          while read -r entry; do
            name=$(echo "$entry" | jq -r '.name')
            url=$(echo "$entry" | jq -r '.url')
            workspace=$(echo "$entry" | jq -r '.workspace')
            labels_csv=$(echo "$entry" | jq -r '.routingLabels | join(",")')
            if echo "$existing" | grep -qFx "$name"; then
              # Reconcile routingLabels in place — `self-add-repo` only fires
              # for new entries, so existing repos would otherwise keep their
              # initial label set forever. Idempotent: jq writes only if the
              # array differs.
              current=$(jq -c --arg n "$name" '.repositories[] | select(.name == $n) | (.routingLabels // [])' "$CONFIG")
              want=$(echo "$entry" | jq -c '.routingLabels')
              if [ "$current" != "$want" ]; then
                echo "~ $name routingLabels: $current → $want"
                tmp=$(mktemp)
                jq --arg n "$name" --argjson labels "$want" \
                  '(.repositories[] | select(.name == $n) | .routingLabels) = $labels' \
                  "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
                CHANGED=1
              else
                echo "✓ $name already in config"
              fi
              continue
            fi
            echo "+ adding $name ($url) labels=[$labels_csv]"
            if node /var/lib/cyrus/src/apps/cli/dist/src/app.js \
                --env-file /run/cyrus/env \
                self-add-repo "$url" "$workspace" -l "$labels_csv"; then
              CHANGED=1
            else
              echo "! failed to add $name (continuing)"
            fi
          done < <(echo "$declared" | jq -c '.[]')
          if [ "$CHANGED" = "1" ]; then
            touch /var/lib/cyrus/.sync-changed
            echo "config.json mutated — cyrus will be restarted"
          fi
        '';
    };

    # ── Declarative GitHub webhook sync ───────────────────────────────────
    # For each declared repository whose URL points at github.com, ensure a
    # webhook exists pointing at our /github-webhook endpoint. Idempotent:
    # POSTs a new hook only if no existing one targets the same URL.
    # Uses the GITHUB_TOKEN already in /run/cyrus/env (sourced from gh CLI).
    systemd.services.cyrus-sync-github-webhooks = lib.mkIf (cfg.repositories != []) {
      description = "Sync declared cyrus repositories with GitHub webhooks";
      wantedBy = [ "multi-user.target" ];
      after = [ "cyrus-env.service" "network-online.target" ];
      requires = [ "cyrus-env.service" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.curl pkgs.jq pkgs.gnused ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.user;
        EnvironmentFile = "/run/cyrus/env";
      };
      script =
        let
          reposJson = builtins.toJSON cfg.repositories;
          # cyrus's /github-webhook endpoint
          hookUrl = "${cfg.baseUrl}/github-webhook";
        in ''
          set -eu
          declared='${reposJson}'
          echo "$declared" | jq -c '.[]' | while read -r entry; do
            url=$(echo "$entry" | jq -r '.url')
            # Extract owner/repo from github.com URLs only; skip others
            # (forgejo, gitlab, ssh-form, etc. — cyrus doesn't manage those
            # webhooks here).
            slug=$(echo "$url" | sed -nE 's|^https?://github\.com/([^/]+/[^/.]+)(\.git)?/?$|\1|p')
            if [ -z "$slug" ]; then
              echo "↷ skipping non-github URL: $url"
              continue
            fi
            existing=$(curl -fsSL \
              -H "Authorization: Bearer $GITHUB_TOKEN" \
              -H "Accept: application/vnd.github+json" \
              "https://api.github.com/repos/$slug/hooks" \
              | jq -r --arg url "${hookUrl}" '.[] | select(.config.url == $url) | .id' \
              || true)
            if [ -n "$existing" ]; then
              echo "✓ $slug already has webhook (id $existing)"
              continue
            fi
            echo "+ creating webhook on $slug → ${hookUrl}"
            body=$(jq -nc \
              --arg url "${hookUrl}" \
              --arg secret "$GITHUB_WEBHOOK_SECRET" \
              '{
                name: "web",
                active: true,
                events: ["issue_comment","pull_request_review","pull_request_review_comment"],
                config: { url: $url, content_type: "json", secret: $secret, insecure_ssl: "0" }
              }')
            curl -fsSL -X POST \
              -H "Authorization: Bearer $GITHUB_TOKEN" \
              -H "Accept: application/vnd.github+json" \
              -d "$body" \
              "https://api.github.com/repos/$slug/hooks" >/dev/null \
              && echo "  → ok" \
              || echo "  ! failed to create webhook for $slug (continuing)"
          done
        '';
    };
  };
}
