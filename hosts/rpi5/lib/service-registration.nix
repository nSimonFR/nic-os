# hosts/rpi5/lib/service-registration.nix
#
# `nic.services.<name>` — the one place a service declares the facts that used
# to live in central lists elsewhere in the tree.
#
# Before this module, adding a service meant remembering to also edit
# `backups.nix` (its Postgres database) and `lib/heavy-services.nix` (its units,
# so `nixos-rebuild-safe` frees their RSS on a 3.9 GiB box). Nothing checked
# either list for completeness, so the gaps stayed invisible until they bit:
# Karakeep ran unbacked from the day it landed, `backups.nix` dumped a
# `ghostfolio` database that no module in the repo creates, and five live units
# were missing from the heavy list.
#
# Both lists are now *derived* from the per-service declarations. Registering a
# service is one block in that service's own module:
#
#   nic.services.airtrail = {
#     backup            = [ "postgres" ];
#     postgresDatabases = [ "airtrail" ];
#     heavyUnits        = [ "airtrail.service" ];
#     heavyPriority     = 110;
#   };
#
# This extends the pattern the repo already uses for `services.socketActivate`
# and `databases.nix`'s `_module.args`: declare per service, derive centrally.
#
# `backup` has no default on purpose. A service cannot be registered without
# stating how its persistent state reaches Storj — that is the whole point, and
# the assertions below turn a wrong or absent answer into an eval error instead
# of a silent gap.
#
# ── The public face ──────────────────────────────────────────────────────────
# `public` carries the same idea one step further. It used to live in
# services-registry.nix: one central, hand-maintained list of 26 entries, keyed
# by DISPLAY name ("Gramps Web") while every other seam here keys on the attr
# name (gramps-web), and read by three consumers (tailscale-serve.nix,
# homepage.nix, front-proxy.nix). Because a service's port lived there and
# nowhere else, five modules kept a private `servePort` copy to build their own
# public origin — and one of them drifted: ryot.nix declared `servePort = 3700`
# long after Ryot moved behind the 443 path-mux, a port that no longer existed,
# read by nothing.
#
# So the port, the route and the tile now sit in the module that owns the
# service, and `nic.publicEntries` is derived from them. `publicUrl` is derived
# too, which is what lets a module say "where am I reachable?" without
# re-deriving the answer:
#
#   nic.services.airtrail.public = {
#     order   = 120;
#     port    = 3600;
#     backend = "http://127.0.0.1:8310";
#     tile    = { name = "AirTrail"; icon = "…"; category = "Apps"; … };
#   };
#   services.airtrail.origin = config.nic.services.airtrail.publicUrl;
#
# `public` is optional: a service can register for backup without being
# reachable. `public.tile` is optional too — omit it and the service is routed
# but renders no dashboard tile. That replaced a pseudo-category: entries were
# hidden by `category = "Infrastructure"`, enforced in three overlapping places
# (a name test for "Homepage", a category test, and omission from
# `categoryOrder`) none of which said "hidden".
{ config, lib, pkgs, tailnetFqdn, ... }:

