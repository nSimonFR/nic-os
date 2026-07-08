# Reactive Resume — self-hosted resume builder, native (no container).
#
# Packaging + the app service itself now live in the reactive-resume-nix flake
# (github:nSimonFR/reactive-resume-nix, `services.reactive-resume`), same model
# as sure-nix / airtrail-nix. This file is the nic-os-side GLUE only:
#   * PostgreSQL database + role (reuses the shared cluster; no Redis, no S3).
#   * reactive-resume-pg-setup — sets the role password + DB ownership from agenix.
#   * reactive-resume-env — writes the runtime env file (DATABASE_URL + AUTH_SECRET).
#   * services.reactive-resume — the flake module, wired to the above.
#   * socket-activated idle-sleep (rpi5/lib/socket-activate.nix): the backend
#     binds 127.0.0.1:13337 and a proxy on 127.0.0.1:13336 (what the 443 nginx
#     path-mux front-proxy /rxresume/ → here) wakes it on first request and stops
#     it after 10 min idle — reclaiming its ~367 MB RSS on this 4 GB Pi. The AI
#     agent workspace IS enabled (REDIS_URL → shared Redis DB 7 + ENCRYPTION_SECRET),
#     which adds long-lived SSE while an agent chat is open; socket-activation stays
#     safe because that activity resets the idle timer and idle-stop only fires once
#     the chat closes. JWT auth (stable AUTH_SECRET) survives a cold wake.
#     Public exposure means internet scanners can wake it more often than tailnet.
#
# Migrations self-apply on boot inside the app (apps/server/src/startup/checks.ts),
# so there is no migrate oneshot — the app just needs a reachable DB.
{ config, lib, pkgs, pgHost, pgPort, redisHost, redisPort, tailnetFqdn, ... }:
let
  osUser = "reactive-resume"; # systemd/service identity (hyphen per convention)
  dbUser = "reactive_resume"; # postgres role == db name (no hyphen quoting needed)
  dbName = "reactive_resume";
  dataDir = "/var/lib/reactive-resume";

  backendPort = 13337; # real Node bind (localhost only)
  proxyPort   = 13336; # socket-activate proxy listen; front-proxy /rxresume/ → here
  # Served publicly behind the 443 nginx path-mux (front-proxy.nix) at /rxresume.
  # appUrl carries the sub-path (server builds absolute PDF/storage/share URLs
  # from it) and basePath is the Vite build-time base — the two MUST match.
  basePath = "/rxresume";
  appUrl = "https://${tailnetFqdn}${basePath}";

  envFile = "/run/reactive-resume/env";
