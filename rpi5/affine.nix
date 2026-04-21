{ pkgs, lib, pgHost, pgPort, redisHost, redisPort, tailnetFqdn, ... }:
let
  version = "0.26.6";
  port = 13010;  # internal; Tailscale Serve proxies 3010 → 13010
  dataDir = "/var/lib/affine";
  appDir = "${dataDir}/app";

  openssl3 = pkgs.openssl_3;
  nodejs = pkgs.nodejs_22;
  rpath = lib.makeLibraryPath [ openssl3 pkgs.glibc pkgs.stdenv.cc.cc.lib ];
  interpreter = "${pkgs.glibc}/lib/ld-linux-aarch64.so.1";

  # AFFiNE config.json — enables Google Calendar + Copilot (via LiteLLM gateway).
  # OAuth credentials are injected at runtime from agenix secret (affine-gcal-oauth).
  affineConfigTemplate = builtins.toJSON {
    "$schema" = "https://github.com/toeverything/affine/releases/latest/download/config.schema.json";
    server.name = "NicOS AFFiNE";
    # Desktop app sends Origin: assets://. which isn't in the default
    # allowedOrigin list (localhost, 127.0.0.1), causing link-preview
    # and image-proxy requests to be rejected with "Invalid header".
    "worker.allowedOrigin" = [ "localhost" "127.0.0.1" "assets://." ];
    calendar.google = {
      enabled = true;
      clientId = "@GCAL_CLIENT_ID@";
      clientSecret = "@GCAL_CLIENT_SECRET@";
      externalWebhookUrl = "";
      webhookVerificationToken = "";
    };
    copilot = {
      enabled = true;
      # Gemini-only copilot provider — points at tiny-llm-gate on :4001
      # which serves the native /v1beta/models/{m}:{generate,stream,embed}Content
      # endpoints and translates them to OpenAI wire format for Ollama.
      #
      # Why no OpenAI provider: AFFiNE v0.26.6's `OpenAIProvider` class has a
      # hardcoded model list (GPT-4o, input [Text, Image], output [Text, Object])
      # with no embedding-capable model. When both providers are registered,
      # `ProductionEmbeddingClient` picks OpenAI first and fails with
      #   `copilot_provider_not_supported: Copilot provider openai does not
      #    support output type embedding`
      # before any network call. Removing the OpenAI provider forces the
      # factory to use Gemini, which does advertise embedding capability.
      # Chat, structured output (session title generation), AND embeddings
      # all route through the same Gemini provider.
      "providers.gemini" = {
        apiKey = "ollama";
        # baseURL MUST include /v1beta. AFFiNE's Gemini provider uses the
        # Vercel `@ai-sdk/google` library which appends `/models/{id}:action`
        # directly to the configured baseURL. Google's public default is
        # `https://generativelanguage.googleapis.com/v1beta`, so our override
        # must end in `/v1beta` too — otherwise AFFiNE hits
        # http://127.0.0.1:4001/models/... which tiny-llm-gate's router
        # returns 404 for.
        baseURL = "http://127.0.0.1:4001/v1beta";
      };
    };
  };

  dbName = "affine";
  dbUser = "affine";
  dbUrl = "postgresql://${dbUser}@localhost:${toString pgPort}/${dbName}?host=/run/postgresql";

  # Update script: pulls arm64 image, extracts app layer, patches binaries for NixOS
  updateScript = pkgs.writeShellScript "affine-update" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.skopeo pkgs.jq pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.patchelf pkgs.findutils ]}"
    export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

    TAG="''${1:-stable}"
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    echo "Pulling ghcr.io/toeverything/affine:$TAG (arm64)..."
    skopeo copy --override-arch arm64 \
      "docker://ghcr.io/toeverything/affine:$TAG" \
      "dir:$WORK/image"

    # Find the app layer (largest layer, contains /app)
    APP_LAYER=$(ls -S "$WORK/image"/*.* 2>/dev/null | head -1)
    # More robust: parse manifest for layers, find the one with /app
    MANIFEST="$WORK/image/manifest.json"
    for digest in $(jq -r '.layers[].digest' "$MANIFEST"); do
      BLOB="$WORK/image/$(echo "$digest" | cut -d: -f2)"
      if tar tzf "$BLOB" 2>/dev/null | grep -q "^app/dist/main.js$"; then
        APP_LAYER="$BLOB"
        break
      fi
    done

    if [ -z "$APP_LAYER" ]; then
      echo "ERROR: could not find app layer in image"
      exit 1
    fi

    echo "Extracting app from layer..."
    mkdir -p "$WORK/extract"
    tar xzf "$APP_LAYER" -C "$WORK/extract"

    echo "Patching native binaries for NixOS..."
    # Patch .node shared libraries (prisma, argon2, crc32, napi, etc.)
    find "$WORK/extract/app" -name "*.node" -type f | while read -r f; do
      patchelf --set-rpath "${rpath}" "$f" 2>/dev/null || true
    done

    # Patch schema-engine binary
    SE="$WORK/extract/app/node_modules/@prisma/engines/schema-engine-linux-arm64-openssl-3.0.x"
    if [ -f "$SE" ]; then
      chmod +x "$SE"
      patchelf --set-interpreter "${interpreter}" --set-rpath "${rpath}" "$SE"
    fi

    # Atomic swap
    echo "Installing to ${appDir}..."
    rm -rf "${appDir}.new"
    mv "$WORK/extract/app" "${appDir}.new"

    if [ -d "${appDir}" ]; then
      mv "${appDir}" "${appDir}.old"
    fi
    mv "${appDir}.new" "${appDir}"
    rm -rf "${appDir}.old"

    VERSION=$(jq -r .version "${appDir}/package.json")
    echo "AFFiNE $VERSION installed. Restart the service:"
    echo "  sudo systemctl restart affine-migrate affine"
  '';
in
{
  # ── PostgreSQL: database + pgvector extension ──────────────────────────
  services.postgresql = {
    ensureUsers = [{ name = dbUser; ensureClauses.login = true; }];
    ensureDatabases = [ dbName ];
    extensions = ps: with ps; [ pgvector ];
  };

  systemd.services.affine-pg-setup = {
    description = "AFFiNE PostgreSQL setup";
    after = [ "postgresql.service" "postgresql-setup.service" ];
    requires = [ "postgresql.service" "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      ${pkgs.postgresql}/bin/psql -d ${dbName} -c "CREATE EXTENSION IF NOT EXISTS vector;"
      ${pkgs.postgresql}/bin/psql -c "ALTER DATABASE ${dbName} OWNER TO ${dbUser};"
    '';
  };

  # ── Prisma migrations ─────────────────────────────────────────────────
  systemd.services.affine-migrate = {
    description = "AFFiNE database migrations";
    after = [ "affine-pg-setup.service" ];
    requires = [ "affine-pg-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = dbUser;
    };
    environment.DATABASE_URL = dbUrl;
    script = ''
      export PRISMA_QUERY_ENGINE_LIBRARY="${appDir}/node_modules/@prisma/engines/libquery_engine-linux-arm64-openssl-3.0.x.so.node"
      export PRISMA_SCHEMA_ENGINE_BINARY="${appDir}/node_modules/@prisma/engines/schema-engine-linux-arm64-openssl-3.0.x"
      exec ${nodejs}/bin/node ${appDir}/node_modules/.bin/prisma migrate deploy --schema ${appDir}/schema.prisma
    '';
  };

  # ── AFFiNE server ─────────────────────────────────────────────────────
  # (Previous `affine-embed-proxy` Node.js service was absorbed by
  # tiny-llm-gate's Gemini frontend in v0.3.0.)
  users.users.${dbUser} = {
    isSystemUser = true;
    group = dbUser;
    home = dataDir;
  };
  users.groups.${dbUser} = { };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 ${dbUser} ${dbUser} -"
    "d ${dataDir}/storage 0750 ${dbUser} ${dbUser} -"
    "Z ${dataDir}/app 0755 ${dbUser} ${dbUser} -"
    "d ${dataDir}/.affine 0750 ${dbUser} ${dbUser} -"
    "d ${dataDir}/.affine/config 0750 ${dbUser} ${dbUser} -"
  ];

  systemd.services.affine = {
    description = "AFFiNE";
    after = [ "network.target" "affine-migrate.service" "redis-shared.service" "tiny-llm-gate.service" ];
    requires = [ "affine-migrate.service" ];
    wants = [ "redis-shared.service" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      NODE_ENV = "production";
      HOME = dataDir;
      AFFINE_SERVER_HOST = "127.0.0.1";
      AFFINE_SERVER_PORT = toString port;
      AFFINE_SERVER_EXTERNAL_URL = "https://${tailnetFqdn}:3010";
      DATABASE_URL = dbUrl;
      REDIS_SERVER_HOST = redisHost;
      REDIS_SERVER_PORT = toString redisPort;
      AFFINE_STORAGE_PATH = "${dataDir}/storage";
      PRISMA_QUERY_ENGINE_LIBRARY = "${appDir}/node_modules/@prisma/engines/libquery_engine-linux-arm64-openssl-3.0.x.so.node";
      PRISMA_SCHEMA_ENGINE_BINARY = "${appDir}/node_modules/@prisma/engines/schema-engine-linux-arm64-openssl-3.0.x";
    };
    # Inject Google Calendar OAuth credentials from agenix into config.json
    script = ''
      CONF="${dataDir}/.affine/config/config.json"
      OAUTH=$(cat /run/agenix/affine-gcal-oauth)
      CID=$(echo "$OAUTH" | ${pkgs.jq}/bin/jq -r .clientId)
      CSE=$(echo "$OAUTH" | ${pkgs.jq}/bin/jq -r .clientSecret)
      TEMPLATE='${affineConfigTemplate}'
      # Use bash parameter substitution for safe literal replacement
      # (sed breaks if CID/CSE contain | & / or other regex metacharacters)
      RESULT="''${TEMPLATE//@GCAL_CLIENT_ID@/$CID}"
      RESULT="''${RESULT//@GCAL_CLIENT_SECRET@/$CSE}"
      echo "$RESULT" > "$CONF"

      # Patch hardcoded cloud worker URLs in client JS bundle.
      # The desktop app (Electron) does not override these fallback
      # endpoints via DI, so link-preview/image-proxy requests go to
      # the cloud worker instead of our local server.
      CLOUD="https://affine-worker.toeverything.workers.dev"
      SELF="https://${tailnetFqdn}:3010"
      for f in ${appDir}/static/js/*.js; do
        if grep -q "$CLOUD" "$f" 2>/dev/null; then
          ${pkgs.gnused}/bin/sed -i "s|$CLOUD|$SELF|g" "$f"
        fi
      done

      # Allow image-proxy requests with no Origin/Referer header.
      # Electron <img> tags don't send either header, causing the
      # server to reject with "Invalid header". Change the check
      # from "reject if neither matches" to "reject only if a
      # header is present but doesn't match".
      ${pkgs.gnused}/bin/sed -i 's#if(!n&&!a)throw this.logger.error("Invalid Origin","ERROR"#if(!n\&\&!a\&\&(o||i))throw this.logger.error("Invalid Origin","ERROR"#' ${appDir}/dist/main.js

      exec ${nodejs}/bin/node ${appDir}/dist/main.js
    '';
    serviceConfig = {
      Type = "simple";
      User = dbUser;
      Group = dbUser;
      WorkingDirectory = appDir;
      Restart = "on-failure";
      RestartSec = "5s";
      PrivateUsers = lib.mkForce false;
    };
  };

  # Make update script available system-wide
  environment.systemPackages = [ (pkgs.writeShellScriptBin "affine-update" (builtins.readFile updateScript)) ];
}
