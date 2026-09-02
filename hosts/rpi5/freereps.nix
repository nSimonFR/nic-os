# hosts/rpi5/freereps.nix
#
# FreeReps — self-hosted Apple Health server (meltforce/FreeReps). The package
# is in-repo (pkgs/services/freereps.nix, via pkgs/overlay.nix) rather than an
# external flake, because upstream ships only a docker-compose stack; there is
# no module to enable, so the unit is spelled out here.
#
# The iPhone side is the free App Store app (id6760661354). It takes an
# arbitrary host+port, so it talks to the Tailscale Serve origin below — which
# means the phone needs Tailscale, exactly like every other tailnet-only service
# here.
#
# ── ⚠ THERE IS NO AUTHENTICATION ─────────────────────────────────────────────
# FreeReps has exactly two identity modes (server/internal/server/server.go's
# identityMiddleware): if tsnet is running it calls Tailscale WhoIs and maps the
# caller to a user, and if it is NOT running every request silently becomes
# `DevIdentity` — user_id 1, no credential of any kind. There is no password, no
# API key, no third mode.
#
# tsnet is off here (see FREEREPS_TS_ENABLED below), so this instance is the
# second one: anything that can reach the port can read and write the health
# data. The tailnet is the entire security boundary, and that is a deliberate
# RAM trade, not an oversight —
#
#   tsnet on:  FreeReps joins the tailnet as its OWN node, with its own
#              gvisor-based userspace netstack (~60–120 MB RSS) and its own node
#              state. It also binds the tailnet IP instead of 127.0.0.1, which
#              makes socket-activation impossible — the proxy has nothing local
#              to forward to — so the cost is permanent, not per-request. Call
#              it ~120–200 MB always-on for a single-user health dashboard.
#   tsnet off: 0 MB at rest, ~70–100 MB awake, and Tailscale Serve provides the
#              same tailnet-only reachability from the outside.
#
# On a 4 GB box that already runs Immich, Home Assistant, AFFiNE, Sure and
# Postgres, the second option is the one that fits. Consequence to keep in mind:
# do NOT funnel this (funnel = false below, and Tailscale only permits funnels on
# 443/8443/10000 anyway, none of which this uses).
#
# ── Ingest is unbounded ──────────────────────────────────────────────────────
# No handler wraps the request body in http.MaxBytesReader, and the unified
# import path does a full io.ReadAll (server/internal/server/handlers.go:132)
# before decoding, so a large push materialises whole in the Go heap. Nothing
# sits in front to cap it either: this service is NOT behind the nginx path-mux
# (front-proxy.nix), so there is no client_max_body_size to lean on — Tailscale
# Serve forwards a body of any size. MemoryMax on the unit is therefore the only
# guard, and it is load-bearing: without it an oversized import is an
# rpi5-wide OOM event (known_issue_rpi5_oom_thrash), with it the import fails
# and nothing else on the box notices.
{
  config,
  pkgs,
  lib,
  pgHost,
  pgPort,
  ...
}:
let
  internalPort = 13348; # freereps HTTP bind (real backend, localhost only)
  proxyPort = 8370; # socket-activate proxy listen; Tailscale Serve → here
  # External tailnet HTTPS port: declared once in nic.services.freereps.public
  # below. 3950 was taken by dsh, hence 3960.

  # config.yaml is REQUIRED even though almost every key has an env override:
  # config.Load does a bare os.ReadFile and returns the error, so a missing file
  # is a startup failure rather than a defaults-only run.
  #
  # Only non-secrets live here — this lands in the world-readable Nix store. The
  # DB password comes from the agenix EnvironmentFile as FREEREPS_DB_PASSWORD.
  configFile = (pkgs.formats.yaml { }).generate "freereps-config.yaml" {
    server = {
      host = "127.0.0.1";
      port = internalPort;
    };
    database = {
      host = pgHost;
      port = pgPort;
      name = "freereps";
      user = "freereps";
      # Loopback TCP to the shared cluster with a scram password (nic.pgRole
      # emits the matching pg_hba line). Not the Unix socket: the app builds a
      # DSN from host+port and has no socket path setting.
      sslmode = "disable";
    };
    tailscale.enabled = false; # see the auth note in the header
    ingest.session_timezone = "Europe/Paris";
    # The three external connectors stay unconfigured. Enabling any of them is
    # incompatible with the socket-activation below: each is a background loop
    # on a 30 min timer inside this process, and a sleeping process runs no
    # timers — so the sync would only ever fire when a request happened to have
    # woken the service for another reason. Wiring Oura/Hevy/Withings later
    # means dropping idleSec, and paying ~70–100 MB permanently for it.
  };
