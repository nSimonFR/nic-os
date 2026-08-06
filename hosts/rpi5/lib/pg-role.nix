# hosts/rpi5/lib/pg-role.nix
#
# One Postgres role for one service: the database, the role, the pg_hba line
# that lets it connect over TCP, its password, and ownership of its own DB.
#
# Six services had grown a near-identical `<svc>-pg-setup` oneshot for this,
# and the copies cited each other as the source ("same fix as sure-pg-setup",
# "pattern shared with airtrail-pg-setup", "same caveat as sure/airtrail").
# Four of them re-explained the same two psql caveats. This module is the seam
# those comments were describing.
#
# Why a oneshot at all: `services.postgresql.ensureUsers` in NixOS 25.11 has no
# `ensurePasswordFile` — it can create a role but not give it a password. And
# `ensureDBOwnership` only works when the DB name equals the role name, which is
# false for sure_user/sure_production, nextcloud_user/nextcloud_production, …
# So the password and the ownership grant both have to be applied by hand.
#
# Two caveats that cost real debugging time, recorded here once instead of six
# times:
#
#   1. ORDERING. The oneshot must order after `postgresql-setup.service`, not
#      just `postgresql.service`. postgresql-setup is the unit that runs
#      ensureUsers/ensureDatabases; ordering only after postgresql.service races
#      it and the ALTER USER fails with "role does not exist" on first boot.
#
#   2. psql's `:'pw'` INTERPOLATION ONLY WORKS VIA stdin/-f, NEVER -c. With -c
#      the variable is silently not substituted and psql reports
#      "syntax error at or near :". Hence the `<<<` heredoc-string below.
#
# Usage:
#
#   nic.pgRole.airtrail = {
#     db           = "airtrail";
#     user         = "airtrail";
#     passwordFile = "/run/agenix/airtrail-pg-password";
#     extensions   = [ "unaccent" ];
#   };
#
# emits services.postgresql.{ensureDatabases,ensureUsers,authentication} plus
# an `airtrail-pg-setup.service` oneshot. Downstream units then order on
# `<name>-pg-setup.service` exactly as before.
#
# Lives under `nic.*` alongside `nic.services` (lib/service-registration.nix),
# the namespace this repo uses for options it invents; `services.*` stays for
# upstream NixOS ones. `services.socketActivate` predates that split and is the
# remaining outlier.
{ config, lib, pkgs, pgHost, ... }:

