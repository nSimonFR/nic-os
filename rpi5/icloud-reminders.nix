{ config, pkgs, lib, ... }:

{
  # iCloud Reminders integration via vdirsyncer + CalDAV
  # Configure credentials in ~/.secrets/openclaw.env before enabling:
  #   ICLOUD_EMAIL="your-apple-id@icloud.com"
  #   ICLOUD_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"  (app-specific password)

  environment.systemPackages = [ pkgs.vdirsyncer ];

  home-manager.users.nsimon.xdg.configFile."vdirsyncer/config".text = ''
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
}