in
{
  # ── PostgreSQL: freereps database + freereps role ──────────────────────────
  # `timescaledb` is pre-created here as postgres because migration 000001 opens
  # with `CREATE EXTENSION IF NOT EXISTS timescaledb`, which needs superuser —
  # the freereps role has no such right, so without this the very first
  # migration fails and the service never starts. The shared library itself is a
  # separate concern, wired in databases.nix (services.postgresql.extensions +
  # shared_preload_libraries).
  nic.pgRole.freereps = {
    db = "freereps";
    user = "freereps";
    passwordFile = "/run/agenix/freereps-pg-password";
    extensions = [ "timescaledb" ];
    description = "Set freereps PostgreSQL password + timescaledb extension";
    # Re-run the oneshot when the secret itself changes. Without this the
    # RemainAfterExit oneshot stays "active" across a rotation, so Postgres
    # keeps the OLD password while freereps-env.age hands the service the NEW
    # one — and the failure surfaces as an authentication error on the next
    # wake, far from the rotation that caused it. Only reactive-resume does this
    # today; the pg-role docstring calls the omission a latent bug in the rest,
    # so a new role should not inherit it.
    restartTriggers = [ config.age.secrets.freereps-pg-password.file ];
  };

  users.users.freereps = {
    isSystemUser = true;
    group = "freereps";
  };
  users.groups.freereps = { };

  systemd.services.freereps = {
    description = "FreeReps — Apple Health server";
    # No wantedBy: socketActivate below owns the lifecycle (it clears the
    # boot-time wantedBy on realUnit) and the proxy starts this on demand.
    after = [
      "network.target"
      "freereps-pg-setup.service"
    ];
    requires = [ "freereps-pg-setup.service" ];

    environment = {
      # Belt and braces over configFile's `tailscale.enabled = false`: the
      # default in config.go is Enabled = TRUE, so a config file that failed to
      # parse the key would silently start a tailnet node. Two independent
      # spellings of "off" is cheap insurance for the auth note in the header.
      FREEREPS_TS_ENABLED = "false";
    };

    serviceConfig = {
      Type = "simple";
      User = "freereps";
      Group = "freereps";
      # FREEREPS_DB_PASSWORD — never in the Nix store. Same plaintext as
      # freereps-pg-password, in env-file form: nic.pgRole needs the bare
      # password to feed psql's ALTER USER, and this unit needs it as an
      # assignment. Two encryptions of one secret, exactly as airtrail does it.
      EnvironmentFile = "/run/agenix/freereps-env";

      # RunMigrations(dsn, "migrations") resolves a RELATIVE path, so cwd has to
      # be the directory holding them — which is why the package installs a
      # copy under share/freereps instead of relying on $src. Read-only store
      # path: fine only because tsnet is disabled, since its state dir
      # ("tsnet-state") is the one thing this app would write to cwd.
      WorkingDirectory = "${pkgs.freereps}/share/freereps";
      ExecStart = "${pkgs.freereps}/bin/freereps -config ${configFile}";

      Restart = "on-failure";
      RestartSec = "15";

      # The guard for the unbounded-ingest note in the header. MemoryHigh
      # throttles and reclaims first so an import that is merely large gets
      # slowed rather than killed; MemoryMax is the hard stop that keeps a
      # runaway decode inside this cgroup instead of taking the box down.
      MemoryHigh = "400M";
      MemoryMax = "640M";

      # Reaches only loopback Postgres and serves loopback HTTP; it needs no
      # write access to anything outside its own cgroup.
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        # AF_UNIX is not optional despite this process only ever speaking TCP:
        # glibc's NSS talks to nscd over a Unix socket, so dropping it can turn
        # name resolution into a startup failure that looks nothing like a
        # sandbox problem. Systemd's own notify/journal plumbing wants it too.
        "AF_UNIX"
      ];
    };
  };

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ────────
  # Proxy on :8370 lazily starts freereps.service on first connection and stops
  # it after idleSec. This is what makes the service cost ~0 RAM at rest, and it
  # is only possible because tsnet is off (see the header) — a tsnet node binds
  # the tailnet IP, not a local port, so there would be nothing to proxy to.
  services.socketActivate.freereps = {
    enable = true;
    realUnit = "freereps.service";
    listen = [ "127.0.0.1:${toString proxyPort}" ];
    backend = "127.0.0.1:${toString internalPort}";
    idleSec = 600;
    readyProbe = {
      # /api/v1/version is the one route registered OUTSIDE the identity group
      # (server.go), so it answers 200 without any credential — and unlike "/"
      # it does not depend on the embedded dashboard assets.
      url = "http://127.0.0.1:${toString internalPort}/api/v1/version";
      expectStatus = 200;
      # The server applies its migrations on every start, before it binds. On a
      # fresh DB that is 28 migrations creating four hypertables, which is the
      # slow case this budget is sized for; afterwards golang-migrate reads the
      # schema version and binds in ~1s.
      timeoutSec = 300;
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ─────────
  nic.services.freereps = {
    backup = [ "postgres" ];
    postgresDatabases = [ "freereps" ];
    heavyUnits = [ "freereps.service" ];
    # Light and non-critical, so it sheds early: above wakapi (140), below
    # vaultwarden (150).
    heavyPriority = 145;

    public = {
      order = 110; # row 3, the day: Calino, BeaverHabits, here, Ryot
      port = 3960;
      backend = "http://127.0.0.1:${toString proxyPort}";
      funnel = false; # NEVER — there is no authentication, see the header
      tile = {
        name = "FreeReps";
        # Not in dashboard-icons; mdi is the cheap option that needs no pinned
        # CDN URL to go stale.
        icon = "mdi-heart-pulse";
        category = "Apps";
        description = "Apple Health";
        # Reads the freereps Postgres directly (nicos_scripts/homepage/stats.py
        # fetch_freereps), NOT /api/v1/stats — so the daily poll never wakes the
        # socket-activated service.
        #
        # Three different windows, one per question. Distance is month-to-date
        # INCLUDING today, because a running monthly total is cumulative and
        # simply grows through the day. Steps are YESTERDAY, the last complete
        # day: the aggregator refreshes once a day at an arbitrary hour, so a
        # "today" figure would be a partial day frozen for 24h. Weight is the
        # last weigh-in, routinely weeks old and shown as-is, because weigh-ins
        # are far too sparse for any per-period figure.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/freereps";
          refreshInterval = 3600000;
          mappings = [
            # float, not number: these carry a decimal (210.4 km, 78.4 kg) and
            # `number` would drop it — same reason wakapi's hour fields are float.
            { field = "km"; label = "This month"; format = "float"; suffix = " km"; }
            { field = "steps"; label = "Steps"; format = "number"; }
            { field = "weight"; label = "Weight"; format = "float"; suffix = " kg"; }
          ];
        };
      };
    };
  };
}