let
  cfg = config.nic.pgRole;

  roleModule = lib.types.submodule ({ name, config, ... }: {
    options = {
      db = lib.mkOption {
        type = lib.types.str;
        description = ''
          Database name. No default — it is only sometimes equal to `user`
          (airtrail, ryot, reactive_resume) and often not (sure_production vs
          sure_user). Explicit > implicit.
        '';
        example = "sure_production";
      };

      user = lib.mkOption {
        type = lib.types.str;
        description = ''
          Postgres role name. Use the underscore form — this is a SQL
          identifier, not a systemd unit name, so `reactive_resume` even when
          the OS user is `reactive-resume`.
        '';
        example = "sure_user";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path to a file holding the role's password, read at runtime (agenix,
          so the secret never enters the world-readable Nix store). null means
          the role gets no password and no pg_hba entry — correct for services
          that reach Postgres over the Unix socket with peer auth (affine).
        '';
        example = "/run/agenix/sure-pg-password";
      };

      extensions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Extensions to `CREATE EXTENSION IF NOT EXISTS` inside `db`, as
          postgres. Needed when the app's own migrations issue CREATE EXTENSION
          but run as the unprivileged role, which lacks the superuser rights it
          requires.

          This is the SQL side only. Making the extension's shared library
          available at all is a separate, nixpkgs-level concern — set
          `services.postgresql.extensions` for anything outside the contrib set
          (pgvector), and leave that at the call site.
        '';
        example = [ "unaccent" ];
      };

      login = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Pass `ensureClauses.login = true` through to ensureUsers, i.e. create
          the role with LOGIN. Only affine needs it today.
        '';
      };

      tcpAuth = lib.mkOption {
        type = lib.types.bool;
        defaultText = lib.literalExpression "passwordFile != null";
        default = config.passwordFile != null;
        description = ''
          Append `host <db> <user> <pgHost>/32 scram-sha-256` to pg_hba, letting
          the role connect over TCP with password auth. Defaults to whether a
          password exists, because the two go together: a TCP scram line is
          useless without a password, and every password-holding role here
          connects via a `postgres://` TCP URL rather than the socket.
        '';
      };

      privateUsers = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          When non-null, force `PrivateUsers` on the oneshot. The RPi5 kernel
          has no user namespaces, so `PrivateUsers = true` breaks the unit
          outright — `false` is the only correct value on this host.

          It is `nullOr` (emitting nothing when null) purely to preserve
          existing drift: airtrail/ryot/nextcloud set `mkForce false`,
          sure/reactive-resume/affine set nothing, and all six run. Normalising
          the three to `false` is the right follow-up, but it would change three
          units, so it is left as a deliberate decision rather than a side
          effect of this extraction.
        '';
      };

      restartTriggers = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [ ];
        description = ''
          Re-run the oneshot when these paths change — in practice, the agenix
          source file behind `passwordFile`.

          Without it the RemainAfterExit oneshot stays "active" across a
          password rotation, so Postgres keeps the OLD password while the app's
          env file picks up the NEW one, and the app fails to authenticate on
          its next restart. Only reactive-resume sets this today; the other four
          password-holding roles have the same latent bug.
        '';
        example = lib.literalExpression "[ config.age.secrets.sure-pg-password.file ]";
      };

      description = lib.mkOption {
        type = lib.types.str;
        default = "Set ${config.user} PostgreSQL password + DB ownership";
        defaultText = lib.literalExpression ''"Set ''${user} PostgreSQL password + DB ownership"'';
        description = "systemd unit Description= for the oneshot.";
      };
    };
  });

  psql = "${pkgs.postgresql}/bin/psql";

  setupScript = c: lib.concatStrings (
    lib.optional (c.passwordFile != null) ''
      password=$(cat ${c.passwordFile})
      # psql's :'pw' interpolation works via stdin/-f only; with -c it is
      # silently dropped and psql errors "syntax error at or near :".
      ${psql} -v pw="$password" <<< "ALTER USER ${c.user} WITH PASSWORD :'pw';"
    ''
    ++ [ ''${psql} -c "ALTER DATABASE ${c.db} OWNER TO ${c.user};"
      ''
    ]
    ++ map (ext: ''${psql} -d ${c.db} -c "CREATE EXTENSION IF NOT EXISTS ${ext};"
    '') c.extensions
  );

  setupService = c: {
    inherit (c) description restartTriggers;
    # See caveat 1 at the top of this file: postgresql-setup, not just postgresql.
    after = [ "postgresql.service" "postgresql-setup.service" ];
    requires = [ "postgresql.service" "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
    } // lib.optionalAttrs (c.privateUsers != null) {
      PrivateUsers = lib.mkForce c.privateUsers;
    };
    script = setupScript c;
  };

  # Alphabetical by role name so the merged pg_hba block is deterministic. The
  # rules are mutually exclusive (each names a distinct db+user pair), so their
  # relative order does not affect first-match-wins resolution; they only need
  # to land before the permissive `host all all` default, which mkAfter ensures.
  withTcpAuth = lib.filter (c: c.tcpAuth) (lib.attrValues cfg);

in
{
  options.nic.pgRole = lib.mkOption {
    type = lib.types.attrsOf roleModule;
    default = { };
    description = ''
      Per-service Postgres roles on the shared cluster. The attribute name is
      the unit prefix: `nic.pgRole.sure` produces `sure-pg-setup.service`.
      See hosts/rpi5/lib/pg-role.nix for the ordering and psql-quoting caveats.
    '';
  };

  config = lib.mkIf (cfg != { }) {
    services.postgresql = {
      ensureDatabases = lib.mapAttrsToList (_: c: c.db) cfg;
      ensureUsers = lib.mapAttrsToList
        (_: c: { name = c.user; } // lib.optionalAttrs c.login {
          ensureClauses.login = true;
        })
        cfg;
      authentication = lib.mkAfter (lib.concatMapStrings
        (c: "host  ${c.db}  ${c.user}  ${pgHost}/32  scram-sha-256\n")
        withTcpAuth);
    };

    systemd.services = lib.mapAttrs'
      (name: c: lib.nameValuePair "${name}-pg-setup" (setupService c))
      cfg;
  };
}
