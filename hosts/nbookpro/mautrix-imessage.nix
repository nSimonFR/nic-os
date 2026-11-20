# mautrix-imessage on the Mac: the only bridge that cannot live on rpi5, since it
# reads Messages' chat.db and sends through AppleScript. rpi5's Tuwunel pushes
# events to this appservice over the tailnet (registration: hosts/rpi5/messaging/
# bridges.nix, same tokens through agenix), so no wsproxy is involved. The bridge
# listens on loopback; tailmux's `serve` entry for the port (configuration.nix)
# is what the tailnet address reaches.
#
# Needs, by hand and once (macOS gates them on the exact binary, so a new store
# path after a bump asks again; `mautrix-imessage -p` only tests the terminal
# you run it from, so check the launchd agent with `lsof -c mautrix-imessage`
# showing chat.db open):
#   - signed in to Messages.app
#   - Full Disk Access for the store binary (readlink -f $(which mautrix-imessage))
#   - Contacts, and Automation → Messages, on first prompt
# Normal Mac mode, SIP stays on: Matrix → iMessage carries text and attachments
# only (no replies, reactions, edits, read receipts).
{
  config,
  lib,
  pkgs,
  tailnetFqdn,
  ...
}:
let
  home = config.home.homeDirectory;
  stateDir = "${home}/Library/Application Support/mautrix-imessage";
  logs = "${home}/Library/Logs/mautrix-imessage.log";
  port = 29345;
  identity = builtins.head config.age.identityPaths;
  tokensFile = ../../shared/mautrix-imessage-tokens.env.age;
  package = pkgs.callPackage ../../pkgs/services/mautrix-imessage.nix { };

  settings = {
    homeserver = {
      address = "https://${tailnetFqdn}:4040"; # Cinny's origin, which proxies /_matrix
      domain = tailnetFqdn;
      websocket_proxy = null;
    };
    appservice = {
      hostname = "127.0.0.1";
      inherit port;
      id = "imessage";
      bot.username = "imessagebot";
      as_token = "$AS_TOKEN";
      hs_token = "$HS_TOKEN";
    };
    imessage.platform = "mac";
    bridge = {
      user = "@nico:${tailnetFqdn}";
      # Double puppeting: log in as Nico with this bridge's own appservice token
      # (its registration covers @nico), so chat rooms join him instead of inviting.
      login_shared_secret = "appservice";
      # Tuwunel has no MSC2716 batch send.
      backfill.enable = false;
      encryption.allow = false;
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

  run = pkgs.writeShellApplication {
    name = "mautrix-imessage-run";
    runtimeInputs = [
      pkgs.age
      pkgs.envsubst
      pkgs.coreutils
      pkgs.ffmpeg-headless # voice notes: Matrix opus → CAF
    ];
    text = ''
      umask 077
      mkdir -p "${stateDir}"
      cd "${stateDir}"
      # Decrypted from the ciphertext this build holds, in memory: reading the
      # agenix-mounted file could race a rotation's activation and keep the old pair.
      # The path also makes the plist change, and so restart the agent, on rotation.
      tokens=$(age -d -i "${identity}" ${tokensFile})
      set -a
      eval "$tokens"
      set +a
      envsubst < ${(pkgs.formats.yaml { }).generate "mautrix-imessage.yaml" settings} > config.yaml
      exec ${lib.getExe package} -c config.yaml
    '';
  };
in
{
  home.packages = [ package ];

  launchd.agents.mautrix-imessage = {
    enable = true;
    config = {
      ProgramArguments = [ "${run}/bin/mautrix-imessage-run" ];
      RunAtLoad = true;
      KeepAlive = true;
      ThrottleInterval = 30; # retry pace while off the tailnet
      ProcessType = "Background";
      StandardOutPath = logs;
      StandardErrorPath = logs;
    };
  };
}
