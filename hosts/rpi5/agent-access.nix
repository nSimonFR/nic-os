# What agents (running as nsimon, no sudo — security-policy.nix) may still do
# as root, none of which hands them a secret:
#   - start/stop/restart system units via polkit, minus the ones that hold or
#     guard secrets or access;
#   - read Postgres through a peer-auth `nsimon` role with pg_read_all_data,
#     except in the databases that store live credentials;
#   - read SQLite DBs through on-demand snapshots (agent-db-snapshot@<name>).
{ config, lib, pkgs, ... }:
let
  # Hold bank-link tokens (Sure), the plaintext Immich key (Dawarich) and
  # integration tokens (Ryot). Only their owner roles connect.
  pgPrivateDbs = [ "sure_production" "dawarich" "ryot" "ryotv2" ];

  pgReadonlySql = pkgs.writeText "agent-pg-readonly.sql" (''
    GRANT pg_read_all_data TO nsimon;
    ALTER ROLE nsimon SET default_transaction_read_only = on;
  '' + lib.concatMapStrings (db: ''
    REVOKE CONNECT ON DATABASE ${db} FROM PUBLIC;
  '') pgPrivateDbs);

  dbSnapshot = pkgs.writeShellApplication {
    name = "agent-db-snapshot";
    runtimeInputs = [ pkgs.sqlite pkgs.coreutils ];
    text = builtins.readFile ./scripts/agent-db-snapshot.sh;
  };
in
{
  # Units an agent must not touch: secret brokers, deploys, remote access, auth.
  security.polkit.enable = true;
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id != "org.freedesktop.systemd1.manage-units" || subject.user != "nsimon") return;
      var unit = action.lookup("unit") || "";
      var verb = action.lookup("verb") || "";
      var verbs = ["start", "stop", "restart", "try-restart", "reload", "reload-or-restart", "reset-failed"];
      if (verbs.indexOf(verb) < 0) return;
      if (!/\.(service|socket|timer)$/.test(unit)) return;
      if (/^(agent-vault|cachix-agent|sshd|tailscaled|polkit|dbus|nix-daemon|systemd-|user@|getty|earlyoom|vaultwarden)/.test(unit)) return;
      return polkit.Result.YES;
    });
  '';

  services.postgresql.ensureUsers = [ { name = "nsimon"; ensureClauses.login = true; } ];
  systemd.services.agent-pg-readonly = {
    description = "Postgres: read-only nsimon role, private DBs excluded";
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

  systemd.tmpfiles.rules = [ "d /var/lib/agent-db 0750 root users -" ];
  systemd.services."agent-db-snapshot@" = {
    description = "Readable snapshot of the %i SQLite DB for agents";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${dbSnapshot}/bin/agent-db-snapshot %i";
    };
  };
}