in
{
  # ── PostgreSQL: reactive_resume database + role ───────────────────────────
  services.postgresql = {
    ensureDatabases = [ dbName ];
    ensureUsers = [{ name = dbUser; }];
    # Password auth over TCP for the app (matches sure.nix). Peer auth over the
    # socket is avoided so DATABASE_URL stays a plain postgres:// TCP URL.
    authentication = lib.mkAfter ''
      host  ${dbName}  ${dbUser}  ${pgHost}/32  scram-sha-256
    '';
  };

  # Set the role password + DB ownership from agenix (ensurePasswordFile is not in
  # NixOS 25.11). MUST order after postgresql-setup.service (which runs ensureUsers)
  # or it races with "role does not exist" on first boot.
  systemd.services.reactive-resume-pg-setup = {
    description = "Set reactive_resume PostgreSQL password + ownership";
    after = [ "postgresql.service" "postgresql-setup.service" ];
    requires = [ "postgresql.service" "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    # Rerun ALTER USER when the password rotates. Without this, the RemainAfterExit
    # oneshot stays "active" and Postgres keeps the OLD password, while
    # reactive-resume-env + the app pick up the NEW one → auth failure on restart.
    # The app's After=reactive-resume-pg-setup ordering ensures this reruns first.
    restartTriggers = [ config.age.secrets.reactive-resume-db-password.file ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    };
    script = ''
      password=$(cat /run/agenix/reactive-resume-db-password)
      # :'pw' interpolation only works via stdin/-f, not -c.
      ${pkgs.postgresql}/bin/psql -v pw="$password" <<< "ALTER USER ${dbUser} WITH PASSWORD :'pw';"
      ${pkgs.postgresql}/bin/psql -c "ALTER DATABASE ${dbName} OWNER TO ${dbUser};"
    '';
  };

  # ── Runtime env file (DATABASE_URL with password + AUTH_SECRET) ───────────
  # Pattern from affine-mcp-env / homepage-dashboard-env. Written by root; the
  # EnvironmentFile is read by systemd (as root) before dropping to ${osUser},
  # so root-only 0400 is sufficient. We mkdir /run/reactive-resume in-script
  # (no RuntimeDirectory=) to avoid the known RuntimeDirectory-wipe crash-loop.
  systemd.services.reactive-resume-env = {
    description = "Generate Reactive Resume environment file with secrets";
    wantedBy = [ "multi-user.target" ];
    before = [ "reactive-resume.service" ];
    restartTriggers = [
      config.age.secrets.reactive-resume-db-password.file
      config.age.secrets.reactive-resume-auth-secret.file
      config.age.secrets.reactive-resume-encryption-secret.file
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /run/reactive-resume
      db_password=$(cat /run/agenix/reactive-resume-db-password)
      auth_secret=$(cat /run/agenix/reactive-resume-auth-secret)
      encryption_secret=$(cat /run/agenix/reactive-resume-encryption-secret)
      cat > ${envFile} <<ENVEOF
      DATABASE_URL=postgresql://${dbUser}:$db_password@${pgHost}:${toString pgPort}/${dbName}
      AUTH_SECRET=$auth_secret
      ENCRYPTION_SECRET=$encryption_secret
      ENVEOF
      chmod 0400 ${envFile}
    '';
  };

  # ── Application (reactive-resume-nix flake module) ────────────────────────
  # The module owns the service user/group, state tmpfiles, and the systemd unit
  # (with the hardening block). We supply the bind, storage path, env file, and
  # the Pi-friendly feature flags / heap tuning.
  services.reactive-resume = {
    enable = true;
    host = "127.0.0.1";
    port = backendPort;
    appUrl = appUrl;
    # Build the SPA for the /rxresume sub-path (Vite base + router basepath +
    # client/server URL bases). Rebuilds the package from the reactive-resume-nix
    # base-path patch. MUST end with a slash and match appUrl's path.
    appBasePath = "${basePath}/";
    storagePath = "${dataDir}/data";
    environmentFile = envFile;
    settings = {
      # Recommended on constrained hardware (upstream .env.example): skip sharp.
      FLAG_DISABLE_IMAGE_PROCESSING = "true";
      # Single-user instance: no public registration (existing users unaffected).
      FLAG_DISABLE_SIGNUPS = "true";
      # AI providers (Settings → AI): allow a provider baseURL on the loopback
      # tiny-llm-gate (http://127.0.0.1:4001/v1). Without this, the AI url-policy
      # rejects non-https / private-host base URLs. ENCRYPTION_SECRET (from the
      # env file) enables the AI-providers feature.
      FLAG_ALLOW_UNSAFE_AI_BASE_URL = "true";
      # AI agent workspace (chat assistant that applies edits): needs REDIS_URL +
      # ENCRYPTION_SECRET. Point at the shared Redis (databases.nix) on a spare DB
      # index (0-6 are used by immich/dawarich/affine/nextcloud/etc.). Enabling
      # this adds long-lived SSE while a chat is open — fine under socket-activation
      # (activity resets the idle timer; it still stops after idleSec once the chat
      # closes), but agent jobs only run while the service is awake (HTTP-woken).
      REDIS_URL = "redis://${redisHost}:${toString redisPort}/7";
      # 4 GiB RPi5 memory hygiene (mirrors affine.nix / sure.nix).
      NODE_OPTIONS = "--max-old-space-size=384";
      MALLOC_ARENA_MAX = "2";
    };
  };

  # Augment the flake module's service with nic-os ordering + secret triggers.
  # The env/pg-setup oneshots keep their own wantedBy=multi-user.target, so they
  # run at boot and are ready ("active (exited)") before the first cold wake.
  systemd.services.reactive-resume = {
    after = [ "reactive-resume-pg-setup.service" "reactive-resume-env.service" ];
    requires = [ "reactive-resume-pg-setup.service" "reactive-resume-env.service" ];
    restartTriggers = [
      config.age.secrets.reactive-resume-db-password.file
      config.age.secrets.reactive-resume-auth-secret.file
      config.age.secrets.reactive-resume-encryption-secret.file
    ];
  };

  # ── Socket-activated idle sleep (rpi5/lib/socket-activate.nix) ────────────
  # Proxy on :13336 lazily starts reactive-resume.service on first connection and
  # stops it after idleSec. readyProbe gates on /api/health because the Node
  # server binds ~30s after systemd "active" (startup + idempotent boot
  # migrations) — the proxy holds the first connection until the backend answers.
  services.socketActivate.reactive-resume = {
    enable   = true;
    realUnit = "reactive-resume.service";
    listen   = [ "127.0.0.1:${toString proxyPort}" ];
    backend  = "127.0.0.1:${toString backendPort}";
    idleSec  = 600;
    readyProbe = {
      url          = "http://127.0.0.1:${toString backendPort}/api/health";
      expectStatus = 200;
      timeoutSec   = 120;
    };
  };
}
