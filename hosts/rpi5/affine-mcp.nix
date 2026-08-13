# DAWNCR0W/affine-mcp-server — write-capable MCP for AFFiNE.
#
# AFFiNE 0.26.6's built-in MCP at /api/workspaces/<wid>/mcp exposes only 3
# read tools (read_document, semantic_search, keyword_search). Issue
# toeverything/AFFiNE#14161 tracks adding writes upstream — not yet shipped.
# This service runs DAWNCR0W's third-party MCP locally and tiny-llm-gate's
# affine bridge proxies to it instead of the native endpoint. Still true on 0.27.3:
# the native endpoint is there but 401s anything except a createMcpCredential
# bearer, and DAWNCR0W registers 87 tools including the markdown writes
# claude-memory-sync depends on (create_doc_from_markdown, replace_doc_with_markdown).
#
# ── How to re-mint AFFINE_COOKIE ────────────────────────────────────────────────
# The secret holds `affine_session=<uuid>`, where the uuid is a row in AFFiNE's
# own session tables. AFFiNE validates the cookie as a plain unsigned id and needs
# no matching auth_sessions row, so a service session is two INSERTs — no account
# password anywhere on the box, and revocable with one DELETE:
#
#   SID=$(uuidgen)
#   sudo -u postgres psql -d affine <<SQL
#   INSERT INTO multiple_users_sessions (id, created_at) VALUES ('$SID', now());
#   INSERT INTO user_sessions (id, session_id, user_id, expires_at, created_at)
#     VALUES (gen_random_uuid()::text, '$SID',
#             (SELECT id FROM users WHERE email = 'nsimon@pm.me'),
#             '2036-01-01 00:00:00+00', now());
#   SQL
#   printf 'affine_session=%s' "$SID" | age -r <age-pub> -r <ed25519-pub> \
#     -o hosts/rpi5/secrets/affine-mcp-cookie.age
#
# The far-future expires_at is the point: a normal browser sign-in gets 15 days, and
# nothing here re-logs-in (the cookie is read once, at construction). This dies if
# the row is deleted — i.e. an AFFiNE-side "sign out everywhere" — in which case
# every tool starts answering "You must sign in first to access this resource."
{ config, pkgs, ... }:
let
  port = 7021;

  affineMcpServer = pkgs.callPackage ../../pkgs/agents/affine-mcp-server.nix { };
in
{
  # Oneshot generates the EnvironmentFile holding the AFFiNE token + the bearer
  # secret tiny-llm-gate uses to authenticate to this server. Same pattern as
  # hosts/rpi5/homepage.nix:60-78 (homepage-dashboard-env.service).
  #
  # restartTriggers reference the encrypted .age store paths (NOT the runtime
  # /run/agenix/* paths, which are stable symlinks). When a secret is rotated
  # and re-encrypted, the .age store path changes → systemd activation re-runs
  # this oneshot → /run/affine-mcp/env is regenerated with the fresh tokens.
  systemd.services.affine-mcp-env = {
    description = "Generate affine-mcp environment file with secrets";
    wantedBy = [ "multi-user.target" ];
    before = [ "affine-mcp.service" ];
    restartTriggers = [
      config.age.secrets.affine-mcp-cookie.file
      config.age.secrets.affine-mcp-http-token.file
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /run/affine-mcp
      cat > /run/affine-mcp/env <<ENVEOF
      MCP_TRANSPORT=http
      # AFFiNE serves at root on :13010 (no NestJS global prefix — it runs at the
      # root of its own :8443 Funnel, see affine.nix), so its API (GraphQL,
      # /api/*) is at the root.
      AFFINE_BASE_URL=http://127.0.0.1:13010
      # Session cookie, NOT AFFINE_API_TOKEN. AFFiNE 0.27.3 removed user access
      # tokens from its API surface — of the token mutations only
      # createMcpCredential survives, and that one is workspace-scoped to AFFiNE's
      # own /mcp endpoint — so the `ut_…` token this used to send 401ed on every
      # tool from the upgrade onward and cannot be re-minted.
      #
      # IMPORTANT: do not "keep the token as well, just in case". The server picks
      # auth in priority order and treats a bearer as proof of authentication
      # (GraphQLClient sets authenticated = true on any non-empty bearer), so a dead
      # AFFINE_API_TOKEN shadows the cookie and puts the service straight back to
      # 401ing. It is cookie or nothing.
      AFFINE_COOKIE=$(cat ${config.age.secrets.affine-mcp-cookie.path})
      # `bearer` here is INBOUND auth (how tiny-llm-gate authenticates TO this
      # server, via affine-mcp-http-token), unrelated to how this server
      # authenticates to AFFiNE above.
      AFFINE_MCP_AUTH_MODE=bearer
      AFFINE_MCP_HTTP_TOKEN=$(cat ${config.age.secrets.affine-mcp-http-token.path})
      AFFINE_MCP_HTTP_HOST=127.0.0.1
      PORT=${toString port}
      ENVEOF
      chmod 0400 /run/affine-mcp/env
    '';
  };

  systemd.services.affine-mcp = {
    description = "AFFiNE MCP server (DAWNCR0W) — write-capable bridge";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "affine.service" "affine-mcp-env.service" ];
    wants = [ "affine.service" ];
    requires = [ "affine-mcp-env.service" ];
    # Pick up rotated tokens on rebuild — restart triggers fire on .age
    # store-path change, identical set as affine-mcp-env so both restart in
    # lockstep and the consumer reads the freshly-regenerated env file.
    restartTriggers = [
      config.age.secrets.affine-mcp-cookie.file
      config.age.secrets.affine-mcp-http-token.file
    ];

    serviceConfig = {
      DynamicUser = true;
      RuntimeDirectory = "affine-mcp";
      # The env file is written into /run/affine-mcp by the separate
      # affine-mcp-env oneshot (RemainAfterExit). Default RuntimeDirectoryPreserve=no
      # makes systemd delete /run/affine-mcp on every stop of THIS service, so any
      # crash- or rebuild-restart wipes the env file — and the oneshot, still
      # "active", never regenerates it, leaving this unit in a permanent
      # "Failed to load environment files" crash-loop. Preserve the dir so the
      # injected env file survives restarts (only cleared at reboot, where the
      # oneshot reruns before us via the before= ordering).
      RuntimeDirectoryPreserve = "yes";
      EnvironmentFile = "/run/affine-mcp/env";
      ExecStart = "${pkgs.nodejs_22}/bin/node ${affineMcpServer}/lib/node_modules/affine-mcp-server/dist/index.js";
      Restart = "on-failure";
      RestartSec = 5;
      MemoryMax = "192M";

      # Hardening — DAWNCR0W only needs network + read access to its own
      # node_modules; everything else can be sandboxed.
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictNamespaces = true;
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.affine-mcp = {
    backup        = [ "none" ];
    backupNote    = "stateless bridge — every document it serves lives in AFFiNE's Postgres";
    heavyUnits    = [ "affine-mcp.service" ];
    heavyPriority = 60;

    # No tile: an internal MCP gateway, not user-facing. Backend is the
    # tiny-llm-gate mount rather than the service's own bind.
    public = {
      order   = 210;
      port    = 7020;
      backend = "http://127.0.0.1:4001/mcp/affine";
    };
  };
}
