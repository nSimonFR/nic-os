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

  # AFFiNE embedding proxy for Ollama on beast.
  #
  # AFFiNE's getEmbeddings() hardcodes "gemini-embedding-001" as the model and
  # calls the Gemini provider (createGoogleGenerativeAI) which uses Google's API
  # format (/v1beta/models/MODEL:embedContent). We proxy that format to Ollama's
  # OpenAI-compatible /v1/embeddings, forwarding to qwen3-embedding:8b with
  # dimensions=1024 (AFFiNE's pgvector column is vector(1024)).
  #
  # Also handles /v1/embeddings passthrough (with dimensions injection) for any
  # future OpenAI-provider embedding calls.
  ollamaHost = "beast";
  ollamaPort = 11434;
  embedProxyPort = 11435;
  embeddingModel = "qwen3-embedding:8b";

  embedProxyScript = pkgs.writeText "affine-embed-proxy.js" ''
    'use strict';
    const http = require('http');

    const UPSTREAM = { hostname: '${ollamaHost}', port: ${toString ollamaPort} };
    const DIMS = 1024;
    const OLLAMA_MODEL = '${embeddingModel}';

    // Gemini embedContent path pattern: /v1beta/models/MODEL:embedContent
    // or just /models/MODEL:embedContent depending on baseURL config
    const GEMINI_SINGLE = /\/models\/[^/:]+:embedContent$/;
    const GEMINI_BATCH  = /\/models\/[^/:]+:batchEmbedContents$/;

    function ollamaEmbed(inputs) {
      return new Promise((resolve, reject) => {
        const body = Buffer.from(JSON.stringify({
          model: OLLAMA_MODEL, input: inputs, dimensions: DIMS
        }));
        const req = http.request({
          ...UPSTREAM,
          path: '/v1/embeddings',
          method: 'POST',
          headers: { 'content-type': 'application/json', 'content-length': body.length },
        }, res => {
          const chunks = [];
          res.on('data', c => chunks.push(c));
          res.on('end', () => {
            try { resolve(JSON.parse(Buffer.concat(chunks).toString())); }
            catch(e) { reject(e); }
          });
        });
        req.on('error', reject);
        req.end(body);
      });
    }

    function forward(req, res, body) {
      const headers = Object.assign({}, req.headers);
      headers['host'] = '${ollamaHost}:${toString ollamaPort}';
      headers['content-length'] = String(body.length);
      const up = http.request({ ...UPSTREAM, path: req.url, method: req.method, headers },
        upRes => { res.writeHead(upRes.statusCode, upRes.headers); upRes.pipe(res); });
      up.on('error', e => { res.writeHead(502); res.end(e.message); });
      up.end(body);
    }

    const server = http.createServer((req, res) => {
      const chunks = [];
      req.on('data', c => chunks.push(c));
      req.on('end', async () => {
        const raw = Buffer.concat(chunks);

        // ── Gemini single embed ───────────────────────────────────────────
        if (req.method === 'POST' && GEMINI_SINGLE.test(req.url)) {
          try {
            const g = JSON.parse(raw.toString());
            // g.content.parts[0].text  OR  g.content.parts = [{text}]
            const text = g?.content?.parts?.[0]?.text ?? "";
            const data = await ollamaEmbed([text]);
            const values = data?.data?.[0]?.embedding ?? [];
            res.writeHead(200, { 'content-type': 'application/json' });
            res.end(JSON.stringify({ embedding: { values } }));
          } catch(e) {
            res.writeHead(500); res.end(e.message);
          }
          return;
        }

        // ── Gemini batch embed ────────────────────────────────────────────
        if (req.method === 'POST' && GEMINI_BATCH.test(req.url)) {
          try {
            const g = JSON.parse(raw.toString());
            const texts = (g?.requests ?? []).map(r => r?.content?.parts?.[0]?.text ?? "");
            const data = await ollamaEmbed(texts);
            const embeddings = (data?.data ?? []).map(d => ({ values: d.embedding }));
            res.writeHead(200, { 'content-type': 'application/json' });
            res.end(JSON.stringify({ embeddings }));
          } catch(e) {
            res.writeHead(500); res.end(e.message);
          }
          return;
        }

        // ── OpenAI /v1/embeddings: inject dimensions if missing ───────────
        if (req.method === 'POST' && req.url === '/v1/embeddings') {
          try {
            const obj = JSON.parse(raw.toString());
            if (!obj.dimensions) {
              obj.dimensions = DIMS;
              forward(req, res, Buffer.from(JSON.stringify(obj)));
              return;
            }
          } catch (_) {}
        }

        // ── Pass through ─────────────────────────────────────────────────
        forward(req, res, raw);
      });
    });

    server.listen(${toString embedProxyPort}, '127.0.0.1', () => {
      process.stderr.write('affine-embed-proxy listening on 127.0.0.1:${toString embedProxyPort} -> ${ollamaHost}:${toString ollamaPort}\n');
    });
  '';

  # AFFiNE config.json — enables Google Calendar + Copilot (embeddings via Ollama on beast).
  # OAuth credentials are injected at runtime from agenix secret (affine-gcal-oauth).
  affineConfigTemplate = builtins.toJSON {
    "$schema" = "https://github.com/toeverything/affine/releases/latest/download/config.schema.json";
    server.name = "NicOS AFFiNE";
    calendar.google = {
      enabled = true;
      clientId = "@GCAL_CLIENT_ID@";
      clientSecret = "@GCAL_CLIENT_SECRET@";
      externalWebhookUrl = "";
      webhookVerificationToken = "";
    };
    copilot = {
      enabled = true;
      # AFFiNE's getEmbeddings() always uses "gemini-embedding-001" via the Gemini
      # provider. The proxy translates Gemini's embedContent API format to Ollama's
      # OpenAI-compatible format, forwarding to qwen3-embedding:8b at 1024 dims.
      "providers.gemini" = {
        apiKey = "ollama";
        baseURL = "http://127.0.0.1:${toString embedProxyPort}";
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

  # ── Ollama embedding proxy ────────────────────────────────────────────
  systemd.services.affine-embed-proxy = {
    description = "AFFiNE embedding proxy (Gemini API -> Ollama qwen3-embedding:8b)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${nodejs}/bin/node ${embedProxyScript}";
      Restart = "on-failure";
      RestartSec = "3s";
      DynamicUser = true;
    };
  };

  # ── AFFiNE server ─────────────────────────────────────────────────────
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
    after = [ "network.target" "affine-migrate.service" "redis-shared.service" "affine-embed-proxy.service" ];
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
      echo "$TEMPLATE" | ${pkgs.gnused}/bin/sed \
        -e "s|@GCAL_CLIENT_ID@|$CID|" \
        -e "s|@GCAL_CLIENT_SECRET@|$CSE|" > "$CONF"
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
