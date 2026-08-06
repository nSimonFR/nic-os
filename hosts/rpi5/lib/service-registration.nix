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
{ config, lib, ... }:

let
  cfg = config.nic.services;

  # { name, value } pairs ordered heaviest → lightest for the stop list. Ties
  # break on name so the derivation is stable across evals.
  orderedEntries = lib.sort
    (a: b:
      if a.value.heavyPriority != b.value.heavyPriority
      then a.value.heavyPriority < b.value.heavyPriority
      else a.name < b.name)
    (lib.mapAttrsToList (name: value: { inherit name value; }) cfg);

  allHeavyUnits = lib.concatMap (e: e.value.heavyUnits) orderedEntries;

  serviceModule = lib.types.submodule ({ name, ... }: {
    options = {
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
      sorted by `heavyPriority`. Consumed by `nixos-rebuild-safe`
      (configuration.nix) and `auto-upgrade.nix`. Read-only — add units to the
      owning service's module.
    '';
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
          dupes = lib.unique
            (lib.filter (u: lib.count (x: x == u) allHeavyUnits > 1) allHeavyUnits);
        in {
          assertion = dupes == [ ];
          message =
            "nic.services.*.heavyUnits declares these units more than once: "
            + lib.concatStringsSep ", " dupes
            + ". Each unit belongs to exactly one service.";
        })
      ];
  };
}
