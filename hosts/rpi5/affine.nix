{ pkgs, lib, pgHost, pgPort, redisHost, redisPort, tailnetFqdn, tinyLlmGateUrl, ... }:
let
  # The pinned upstream image tag, and the only place the version is written.
  # affine-sync below installs whatever this says, so a Renovate bump of this
  # line is a real upgrade rather than a comment change. Beta tags (AFFiNE cuts
  # one most days) are filtered out in renovate.json.
  # renovate: datasource=docker depName=ghcr.io/toeverything/affine
  version = "0.27.3";
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
      #
      # Why bypass Aperture: Aperture's compatibility flags only cover the
      # chat-shaped actions (`gemini_generate_content` → :generateContent /
      # :streamGenerateContent). It rejects `:embedContent` with HTTP 400
      # `unsupported Gemini action: embedContent`, which @ai-sdk/google
      # silently parses into an empty embedding array → AFFiNE's
      # `CopilotEmbeddingJob` reports `Expected 1 embeddings, got 0` for
      # every doc and the workspace embedding queue stalls. Until Aperture
      # ships an embedding-shaped compatibility flag, we hit tiny-llm-gate
      # directly. Trade-off: AFFiNE AI traffic (chat + embeddings) bypasses
      # Aperture's observability layer.
      "providers.gemini" = {
        apiKey = "ollama";
        # baseURL MUST include /v1beta. AFFiNE's Gemini provider uses the
        # Vercel `@ai-sdk/google` library which appends `/models/{id}:action`
        # directly to the configured baseURL. Google's public default is
        # `https://generativelanguage.googleapis.com/v1beta`, so our override
        # must end in `/v1beta` too — otherwise AFFiNE hits
        # http://127.0.0.1:4001/models/... which tiny-llm-gate's router
        # returns 404 for.
        baseURL = "${tinyLlmGateUrl}/v1beta";
      };
    };
  };

  dbName = "affine";
  dbUser = "affine";
  dbUrl = "postgresql://${dbUser}@localhost:${toString pgPort}/${dbName}?host=/run/postgresql";

  # skopeo refuses to pull without a trust policy and looks for one only under
  # $HOME and /etc/containers, neither of which NixOS populates. This worked by
  # hand purely because the original install left a policy.json in nsimon's
  # dotfiles in April; as a service running as root it found nothing and died.
  # Ship the policy instead of depending on that file — it is the same
  # accept-anything default a distro would install, and the pull is a pinned tag
  # over TLS from ghcr.
  skopeoPolicy = pkgs.writeText "affine-skopeo-policy.json" (builtins.toJSON {
    default = [ { type = "insecureAcceptAnything"; } ];
  });

  # Update script: pulls arm64 image, extracts app layer, patches binaries for NixOS
  updateScript = pkgs.writeShellScript "affine-update" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.skopeo pkgs.jq pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.patchelf pkgs.findutils pkgs.gnugrep ]}"
    export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

    # Defaults to the pinned version, not `stable` — otherwise `version` above
    # and what actually lands in ${appDir} drift apart silently, which is how
    # the pin sat at 0.26.6 while claiming to be the source of truth.
    TAG="''${1:-${version}}"
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    echo "Pulling ghcr.io/toeverything/affine:$TAG (arm64)..."
    skopeo copy --policy ${skopeoPolicy} --override-arch arm64 \
      "docker://ghcr.io/toeverything/affine:$TAG" \
      "dir:$WORK/image"

    # Find the app layer by asking each one whether it holds the entrypoint.
    #
    # The subshell drops pipefail for the duration: `grep -q` exits at the
    # first match and SIGPIPEs `tar`, so under pipefail the pipeline reports
    # failure precisely when it succeeds. That, plus grep missing from PATH
    # above, is why this loop never once matched and the "largest layer"
    # fallback it used to seed was quietly doing all the work. The fallback is
    # gone rather than fixed: it turned an unidentifiable image into a
    # confusing tar error several steps downstream.
    APP_LAYER=""
    MANIFEST="$WORK/image/manifest.json"
    for digest in $(jq -r '.layers[].digest' "$MANIFEST"); do
      BLOB="$WORK/image/$(echo "$digest" | cut -d: -f2)"
      if ( set +o pipefail; tar tzf "$BLOB" 2>/dev/null | grep -q "^app/dist/main.js$" ); then
        APP_LAYER="$BLOB"
        break
      fi
    done

    if [ -z "$APP_LAYER" ]; then
      echo "ERROR: no layer in ghcr.io/toeverything/affine:$TAG contains app/dist/main.js" >&2
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

    # The layer unpacks as root; the service runs as ${dbUser}. tmpfiles' `Z`
    # rule fixes this at activation, but affine-sync can run after that point,
    # so don't rely on the ordering.
    chown -R ${dbUser}:${dbUser} "${appDir}"

    VERSION=$(jq -r .version "${appDir}/package.json")
    echo "AFFiNE $VERSION installed. Restart the service:"
    echo "  sudo systemctl restart affine-migrate affine"
  '';
