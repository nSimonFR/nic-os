{ config, pkgs, lib, ... }:

{
  options.services.icloud-reminders = {
    enable = lib.mkEnableOption "iCloud Reminders sync via vdirsyncer";
  };

  config = lib.mkIf config.services.icloud-reminders.enable {
    environment.systemPackages = [ pkgs.vdirsyncer ];

    home-manager.users.nsimon.xdg.configFile."vdirsyncer/config".text = ''
      [general]
      status_path = "~/.cache/vdirsyncer"

      [pair icloud_reminders]
      a = "icloud_reminders_local"
      b = "icloud_reminders_remote"
      collections = ["home", "work"]
      metadata = ["color", "displayname"]

      [storage icloud_reminders_local]
      type = "filesystem"
      path = "~/.cache/icloud-reminders"
      fileext = ".ics"

      [storage icloud_reminders_remote]
      type = "caldav"
      url = "https://caldav.icloud.com/"
      username.fetch = ["command", "bash", "-c", "source ~/.secrets/openclaw.env 2>/dev/null; printf '%s' \"$ICLOUD_EMAIL\""]
      password.fetch = ["command", "bash", "-c", "source ~/.secrets/openclaw.env 2>/dev/null; printf '%s' \"$ICLOUD_APP_PASSWORD\""]
    '';
  };
}
