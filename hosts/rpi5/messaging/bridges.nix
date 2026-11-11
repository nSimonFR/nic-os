# mautrix bridges: one puppeting bridge per network, all driven by Tuwunel
# (tuwunel.nix). One generic unit pair per bridge instead of the nixpkgs
# modules, which differ per bridge and assume Synapse:
#
#   mautrix-<name>-setup  root oneshot, before Tuwunel: mints the appservice
#                         tokens once, renders the registration into
#                         appserviceDir and the bridge's own state dir.
#   mautrix-<name>        the bridge, config rendered from Nix at every start.
#
# Each bridge is always on (it holds the network's connection) and capped with
# GOMEMLIMIT: MemoryMax is a no-op on this kernel (cgroup memory disabled).
# State lives in Postgres (peer auth over the socket), dumped by postgresqlBackup.
#
# Login is per network, from the bridge bot's DM in the client: `login`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.nic.messaging) serverName homeserverPort appserviceDir;
  hsUrl = "http://127.0.0.1:${toString homeserverPort}";
  owner = "@nico:${serverName}";
  serverRe = lib.escapeRegex serverName;

  goolm = p: p.override { withGoolm = true; };
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

  # port: the bridge's appservice listener (loopback). legacy: pre-bridgev2
  # config layout (Discord has no bridgev2 release yet).
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
    # Instagram, Messenger and Facebook: the network is picked at `login`.
    meta = {
      package = goolm pkgs.mautrix-meta;
      port = 29319;
    };
    gmessages = {
      package = goolm pkgs.mautrix-gmessages;
      port = 29336;
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
    bluesky = {
      package =
        mkBridge "bluesky" "v0.2510.0" "sha256-tADkD2WSATOubXiLX76qoqFp5aOst62qx40TjhLN2os="
          "sha256-4vX9KV2+TMxKkO7OGTazhDF9jx5/HNbenSUIN8qajLs=";
      port = 29340;
    };
    discord = {
      # No withGoolm knob in its nixpkgs package.
      package = pkgs.mautrix-discord.overrideAttrs (old: {
        buildInputs = [ ]; # olm only
        tags = (old.tags or [ ]) ++ [ "goolm" ];
      });
      port = 29334;
      legacy = true;
    };
  };

  stateDir = name: "/var/lib/mautrix-${name}";
  dbName = name: "mautrix-${name}";
  dbUri = name: "postgres:///${dbName name}?host=/run/postgresql";

  # Double puppeting: one url-less appservice owning only @nico, so every bridge
  # (and the MCP) can act as Nico without his password. The new-style
  # "as_token:" secret, read by bridgev2 and the legacy bridges alike.
  doublePuppet = {
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
  # Own dir: appserviceDir is closed to the MCP's group.
  doublePuppetDir = "/var/lib/matrix-doublepuppet";
  doublePuppetEnv = "${doublePuppetDir}/doublepuppet.env";

  registration = name: b: {
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
    "de.sorunome.msc2409.push_ephemeral" = true;
  };

  common = name: b: {
    homeserver = {
      address = hsUrl;
      domain = serverName;
      software = "standard";
    };
    appservice = {
      address = "http://127.0.0.1:${toString b.port}";
      hostname = "127.0.0.1";
      inherit (b) port;
      id = name;
      bot = {
        username = "${name}bot";
        displayname = "${name} bridge";
      };
      as_token = "$AS_TOKEN";
      hs_token = "$HS_TOKEN";
      ephemeral_events = true;
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

  bridgev2Config =
    name: b:
    lib.recursiveUpdate (common name b) {
      appservice.username_template = "${name}_{{.}}";
      database = {
        type = "postgres";
        uri = dbUri name;
        max_open_conns = 2;
        max_idle_conns = 1;
      };
      bridge = {
        permissions.${owner} = "admin";
        personal_filtering_spaces = true;
      };
      double_puppet.secrets.${serverName} = "as_token:$DOUBLEPUPPET_TOKEN";
      encryption.allow = false;
      provisioning.shared_secret = "disable";
      backfill = {
        enabled = true;
        max_initial_messages = 50;
        max_catchup_messages = 500;
      };
      network = b.network or { };
    };

  legacyConfig =
    name: b:
    lib.recursiveUpdate (common name b) {
      appservice.database = {
        type = "postgres";
        uri = dbUri name;
        max_open_conns = 2;
        max_idle_conns = 1;
      };
      bridge = {
        username_template = "${name}_{{.}}";
        permissions.${owner} = "admin";
        login_shared_secret_map.${serverName} = "as_token:$DOUBLEPUPPET_TOKEN";
        encryption.allow = false;
      };
    };

  json = name: value: pkgs.writeText name (builtins.toJSON value);
  render = "${pkgs.envsubst}/bin/envsubst";

  setupUnit = name: b: {
    description = "mautrix-${name}: appservice tokens and registration";
    wantedBy = [ "multi-user.target" ];
    before = [ "tuwunel.service" ];
    requiredBy = [ "tuwunel.service" ];
    after = [ "matrix-doublepuppet-setup.service" ];
    requires = [ "matrix-doublepuppet-setup.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      dir=${stateDir name}
      install -d -m 0750 -o mautrix-${name} -g mautrix-${name} "$dir"
      tokens="$dir/tokens.env"
      if [ ! -s "$tokens" ]; then
        printf 'AS_TOKEN=%s\nHS_TOKEN=%s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > "$tokens"
      fi
      # The bridge reads its own tokens plus the double-puppet one.
      cat "$tokens" ${doublePuppetEnv} > "$dir/env"
      chown mautrix-${name}:mautrix-${name} "$tokens" "$dir/env"
      chmod 0400 "$tokens" "$dir/env"
      set -a; . "$tokens"; set +a
      ${render} -i ${json "${name}-registration.json" (registration name b)} -o ${appserviceDir}/${name}.yaml
      chgrp matrix-appservices ${appserviceDir}/${name}.yaml
      chmod 0640 ${appserviceDir}/${name}.yaml
      install -m 0400 -o mautrix-${name} ${appserviceDir}/${name}.yaml "$dir/registration.yaml"
    '';
    path = [ pkgs.openssl ];
  };

  bridgeUnit =
    name: b:
    let
      cfgFile = json "mautrix-${name}-config.json" (
        if b.legacy or false then legacyConfig name b else bridgev2Config name b
      );
    in
    {
      description = "mautrix-${name} bridge";
      wantedBy = [ "multi-user.target" ];
      after = [
        "tuwunel.service"
        "postgresql-setup.service"
        "mautrix-${name}-setup.service"
      ];
      requires = [ "mautrix-${name}-setup.service" ];
      wants = [ "tuwunel.service" ];
      path = [ pkgs.ffmpeg-headless ]; # voice notes and stickers
      environment.GOMEMLIMIT = "40MiB";
      restartTriggers = [ cfgFile ];
      serviceConfig = {
        User = "mautrix-${name}";
        Group = "mautrix-${name}";
        EnvironmentFile = [
          "${stateDir name}/env"
        ]
        ++ lib.optional (b ? environmentFile) b.environmentFile;
        WorkingDirectory = stateDir name;
        UMask = "0077";
        ExecStartPre = "${pkgs.writeShellScript "mautrix-${name}-config" ''
          ${render} -i ${cfgFile} -o ${stateDir name}/config.yaml
        ''}";
        ExecStart = "${lib.getExe b.package} -c ${stateDir name}/config.yaml -r ${stateDir name}/registration.yaml";
        Restart = "always";
        RestartSec = "30s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ (stateDir name) ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };
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
    # Read access to the double-puppet token: the messaging MCP runs in hermes, as nsimon.
    matrix-mcp.members = [ "nsimon" ];
  };

  services.postgresql = {
    ensureDatabases = map dbName (lib.attrNames bridges);
    ensureUsers = map (name: {
      name = dbName name;
      ensureDBOwnership = true;
    }) (lib.attrNames bridges);
  };

  systemd.services = {
    matrix-doublepuppet-setup = {
      description = "Matrix double-puppet appservice registration";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      path = [ pkgs.openssl ];
      script = ''
        install -d -m 0750 -g matrix-mcp ${doublePuppetDir}
        if [ ! -s ${doublePuppetEnv} ]; then
          printf 'DOUBLEPUPPET_TOKEN=%s\nDOUBLEPUPPET_HS_TOKEN=%s\n' \
            "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > ${doublePuppetEnv}
        fi
        chgrp matrix-mcp ${doublePuppetEnv}
        chmod 0440 ${doublePuppetEnv}
        set -a; . ${doublePuppetEnv}; set +a
        ${render} -i ${json "doublepuppet-registration.json" doublePuppet} -o ${appserviceDir}/doublepuppet.yaml
        chgrp matrix-appservices ${appserviceDir}/doublepuppet.yaml
        chmod 0640 ${appserviceDir}/doublepuppet.yaml
      '';
    };
  }
  // lib.mapAttrs' (name: b: lib.nameValuePair "mautrix-${name}-setup" (setupUnit name b)) bridges
  // lib.mapAttrs' (name: b: lib.nameValuePair "mautrix-${name}" (bridgeUnit name b)) bridges
  // {
    # A registration is only read at start.
    tuwunel.restartTriggers = [
      (json "doublepuppet-registration.json" doublePuppet)
    ]
    ++ lib.mapAttrsToList (name: b: json "${name}-registration.json" (registration name b)) bridges;
  };

  nic.services.matrix-bridges = {
    backup = [ "postgres" ];
    postgresDatabases = map dbName (lib.attrNames bridges);
  };
}