let
  cfg = config.nic.services;

  # Locations on the 443 path-mux vhost (front-proxy.nix), if it exists. Read
  # for the `proxied` ↔ location assertions below; nginx does not depend on
  # nic.services, so there is no cycle.
  frontProxyLocations =
    let
      vhosts = config.services.nginx.virtualHosts;
    in
    if vhosts ? "front-proxy" then vhosts."front-proxy".locations else { };

  # Only locations that actually proxy need an owner. The pure `return 301`
  # redirects (bare `/` → Nextcloud, the two DAV auto-discovery paths, and the
  # `= /foo` → `/foo/` pairs) exempt themselves by carrying no proxyPass, so
  # there is no list to keep in step for them.
  proxyLocationNames =
    lib.attrNames (lib.filterAttrs (_: l: (l.proxyPass or null) != null) frontProxyLocations);

  # { name, value } pairs ordered heaviest → lightest for the stop list. Ties
  # break on name so the derivation is stable across evals.
  orderedEntries = lib.sort
    (a: b:
      if a.value.heavyPriority != b.value.heavyPriority
      then a.value.heavyPriority < b.value.heavyPriority
      else a.name < b.name)
    (lib.mapAttrsToList (name: value: { inherit name value; }) cfg);

  allHeavyUnits = lib.concatMap (e: e.value.heavyUnits) orderedEntries;

  # `heavy-shed <command…>`: free the RAM, do the thing, put it back. Shared by
  # nixos-rebuild-safe (configuration.nix) and auto-upgrade.nix — it used to be
  # written twice and only the wrapper's copy had the restore, so a failed weekly
  # upgrade left nine always-on services stopped for 9h on 2026-08-30.
  heavyShed = pkgs.writeShellApplication {
    name = "heavy-shed";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      # Guard: with no command, "$@" is a no-op that exits 0 — which would stop
      # everything and take the success path straight past the restore.
      : "''${1:?heavy-shed: no command given}"

      # Already root under the auto-upgrade unit, which has no sudo on its PATH
      # (and the store's sudo is not setuid); nsimon interactively, which does.
      as_root=()
      if [ "$(id -u)" -ne 0 ]; then as_root=(/run/wrappers/bin/sudo); fi

      heavy=(
        ${lib.concatMapStringsSep "\n  " (u: ''"${u}"'') allHeavyUnits}
      )

      # Only always-on units need putting back; socket-idle ones re-activate on
      # the next request, which is how the memory stays freed.
      restore=()
      for unit in "''${heavy[@]}"; do
        if ! systemctl is-active --quiet "$unit"; then continue; fi
        if [ "$(systemctl show "$unit" --property=StopWhenUnneeded --value)" = yes ]; then continue; fi
        restore+=("$unit")
      done

      # A trap, not a branch after the command: callers run `set -e`, and an
      # aborting script never reaches the next line but does run its trap. On
      # success the new generation's activation restarts them instead.
      restore_heavy() {
        status=$?
        trap - EXIT
        if [ "$status" -ne 0 ] && [ "''${#restore[@]}" -gt 0 ]; then
          echo "heavy-shed: failed (exit $status) — restarting ''${#restore[@]} service(s)" >&2
          "''${as_root[@]}" systemctl start "''${restore[@]}" || true
        fi
        exit "$status"
      }
      trap restore_heavy EXIT

      "''${as_root[@]}" systemctl stop "''${heavy[@]}" || true
      echo "heavy-shed: running $*" >&2
      "$@"
    '';
  };

  # Sorted so the derivation is stable across evals; `unique` because nothing
  # stops two services from naming one shared dump unit.
  allBackupUnits =
    lib.sort (a: b: a < b)
      (lib.unique (lib.concatMap (s: s.backupUnits) (lib.attrValues cfg)));

  # Every service with a public face, ascending by `order`, each entry carrying
  # its attr name so consumers key on the same string every other seam does.
  # Ties break on name so the list is stable even if the uniqueness assertion is
  # ever relaxed.
  publicEntries =
    lib.sort
      (a: b: if a.order != b.order then a.order < b.order else a.name < b.name)
      (lib.mapAttrsToList (name: s: { inherit name; } // s.public)
        (lib.filterAttrs (_: s: s.public != null) cfg));

  muxPaths = map (e: e.muxPath) (lib.filter (e: e.muxPath != null) publicEntries);

  # A dashboard tile. Optional on `public`: routed-but-hidden services (the
  # front proxy itself, the MCP gateway, the notify aggregator, the Epic captcha
  # portal, homepage) simply omit it.
  tileModule = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Display name on the dashboard. The only place a human-readable name belongs.";
        example = "Gramps Web";
      };

      icon = lib.mkOption {
        type = lib.types.str;
        description = ''
          `name.svg` / `name.png` → dashboard-icons (walkxcode CDN);
          `mdi-name` → Material Design Icons; `si-name` → Simple Icons;
          or an absolute URL for anything dashboard-icons does not carry.
        '';
        example = "gramps.svg";
      };

      category = lib.mkOption {
        type = lib.types.enum [ "Apps" "Backend" ];
        description = ''
          Which dashboard group the tile renders under. Grouping only — a
          service that should not render omits `tile` entirely rather than
          claiming a category that secretly means "hidden".
        '';
      };

      description = lib.mkOption {
        type = lib.types.str;
        description = "One-line subtitle under the tile.";
        example = "Genealogy";
      };

      deepLink = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Suffix appended to `publicUrl` for the tile's href, so a tile can
          point somewhere other than the service root. Cosmetic, and NOT
          `muxPath`: this changes where a link goes, never how a request is
          routed. Home Assistant is the only user — it deep-links to its
          "Mine" Lovelace dashboard instead of HA's root.
        '';
        example = "/mine-dashboard/";
      };

      widget = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = null;
        description = ''
          homepage widget config, passed through verbatim. Every tile that has
          one is a `customapi` widget pointed at the homepage-stats aggregator
          on :8087 (nicos_scripts/homepage/stats.py), which fetches once a day
          and holds whatever API key or DB path the service needs — so no
          credential appears here, and polling never wakes a socket-activated
          service. Three stats per tile, so no tile is taller than its
          neighbours.
        '';
      };
    };
  };

  # A service's reachable-from-outside surface.
  publicModule = lib.types.submodule ({ config, ... }: {
    options = {
      order = lib.mkOption {
        type = lib.types.int;
        default = 500;
        description = ''
          Sort key, ascending, for both the dashboard tile row and the order in
          which serve/funnel commands are emitted. Spaced by 10 to leave room
          to insert without renumbering — same convention as `heavyPriority`.
          Asserted unique: equal keys would make the emit order depend on
          attrset iteration rather than on a decision.
        '';
        example = 120;
      };

      port = lib.mkOption {
        type = lib.types.port;
        description = ''
          External tailnet HTTPS port that `tailscale serve` (or `funnel`)
          binds. 443 for anything behind the path-mux, since one funnel on 443
          fronts them all.
        '';
        example = 3600;
      };

      backend = lib.mkOption {
        type = lib.types.str;
        description = ''
          Where Tailscale Serve forwards. Usually the socket-activate proxy
          port rather than the service's real bind, so a request wakes it.
        '';
        example = "http://127.0.0.1:8310";
      };

      funnel = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Publicly reachable via `tailscale funnel` instead of tailnet-only
          `tailscale serve`. Tailscale permits funnels on 443, 8443 and 10000
          only — asserted below, because that limit was documented in prose in
          three places here and enforced nowhere.
        '';
      };

      proxied = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Fronted by the nginx path-mux (front-proxy.nix) behind the single 443
          funnel. No serve/funnel command is emitted for these — a second bind
          on 443 would conflict — but the tile still renders. Requires
          `muxPath`, and is mutually exclusive with `funnel`.
        '';
      };

      muxPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Prefix under which the path-mux fronts this service, folded into
          `publicUrl`. The nginx `location` block itself stays in
          front-proxy.nix — the forwarding rules there are genuinely bespoke
          per service (body sizes, stream buffering, whether the prefix is
          stripped) and pushing them through an option would only be a
          passthrough of nginx config. Asserted to have a matching location, so
          declaring one without the other fails eval instead of serving a 404.
        '';
        example = "/ryot";
      };

      tile = lib.mkOption {
        type = lib.types.nullOr tileModule;
        default = null;
        description = ''
          Dashboard tile, or null for a service that is routed but renders
          nothing.
        '';
      };

      publicUrl = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        description = ''
          Derived: the URL this service is reachable at. `:port` is omitted on
          443 (the bare-URL funnel) and `muxPath` is folded in, so the two
          shapes — `https://host:3600` and `https://host/ryot` — come out of
          one rule instead of being spelled at each call site. Read this from
          the owning module for its own origin / APP_URL / NEXTAUTH_URL.
        '';
      };
    };

    config.publicUrl =
      "https://${tailnetFqdn}"
      + lib.optionalString (config.port != 443) ":${toString config.port}"
      + lib.optionalString (config.muxPath != null) config.muxPath;
  });

  serviceModule = lib.types.submodule ({ name, ... }: {
    options = {
      public = lib.mkOption {
        type = lib.types.nullOr publicModule;
        default = null;
        description = ''
          How ${name} is reached from outside, and how it appears on the
          dashboard. null for a service with no public face — it still
          registers here for backup and heavy-unit accounting.
        '';
      };

      backup = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "postgres" "unit" "mnt-data" "none" ]);
        description = ''
          Every mechanism by which ${name}'s persistent state reaches
          `/mnt/data` — and from there Storj, since restic
          (`storj-backup.nix`) backs up `/mnt/data` and nothing else. A list,
          because services routinely use more than one: Forgejo has a Postgres
          dump, a state tarball unit, and repositories sitting on the HDD.

          - `postgres`  — dumped by `services.postgresqlBackup`; requires
                          `postgresDatabases`.
          - `unit`      — a dedicated unit writes a dump under
                          `/mnt/data/backups/…`; requires `backupUnits`, and
                          each named unit must actually exist.
          - `mnt-data`  — state already lives under `/mnt/data`, so restic
                          covers it with no dump step.
          - `none`      — nothing worth backing up; requires `backupNote`, and
                          cannot be combined with the others.

          No default: every registered service answers this question.
        '';
        example = [ "postgres" "mnt-data" ];
      };

      postgresDatabases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Databases appended to `services.postgresqlBackup.databases`. Real
          database names, not service names (`sure_production`,
          `nextcloud_production`, …).
        '';
        example = [ "airtrail" ];
      };

      backupUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Units (with `.service`) that dump this service's state onto
          `/mnt/data`. Asserted to exist, so a typo — or a `backup = [ "unit" ]`
          written before the unit was — fails evaluation rather than silently
          backing up nothing.
        '';
        example = [ "papra-backup.service" ];
      };

      backupNote = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Why there is nothing to back up. Required when `backup = [ "none" ]`,
          so a deliberate decision reads differently from an oversight.
        '';
        example = "stateless — everything it serves comes from the nix store";
      };

      heavyUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Units stopped by `nixos-rebuild-safe` and the weekly auto-upgrade to
          free RSS before a build. List every unit the service actually runs
          (web + workers + its search backend), not just the socket-activated
          `realUnit` — the workers are where the RSS is.

          Infra (tailscaled, nginx, postgresql, redis, blocky) is deliberately
          never listed: stopping it breaks the rebuild itself.
        '';
        example = [ "karakeep-web.service" "karakeep-workers.service" ];
      };

      heavyPriority = lib.mkOption {
        type = lib.types.int;
        default = 500;
        description = ''
          Sort key for the stop list, ascending — heaviest first, so the largest
          RSS is freed soonest. Existing services are spaced by 10 to leave room
          to insert without renumbering.
        '';
        example = 110;
      };
    };
  });

  # One message per failing service, naming the service.
  assertFor = f: lib.mapAttrsToList f cfg;

  # Same, over services that have a public face. `e.name` is the attr name.
  assertForPublic = f: map f publicEntries;

  # Duplicate values in a list, for the uniqueness messages below.
  dupesIn = xs: lib.unique (lib.filter (x: lib.count (y: y == x) xs > 1) xs);
