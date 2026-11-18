# mautrix-imessage on the Mac: the only bridge that cannot live on rpi5, since it
# reads Messages' chat.db and sends through AppleScript. rpi5's Tuwunel pushes
# events to this appservice over the tailnet (registration: hosts/rpi5/messaging/
# bridges.nix, same tokens through agenix), so no wsproxy is involved.
#
# Needs, by hand and once (macOS gates them on the exact binary, so a new store
# path after a bump asks again; check with `mautrix-imessage -p`):
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
  macIp = "100.78.185.89"; # this Mac on the tailnet; the registration in bridges.nix points here
  port = 29345;
  package = pkgs.callPackage ../../pkgs/services/mautrix-imessage.nix { };

  settings = {
    homeserver = {
      address = "https://${tailnetFqdn}:4040"; # Cinny's origin, which proxies /_matrix
      domain = tailnetFqdn;
      websocket_proxy = null;
    };
    appservice = {
      hostname = macIp;
      inherit port;
      id = "imessage";
      bot.username = "imessagebot";
      as_token = "$AS_TOKEN";
      hs_token = "$HS_TOKEN";
    };
    imessage.platform = "mac";
    bridge = {
      user = "@nico:${tailnetFqdn}";
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
      pkgs.envsubst
      pkgs.coreutils
    ];
    text = ''
      umask 077
      mkdir -p "${stateDir}"
      cd "${stateDir}"
      set -a
      # shellcheck source=/dev/null
      . "${config.age.secrets.mautrix-imessage-tokens.path}"
      set +a
      envsubst < ${(pkgs.formats.yaml { }).generate "mautrix-imessage.yaml" settings} > config.yaml
      exec ${lib.getExe package} -c config.yaml
    '';
  };
in
{
  age.secrets.mautrix-imessage-tokens.file = ../../shared/mautrix-imessage-tokens.env.age;

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