in
{
  # ── PostgreSQL: database + pgvector extension ──────────────────────────
  # pgvector is not in the contrib set, so the shared library has to be added to
  # the server package itself — that stays here; pgRole only issues the SQL
  # CREATE EXTENSION. No passwordFile: AFFiNE connects over the Unix socket
  # (dbUrl carries ?host=/run/postgresql), so it needs no pg_hba TCP rule.
  services.postgresql.extensions = ps: with ps; [ pgvector ];

  nic.pgRole.affine = {
    db          = dbName;
    user        = dbUser;
    login       = true;
    extensions  = [ "vector" ];
    description = "AFFiNE PostgreSQL setup";
  };

  # ── Version reconciliation ────────────────────────────────────────────
  # What turns a Renovate bump of `version` into an actual upgrade: compare the
  # installed bundle against the pin on every activation and re-run the updater
  # when they differ. Matching versions cost one jq call and no network.
  #
  # The unit text embeds `version`, so a bump changes the unit and systemd
  # restarts it on switch; an unchanged version leaves RemainAfterExit=true
  # holding, and nothing re-runs.
  #
  # `wants`, not `requires`, downstream: if ghcr is unreachable the pull fails,
  # systemd-failed-alert fires, and AFFiNE keeps serving the version already on
  # disk instead of being held down by a network hiccup.
  systemd.services.affine-sync = {
    description = "Reconcile installed AFFiNE with the pinned version";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      INSTALLED=$(${pkgs.jq}/bin/jq -re .version ${appDir}/package.json 2>/dev/null || echo none)
      if [ "$INSTALLED" = "${version}" ]; then
        echo "AFFiNE ${version} already installed"
        exit 0
      fi
      echo "AFFiNE $INSTALLED installed, pinned at ${version} — updating"
      exec ${updateScript} ${version}
    '';
  };

  # ── Prisma migrations ─────────────────────────────────────────────────
  systemd.services.affine-migrate = {
    description = "AFFiNE database migrations";
    after = [ "affine-pg-setup.service" "affine-sync.service" ];
    requires = [ "affine-pg-setup.service" ];
    wants = [ "affine-sync.service" ];
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
      # AFFiNE runs at the ROOT of its own Tailscale Funnel on :8443 (see
      # nic.services.affine.public below). No NestJS global prefix — its SPA router insists
      # on root paths (a /affine sub-path made the client navigate to root
      # /workspace/… and never held the base), so serving at root is the only
      # clean option. Internal callers on :13010 hit routes at root (/graphql,
      # /api/*) with no prefix.
      AFFINE_SERVER_EXTERNAL_URL = "https://${tailnetFqdn}:8443";
      DATABASE_URL = dbUrl;
      REDIS_SERVER_HOST = redisHost;
      REDIS_SERVER_PORT = toString redisPort;
      AFFINE_STORAGE_PATH = "${dataDir}/storage";
      PRISMA_QUERY_ENGINE_LIBRARY = "${appDir}/node_modules/@prisma/engines/libquery_engine-linux-arm64-openssl-3.0.x.so.node";
      PRISMA_SCHEMA_ENGINE_BINARY = "${appDir}/node_modules/@prisma/engines/schema-engine-linux-arm64-openssl-3.0.x";
      # RAM optimizations for single-user instance on 4GB RPi5
      # 384MB: bulk doc-creation + parallel copilot.embedding.docs jobs OOM'd
      # 11× at 192MB during slite import; 1× at 384MB. RSS settles ~580MB.
      NODE_OPTIONS = "--max-old-space-size=384";
      MALLOC_ARENA_MAX = "2";
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

      # ── Bundle patches ──────────────────────────────────────────────
      # Both rewrite minified JS, so nothing anchors them but esbuild's
      # output, and both re-run on every start (the swap in affine-sync
      # drops an unpatched bundle in place). Each therefore asserts its
      # own post-condition rather than its match count: applying cleanly
      # and having-been-applied-already are both success, a pattern that
      # no longer matches is a hard failure.
      #
      # This is not hypothetical. 0.26.6 → 0.27.3 renamed the minifier's
      # locals in the origin check (`if(!n&&!a)` → `if(!a&&!n)`), which
      # the old fixed-string sed would have skipped in silence, leaving
      # the desktop app's images broken with the unit reporting healthy.

      # Cloud worker URL → our own origin. The desktop app (Electron)
      # does not override these fallback endpoints via DI, so
      # link-preview/image-proxy requests would otherwise go to the
      # cloud worker instead of our local server.
      CLOUD="https://affine-worker.toeverything.workers.dev"
      SELF="https://${tailnetFqdn}/affine"
      for f in ${appDir}/static/js/*.js; do
        if grep -q "$CLOUD" "$f" 2>/dev/null; then
          ${pkgs.gnused}/bin/sed -i "s|$CLOUD|$SELF|g" "$f"
        fi
      done
      if grep -rq "$CLOUD" ${appDir}/static/js/ 2>/dev/null; then
        echo "affine: cloud worker URL survived patching — check static/js" >&2
        exit 1
      fi

      # Allow image-proxy requests with no Origin/Referer header.
      # Electron <img> tags don't send either header, causing the
      # server to reject with "Invalid header". Change the check
      # from "reject if neither matches" to "reject only if a
      # header is present but doesn't match".
      #
      # The two header locals are read back out of the error payload
      # (`{origin:…,referer:…}`) instead of being hardcoded, so the
      # patch survives a reshuffle of the minifier's names. Only the
      # image-proxy site carries the "ERROR" argument; the link-preview
      # check next to it is deliberately left alone.
      ${pkgs.gnused}/bin/sed -E -i 's#if\(!([A-Za-z0-9_$]+)&&!([A-Za-z0-9_$]+)\)throw this\.logger\.error\("Invalid Origin","ERROR",\{origin:([A-Za-z0-9_$]+),referer:([A-Za-z0-9_$]+)\}#if(!\1\&\&!\2\&\&(\3||\4))throw this.logger.error("Invalid Origin","ERROR",{origin:\3,referer:\4}#g' ${appDir}/dist/main.js
      if ! grep -qE 'if\(!([A-Za-z0-9_$]+)&&!([A-Za-z0-9_$]+)&&\(([A-Za-z0-9_$]+)\|\|([A-Za-z0-9_$]+)\)\)throw this\.logger\.error\("Invalid Origin","ERROR"' ${appDir}/dist/main.js; then
        echo "affine: image-proxy origin check did not match — the ${version} bundle changed shape" >&2
        exit 1
      fi

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
      MemoryMax = "384M";
    };
  };

  # Make update script available system-wide
  environment.systemPackages = [ (pkgs.writeShellScriptBin "affine-update" (builtins.readFile updateScript)) ];

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  # Doc content lives in Postgres, which is dumped nightly. Worth knowing:
  # attachment blobs under /var/lib/affine/storage are on the SSD, outside restic's
  # /mnt/data scope — pre-existing, not addressed here.
  nic.services.affine = {
    backup            = [ "postgres" ];
    postgresDatabases = [ "affine" ];
    heavyUnits        = [ "affine.service" ];
    heavyPriority     = 50;

    # NOT behind the 443 path-mux: AFFiNE's SPA router insists on root paths, so
    # it runs at the root of its own 8443 funnel.
    public = {
      order   = 20;
      port    = 8443;
      backend = "http://127.0.0.1:13010";
      funnel  = true;
      tile = {
        name        = "AFFiNE";
        icon        = "affine.svg";
        category    = "Apps";
        description = "Collaborative docs";
        # Was a customapi POSTing GraphQL straight at AFFiNE every 10s, and it read
        # workspaces[0] — the 3-doc scratch workspace, not the main one. The
        # aggregator sums all four workspaces and asks once a day.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/affine";
          refreshInterval = 3600000;
          mappings = [
            { field = "workspaces"; label = "Workspaces"; format = "number"; }
            { field = "docs";       label = "Docs";       format = "number"; }
            { field = "storage";    label = "Storage";    format = "bytes"; }
          ];
        };
      };
    };
  };
}