in
{
  options.nic.services = lib.mkOption {
    type = lib.types.attrsOf serviceModule;
    default = { };
    description = ''
      Per-service declarations. The central backup and heavy-service lists are
      derived from these — do not maintain either by hand.
    '';
  };

  options.nic.heavyServices = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = allHeavyUnits;
    description = ''
      Derived, heaviest → lightest: every `nic.services.*.heavyUnits` entry
      sorted by `heavyPriority`. Read-only — add units to the owning service's
      module. Stop them via `nic.heavyShed`, never by hand: the one caller that
      did is why nine services stayed down for 9h on 2026-08-30.
    '';
  };

  options.nic.heavyShed = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    default = heavyShed;
    description = ''
      Derived: `heavy-shed <command…>` stops every `nic.heavyServices` unit, runs
      the command, and restarts the always-on ones if it fails. The single
      implementation behind `nixos-rebuild-safe` and the weekly auto-upgrade.
    '';
  };

  options.nic.backupUnits = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    default = allBackupUnits;
    description = ''
      Derived: every `nic.services.*.backupUnits` entry, deduplicated and
      sorted. Consumed by `storj-backup.nix`, which orders restic `After=` all
      of them — restic used to run on a 03:00 timer with an hour of jitter
      while these dumped between 03:00 and 04:15, so it could read a `.gz`
      mid-write and always shipped the late ones a day stale. Read-only — add
      units to the owning service's module.
    '';
  };

  options.nic.publicEntries = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    readOnly = true;
    default = publicEntries;
    description = ''
      Derived, ascending by `order`: every `nic.services.*.public`, each with
      its attr name added as `name`. Consumed by `tailscale-serve.nix` (serve +
      funnel commands) and `homepage.nix` (tiles). Read-only — this replaced
      services-registry.nix, so declare the facts on the owning service and
      never maintain a list here.
    '';
  };

  options.nic.frontProxy.unclaimed = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Locations on the 443 path-mux that proxy somewhere but belong to no
      service's `muxPath`, each one a deliberate exception. Without this the
      reverse assertion below — which is what catches a deleted service leaving
      a live nginx block behind — could not tell an exception from an oversight.
      Pure `return 301` redirects need no entry; they carry no proxyPass.
    '';
    example = [ "/backend/" ];
  };

  config = {
    services.postgresqlBackup.databases =
      lib.concatMap (s: s.postgresDatabases) (lib.attrValues cfg);

    assertions =
      assertFor (name: s: {
        assertion = s.backup != [ ];
        message =
          "nic.services.${name}.backup is empty. State how the service's persistent "
          + "state reaches Storj, or [ \"none\" ] with a backupNote if there is none.";
      })
      ++ assertFor (name: s: {
        assertion = (s.postgresDatabases != [ ]) == (lib.elem "postgres" s.backup);
        message =
          "nic.services.${name}: postgresDatabases and backup = [ … \"postgres\" … ] "
          + "must agree. Either the database is dumped and unlisted, or it is listed "
          + "and never dumped.";
      })
      ++ assertFor (name: s: {
        assertion = (s.backupUnits != [ ]) == (lib.elem "unit" s.backup);
        message =
          "nic.services.${name}: backupUnits and backup = [ … \"unit\" … ] must agree. "
          + "Name the unit that does the dumping, or drop \"unit\" from backup.";
      })
      ++ lib.concatLists (assertFor (name: s:
        map (unit: {
          assertion = config.systemd.services ? ${lib.removeSuffix ".service" unit};
          message =
            "nic.services.${name}.backupUnits names \"${unit}\", which does not exist. "
            + "Either the unit was never written or the name is a typo — either way "
            + "the service is unbacked.";
        }) s.backupUnits))
      ++ assertFor (name: s: {
        assertion = lib.elem "none" s.backup -> s.backup == [ "none" ];
        message =
          "nic.services.${name} combines backup = \"none\" with a real backup "
          + "mechanism. Pick one.";
      })
      ++ assertFor (name: s: {
        assertion = lib.elem "none" s.backup -> s.backupNote != "";
        message =
          "nic.services.${name} has backup = [ \"none\" ] but no backupNote. Say why "
          + "there is nothing to back up, so the next reader can tell a deliberate "
          + "decision from an oversight.";
      })
      ++ [
        (let
          dupes = dupesIn allHeavyUnits;
        in {
          assertion = dupes == [ ];
          message =
            "nic.services.*.heavyUnits declares these units more than once: "
            + lib.concatStringsSep ", " dupes
            + ". Each unit belongs to exactly one service.";
        })
      ]

      # ── The public face ────────────────────────────────────────────────────
      ++ assertForPublic (e: {
        assertion = e.proxied == (e.muxPath != null);
        message =
          "nic.services.${e.name}.public: proxied and muxPath must agree. A "
          + "proxied service is reached through the path-mux, so it needs the "
          + "prefix; an unproxied one has no mux to be fronted by.";
      })
      ++ assertForPublic (e: {
        assertion = !(e.proxied && e.funnel);
        message =
          "nic.services.${e.name}.public sets both proxied and funnel. The "
          + "path-mux already sits behind the single 443 funnel — a second bind "
          + "on the same port would conflict. Pick one.";
      })
      ++ assertForPublic (e: {
        assertion = e.funnel -> lib.elem e.port [ 443 8443 10000 ];
        message =
          "nic.services.${e.name}.public asks to funnel port ${toString e.port}. "
          + "Tailscale permits funnels on 443, 8443 and 10000 only, and all "
          + "three are already allocated — so this would fail at runtime, in "
          + "tailscale-serve.service, not here.";
      })
      ++ assertForPublic (e: {
        assertion =
          e.muxPath == null || lib.any (loc: lib.hasPrefix e.muxPath loc) proxyLocationNames;
        message =
          "nic.services.${e.name}.public.muxPath is \"${e.muxPath}\" but no "
          + "front-proxy location proxies it (see hosts/rpi5/front-proxy.nix). "
          + "No serve command is emitted for a proxied service, so its tile "
          + "would link straight to a 404.";
      })
      ++ [
        (let
          claimed = loc: lib.any (p: lib.hasPrefix p loc) muxPaths;
          orphans = lib.filter
            (loc: !(claimed loc) && !(lib.elem loc config.nic.frontProxy.unclaimed))
            proxyLocationNames;
        in {
          assertion = orphans == [ ];
          message =
            "front-proxy proxies "
            + lib.concatStringsSep ", " orphans
            + " but no service claims it via public.muxPath. Either a service "
            + "was deleted and its nginx location left behind — proxying to a "
            + "dead port, which answers 502 rather than 404 — or the location "
            + "is deliberate and belongs in nic.frontProxy.unclaimed with a "
            + "comment saying why.";
        })
        (let
          # Proxied entries all share 443 behind the one funnel, so uniqueness
          # only holds among the entries that bind a port of their own.
          ports = map (e: e.port) (lib.filter (e: !e.proxied) publicEntries);
          dupes = dupesIn ports;
        in {
          assertion = dupes == [ ];
          message =
            "Two services claim the same tailnet port: "
            + lib.concatStringsSep ", " (map toString dupes)
            + ". Tailscale Serve binds one backend per port, so the later "
            + "command silently wins.";
        })
        (let
          dupes = dupesIn (map (e: e.order) publicEntries);
        in {
          assertion = dupes == [ ];
          message =
            "nic.services.*.public.order is reused: "
            + lib.concatStringsSep ", " (map toString dupes)
            + ". Equal keys make tile and serve order depend on attrset "
            + "iteration rather than on a decision. Keys are spaced by 10 — "
            + "pick a gap.";
        })
      ];
  };
}
