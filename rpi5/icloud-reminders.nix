{ config, pkgs, lib, ... }:

{
  options.services.icloud-reminders = {
    enable = lib.mkEnableOption "iCloud Reminders sync via vdirsyncer";
  };

  config = lib.mkIf config.services.icloud-reminders.enable {
    # Ensure vdirsyncer is available
    environment.systemPackages = [ pkgs.vdirsyncer ];

    # Configure vdirsyncer for iCloud CalDAV
    home-manager.users.nsimon = {
      xdg.configFile."vdirsyncer/config".text = ''
        [general]
        status_path = "~/.cache/vdirsyncer"

        [pair icloud_reminders]
        a = "icloud_reminders_local"
        b = "icloud_reminders_remote"
        collections = ["Reminders"]
        metadata = ["color", "displayname"]

        [storage icloud_reminders_local]
        type = "filesystem"
        path = "~/.cache/icloud-reminders"
        fileext = ".ics"

        [storage icloud_reminders_remote]
        type = "caldav"
        url.fetch = ["command", "${pkgs.bash}/bin/bash", "-c", ''
          source ~/.secrets/openclaw.env 2>/dev/null || true
          echo "https://''${ICLOUD_EMAIL}@caldav.icloud.com/calendars/caldav/Reminders/"
        '']
        password.fetch = ["command", "${pkgs.bash}/bin/bash", "-c", ''
          source ~/.secrets/openclaw.env 2>/dev/null || true
          echo "''${ICLOUD_APP_PASSWORD}"
        '']
        ssl_verify = true
      '';
    };
  };
}
