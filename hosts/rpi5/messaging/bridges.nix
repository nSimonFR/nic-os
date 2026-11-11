# mautrix bridges, one per network, all on Tuwunel (tuwunel.nix). Not the nixpkgs
# modules: they cover 4 of these 7, each with its own token handling, and assume
# Synapse.
#
#   matrix-appservices-setup  root oneshot before Tuwunel: mints each bridge's
#                             appservice tokens once, writes the registrations.
#   mautrix-<name>            the bridge; config rendered at every start, tokens
#                             envsubst'd in so they stay out of the store.
#
# Always on (each holds its network's connection), capped with GOMEMLIMIT:
# MemoryMax is a no-op on this kernel (cgroup memory disabled). State in Postgres
# over peer auth, dumped by postgresqlBackup. Login: `login` in the bot's DM.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.nic.messaging) serverName homeserverPort appserviceDir;
  owner = "@nico:${serverName}";
  serverRe = lib.escapeRegex serverName;

  goolm = p: p.override { withGoolm = true; };
  # Not in nixpkgs (Telegram there is the retired Python bridge).
  mkBridge =
    repo: tag: hash: vendorHash:
    pkgs.callPackage ../../../pkgs/services/mautrix-bridge.nix {
      buildGoModule = pkgs.buildGoModule.override { go = pkgs.go_1_26; };
      inherit
        repo
        tag
        hash
        vendorHash
        ;
    };

  # port: the bridge's appservice listener, loopback.
  bridges = {
    whatsapp = {
      package = goolm pkgs.mautrix-whatsapp;
      port = 29318;
      # Full sync pulls years of history into Postgres on first login.
      network.history_sync.request_full_sync = false;
    };
    signal = {
      package = goolm pkgs.mautrix-signal;
      port = 29328;
    };
    # Instagram only: picked at `login` (the same bridge also does Messenger).
    meta = {
      package = goolm pkgs.mautrix-meta;
      port = 29319;
    };
    slack = {
      package = goolm pkgs.mautrix-slack;
      port = 29335;
    };
    telegram = {
      package =
        mkBridge "telegram" "v0.2610.0" "sha256-2oHtqtpFhNr+v49nMSe33RGDj+MQV2D/+8JX+YYWi+0="
          "sha256-JbnlJnCtIKC3rpO2mBa7DvEFeWuq9tpvN9H+MoQ5VV0=";
      port = 29317;
      # TELEGRAM_API_ID / TELEGRAM_API_HASH, from https://my.telegram.org/apps.
      environmentFile = "/run/agenix/mautrix-telegram-env";
      network = {
        api_id = "$TELEGRAM_API_ID";
        api_hash = "$TELEGRAM_API_HASH";
      };
    };
    linkedin = {
      package =
        mkBridge "linkedin" "v0.2609.0" "sha256-tGgxlcDq5BfGOmabukfDqZ88lcCLx4/WXHOYHuSxO04="
          "sha256-6WaikDU5tIMdZdBiAqMPOaiG+mmptTi7GFgPMxB/04E=";
      port = 29341;
    };
    twitter = {
      package =
        mkBridge "twitter" "v0.2609.0" "sha256-reUzyhigVZM9IqYGHMOTdTT0UTD9oAEJkeqUFvGmGvM="
          "sha256-tePfW71Rd1krac2+UQK7JhyyKqkyAGyMkXh1knvtZUM=";
      port = 29327;
    };
  };

  stateDir = name: "/var/lib/mautrix-${name}";
  dbName = name: "mautrix-${name}";
  database = name: {
    type = "postgres";
    uri = "postgres:///${dbName name}?host=/run/postgresql";
    max_open_conns = 2;
    max_idle_conns = 1;
  };

  # Double puppeting: a url-less appservice owning only @nico, so the bridges
  # (and the messaging MCP) act as Nico without his password.
  doublePuppetDir = "/var/lib/matrix-doublepuppet"; # appserviceDir is closed to the MCP
  doublePuppetEnv = "${doublePuppetDir}/doublepuppet.env";
  doublePuppetSecret = "as_token:$DOUBLEPUPPET_TOKEN";

  registrations = {
    doublepuppet = {
      id = "doublepuppet";
      url = null;
      as_token = "$DOUBLEPUPPET_TOKEN";
      hs_token = "$DOUBLEPUPPET_HS_TOKEN";
      sender_localpart = "doublepuppet";
      rate_limited = false;
      namespaces.users = [
        {
          regex = "^${lib.escapeRegex owner}$";
          exclusive = false;
        }
      ];
    };
  }
  // lib.mapAttrs (name: b: {
    id = name;
    url = "http://127.0.0.1:${toString b.port}";
    as_token = "$AS_TOKEN";
    hs_token = "$HS_TOKEN";
    sender_localpart = "${name}bot";
    rate_limited = false;
    namespaces.users = [
      {
        regex = "^@${name}bot:${serverRe}$";
        exclusive = true;
      }
      {
        regex = "^@${name}_.*:${serverRe}$";
        exclusive = true;
      }
    ];
    receive_ephemeral = true;
  }) bridges;

  bridgeConfig =
    name: b:
    let
      common = {
        homeserver = {
          address = "http://127.0.0.1:${toString homeserverPort}";
          domain = serverName;
        };
        appservice = {
          address = "http://127.0.0.1:${toString b.port}";
          hostname = "127.0.0.1";
          inherit (b) port;
          id = name;
          bot.username = "${name}bot";
          as_token = "$AS_TOKEN";
          hs_token = "$HS_TOKEN";
        };
        logging = {
          min_level = "info";
          writers = [
            {
              type = "stdout";
              format = "pretty";
            }
          ];
        };
      };
    in
    lib.recursiveUpdate common {
      appservice.username_template = "${name}_{{.}}";
      database = database name;
      bridge = {
        permissions.${owner} = "admin";
        personal_filtering_spaces = true;
      };
      double_puppet.secrets.${serverName} = doublePuppetSecret;
      encryption.allow = false;
      provisioning.shared_secret = "disable";
      backfill = {
        enabled = true;
        max_initial_messages = 50;
      };
      network = b.network or { };
    };

  yaml = (pkgs.formats.yaml { }).generate;
  registrationFiles = lib.mapAttrs (name: r: yaml "${name}-registration.yaml" r) registrations;
  render = "${pkgs.envsubst}/bin/envsubst";

  bridgeUnit =
    name: b:
    let
      cfgFile = yaml "mautrix-${name}.yaml" (bridgeConfig name b);
      dir = stateDir name;
    in
    {
      description = "mautrix-${name} bridge";
      wantedBy = [ "multi-user.target" ];
      after = [
        "tuwunel.service"
        "postgresql-setup.service"
        "matrix-appservices-setup.service"
      ];
      requires = [ "matrix-appservices-setup.service" ];
      wants = [ "tuwunel.service" ];
      path = [ pkgs.ffmpeg-headless ]; # voice notes and stickers
      environment.GOMEMLIMIT = "40MiB";
      restartTriggers = [ cfgFile ];
      serviceConfig = {
        User = "mautrix-${name}";
        Group = "mautrix-${name}";
        StateDirectory = "mautrix-${name}";
        StateDirectoryMode = "0750";
        EnvironmentFile = [ "${dir}/env" ] ++ lib.optional (b ? environmentFile) b.environmentFile;
        WorkingDirectory = dir;
        UMask = "0077";
        ExecStartPre = "${render} -i ${cfgFile} -o ${dir}/config.yaml";
        ExecStart = "${lib.getExe b.package} -c ${dir}/config.yaml -r ${dir}/registration.yaml";
        Restart = "always";
        RestartSec = "30s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };

  # Per bridge: tokens minted once, then its registration in appserviceDir (for
  # Tuwunel) and in its own dir, plus an env file with its and the DP token.
  setupBridge = name: _: ''
    dir=${stateDir name}
    install -d -m 0750 -o mautrix-${name} -g mautrix-${name} "$dir"
    [ -s "$dir/tokens.env" ] || printf 'AS_TOKEN=%s\nHS_TOKEN=%s\n' "$(rand)" "$(rand)" > "$dir/tokens.env"
    cat "$dir/tokens.env" ${doublePuppetEnv} > "$dir/env"
    (set -a; . "$dir/tokens.env"; ${render} -i ${registrationFiles.${name}} -o ${appserviceDir}/${name}.yaml)
    install -m 0400 -o mautrix-${name} ${appserviceDir}/${name}.yaml "$dir/registration.yaml"
    chown mautrix-${name} "$dir/tokens.env" "$dir/env"
  '';
in
{
  users.users = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "mautrix-${name}" {
      isSystemUser = true;
      group = "mautrix-${name}";
      home = stateDir name;
    }
  ) bridges;
  users.groups = lib.mapAttrs' (name: _: lib.nameValuePair "mautrix-${name}" { }) bridges // {
    # The messaging MCP reads the double-puppet token; it runs in hermes, as nsimon.
    matrix-mcp.members = [ "nsimon" ];
  };

  services.postgresql = {
    ensureDatabases = map dbName (lib.attrNames bridges);
    ensureUsers = map (name: {
      name = dbName name;
      ensureDBOwnership = true;
    }) (lib.attrNames bridges);
  };

  systemd.services =
    lib.mapAttrs' (name: b: lib.nameValuePair "mautrix-${name}" (bridgeUnit name b)) bridges
    // {
      matrix-appservices-setup = {
        description = "Matrix appservice tokens and registrations";
        wantedBy = [ "multi-user.target" ];
        before = [ "tuwunel.service" ];
        requiredBy = [ "tuwunel.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
        };
        path = [ pkgs.openssl ];
        script = ''
          set -eu
          rand() { openssl rand -hex 32; }
          install -d -m 0750 -g matrix-mcp ${doublePuppetDir}
          [ -s ${doublePuppetEnv} ] || printf 'DOUBLEPUPPET_TOKEN=%s\nDOUBLEPUPPET_HS_TOKEN=%s\n' "$(rand)" "$(rand)" > ${doublePuppetEnv}
          chgrp matrix-mcp ${doublePuppetEnv}
          chmod 0440 ${doublePuppetEnv}
          (set -a; . ${doublePuppetEnv}; ${render} -i ${registrationFiles.doublepuppet} -o ${appserviceDir}/doublepuppet.yaml)
          ${lib.concatStrings (lib.mapAttrsToList setupBridge bridges)}
          chgrp matrix-appservices ${appserviceDir}/*.yaml
          chmod 0640 ${appserviceDir}/*.yaml
        '';
      };
      # A registration is only read at start.
      tuwunel.restartTriggers = lib.attrValues registrationFiles;
    };

  nic.services.matrix-bridges = {
    backup = [ "postgres" ];
    postgresDatabases = map dbName (lib.attrNames bridges);
  };
}
