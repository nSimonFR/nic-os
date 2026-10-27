# What agents (running as nsimon, no sudo — security-policy.nix) may still do
# as root, none of which hands them a secret:
#   - start/stop/restart the app units the deploy manages, via polkit;
#   - read Postgres through a peer-auth `nsimon` role with pg_read_all_data,
#     in an allowlist of databases that hold no credentials;
#   - read SQLite DBs through read-only single-file bind mounts in
#     /var/lib/agent-db. Not via the service dirs: HA and Gramps keep secrets
#     world-readable in there (.storage, users.sqlite), so traversal leaks them.
#     Open with `?immutable=1`: no -shm needed, but un-checkpointed WAL is unseen.
{ config, lib, pkgs, ... }:
let
  # Every other database loses PUBLIC CONNECT, so only its owner role gets in.
  # A new one is covered from the next boot or change of this SQL.
  pgAgentDbs = [ "postgres" "airtrail" "freereps" "immich" ];

  pgReadonlySql = pkgs.writeText "agent-pg-readonly.sql" ''
    GRANT pg_read_all_data TO nsimon;
    ALTER ROLE nsimon SET default_transaction_read_only = on;
    DO $$ DECLARE d text; BEGIN
      FOR d IN SELECT datname FROM pg_database
        WHERE NOT datistemplate AND datname <> ALL (ARRAY[${lib.concatMapStringsSep ", " (db: "'${db}'") pgAgentDbs}])
      LOOP
        EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', d);
      END LOOP;
    END $$;
  '';

  agentUnits = config.nic.heavyServices
    ++ lib.concatMap (n: [ "${n}-proxy.service" "${n}-proxy.socket" ])
      (lib.attrNames config.services.socketActivate);

  sqliteDbs = {
    hass = "/var/lib/hass/home-assistant_v2.db";
    gramps = "/var/lib/gramps-web/data/grampsdb/6a51098a/sqlite.db"; # one per tree
  };
in
{
  # Existing units only: systemd checks StartTransientUnit (systemd-run, i.e.
  # root) as the same manage-units/"start" pair, and a name that already exists
  # can't be reused for a transient unit. Patterns would let one through.
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id != "org.freedesktop.systemd1.manage-units" || subject.user != "nsimon") return;
      var allowed = ${builtins.toJSON agentUnits};
      var verbs = ["start", "stop", "restart", "try-restart", "reset-failed"];
      if (verbs.indexOf(action.lookup("verb")) >= 0 && allowed.indexOf(action.lookup("unit")) >= 0)
        return polkit.Result.YES;
    });
  '';

  services.postgresql.ensureUsers = [ { name = "nsimon"; ensureClauses.login = true; } ];
  systemd.services.agent-pg-readonly = {
    description = "Postgres: read-only nsimon role, allowlisted DBs only";
    # postgresql-setup creates the role (see lib/pg-role.nix, caveat 1).
    after = [ "postgresql.service" "postgresql-setup.service" ];
    requires = [ "postgresql.service" "postgresql-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ pgReadonlySql ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      ExecStart = "${config.services.postgresql.package}/bin/psql -v ON_ERROR_STOP=1 -f ${pgReadonlySql}";
    };
  };

  # A file bind needs an existing file mountpoint, else systemd mkdirs one.
  systemd.tmpfiles.rules = [
    "d /var/lib/agent-db 0750 root users -"
    # Was 0777. With group ---, the mask must be set too or the entry is ---.
    "z ${sqliteDbs.hass} 0640 hass hass -"
    "a+ ${sqliteDbs.hass} - - - - u:nsimon:r,m::r"
    "r /var/lib/agent-db/memos.db"
  ] ++ lib.mapAttrsToList (n: _: "f /var/lib/agent-db/${n}.db 0440 root users -") sqliteDbs;

  # Default dependencies would put these Before=local-fs.target, and tmpfiles
  # runs after local-fs: a boot cycle that systemd breaks by dropping the mounts.
  systemd.mounts = lib.mapAttrsToList (n: src: {
    what = src;
    where = "/var/lib/agent-db/${n}.db";
    type = "none";
    options = "bind,ro";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "systemd-tmpfiles-setup.service" "systemd-tmpfiles-resetup.service" ];
    before = [ "umount.target" ];
    conflicts = [ "umount.target" ];
    unitConfig = {
      DefaultDependencies = false;
      ConditionPathExists = src;
    };
  }) sqliteDbs;
}
