# Stdio-only MCP servers behind mcp-stdio-bridge (nicos-scripts), served as
# Streamable HTTP for Aperture's `mail` and `mtg` connectors (aperture-sync.nix).
# Socket-activated: 0 at rest; the child server starts on the first request.
#
# A bridge with `token = true` requires a bearer token, generated once into
# /var/lib/mcp-tokens/<name> by mcp-tokens.service and handed to Aperture by
# aperture-config-sync.
{ pkgs, lib, ... }:
let
  tokenDir = "/var/lib/mcp-tokens";

  mcpEmailServer = pkgs.callPackage ../../../pkgs/agents/mcp-email-server.nix { };
  mtgMcp = pkgs.callPackage ../../../pkgs/agents/mtg-mcp.nix { };

  # Proton through hydroxide (loopback) and Gmail. Passwords only inline, so
  # mailSetup fills the @…@ placeholders from credentials into the state dir.
  mailConfig =
    let
      endpoint = host: port: tls: password: {
        inherit host port password;
        use_ssl = tls;
        start_ssl = false;
        verify_ssl = tls;
      };
      account =
        name: address: imap: smtp: extra:
        {
          account_name = name;
          email_address = address;
          full_name = "Nicolas Simon"; # required by the TOML schema
          # Both providers file sent mail themselves; an IMAP append would duplicate it.
          save_to_sent = false;
          incoming = imap // {
            user_name = address;
          };
          outgoing = smtp // {
            user_name = address;
          };
        }
        // extra;
    in
    (pkgs.formats.toml { }).generate "mail-mcp.toml" {
      credential_storage = "plaintext";
      # Sending is granted here, gated in Hermes (mcp_servers.aperture-send) and
      # denied to Claude Code (claude-settings.json).
      allowed_recipients = [ "*" ];
      allowed_mutations = [
        "draft"
        "organize"
        "send"
      ];
      emails = [
        (account "proton" "nsimon@protonmail.com" (endpoint "127.0.0.1" 1143 false "@PROTON_PASSWORD@") (
          endpoint
            "127.0.0.1"
            1025
            false
            "@PROTON_PASSWORD@"
        ) { description = "Personal mail (nsimon@protonmail.com, @pm.me) via the hydroxide bridge"; })
        (account "gmail" "hemeraude@gmail.com" (endpoint "imap.gmail.com" 993 true "@GMAIL_PASSWORD@") (
          endpoint
            "smtp.gmail.com"
            465
            true
            "@GMAIL_PASSWORD@"
        ) { description = "Personal Gmail (hemeraude@gmail.com)"; })
      ];
    };

  # A missing password leaves that account failing its login, not the unit.
  mailSetup = pkgs.writeShellApplication {
    name = "mail-mcp-setup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.replace-secret
    ];
    text = ''
      cfg="$STATE_DIRECTORY/config.toml"
      install -m 0600 ${mailConfig} "$cfg"
      replace-secret @PROTON_PASSWORD@ "$CREDENTIALS_DIRECTORY/proton" "$cfg" || true
      replace-secret @GMAIL_PASSWORD@ "$CREDENTIALS_DIRECTORY/gmail" "$cfg" || true
    '';
  };

  bridges = {
    mail = {
      description = "Mail MCP (mcp-email-server)";
      internalPort = 13363;
      proxyPort = 8410;
      publicPort = 4050;
      order = 178;
      token = true;
      command = [
        "${mcpEmailServer}/bin/mcp-email-server"
        "stdio"
      ];
      # Raw IMAP/SMTP, deletion and writing attachments to disk.
      exclude = [
        "email_command"
        "delete_emails"
        "download_attachment"
      ];
      environment = {
        MCP_EMAIL_SERVER_CONFIG_PATH = "/var/lib/mail-mcp/config.toml";
        HOME = "/var/lib/mail-mcp";
      };
      serviceConfig = {
        StateDirectory = "mail-mcp";
        StateDirectoryMode = "0700";
        ExecStartPre = "${mailSetup}/bin/mail-mcp-setup";
        LoadCredential = [
          "proton:/run/agenix/protonmail-bridge-password"
          "gmail:/run/agenix/gmail-app-password"
        ];
      };
      backup = [ "none" ];
      backupNote = "mail stays on Proton and Gmail; the state dir is a cache";
    };
    # Public Magic: The Gathering data: no token.
    mtg = {
      description = "MTG MCP (mtg-mcp)";
      internalPort = 13365;
      proxyPort = 8430;
      publicPort = 4070;
      order = 179;
      token = false;
      command = [ "${mtgMcp}/bin/mtg-mcp" ];
      exclude = [ ];
      environment = { };
      serviceConfig = { };
      backup = [ "none" ];
      backupNote = "stateless — Scryfall, EDHREC, Moxfield and Archidekt live";
    };
  };

  mkBridge =
    name: b:
    let
      unit = "${name}-mcp";
    in
    {
      systemd.services.${unit} = {
        inherit (b) description;
        after = [ "network-online.target" ] ++ lib.optional b.token "mcp-tokens.service";
        wants = [ "network-online.target" ];
        requires = lib.optional b.token "mcp-tokens.service";
        environment = b.environment // {
          MCP_BRIDGE_HOST = "127.0.0.1";
          MCP_BRIDGE_PORT = toString b.internalPort;
        };
        serviceConfig = lib.mkMerge [
          {
            ExecStart = lib.escapeShellArgs (
              [ "${pkgs.nicos-scripts}/bin/mcp-stdio-bridge" ]
              ++ lib.concatMap (t: [
                "--exclude"
                t
              ]) b.exclude
              ++ [ "--" ]
              ++ b.command
            );
            DynamicUser = true;
            Restart = "on-failure";
            RestartSec = "10s";
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
          }
          (lib.mkIf b.token { LoadCredential = [ "token:${tokenDir}/${name}" ]; })
          b.serviceConfig
        ];
      };

      services.socketActivate.${unit} = {
        enable = true;
        realUnit = "${unit}.service";
        listen = [ "127.0.0.1:${toString b.proxyPort}" ];
        backend = "127.0.0.1:${toString b.internalPort}";
        idleSec = 600;
        readyProbe.url = "http://127.0.0.1:${toString b.internalPort}/health";
      };

      nic.services.${unit} = {
        inherit (b) backup backupNote;
        public = {
          inherit (b) order;
          port = b.publicPort;
          backend = "http://127.0.0.1:${toString b.proxyPort}";
          funnel = false;
          # Tailnet-only; a token-less bridge serves public data only.
          authenticated = b.token;
        };
      };
    };
in
{
  config = lib.mkMerge (
    lib.mapAttrsToList mkBridge bridges
    ++ [
      {
        # One random bearer per token-protected MCP server, kept across boots.
        systemd.services.mcp-tokens = {
          description = "Bearer tokens for the token-protected MCP servers";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StateDirectory = "mcp-tokens";
            StateDirectoryMode = "0700";
            UMask = "0077";
          };
          script = ''
            # mail here, messaging in messaging/messaging-mcp.nix.
            for name in mail messaging; do
              f=${tokenDir}/$name
              [ -s "$f" ] || ${pkgs.openssl}/bin/openssl rand -hex 32 > "$f"
            done
          '';
        };
      }
    ]
  );
}
