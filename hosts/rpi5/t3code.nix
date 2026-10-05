# hosts/rpi5/t3code.nix
#
# T3 Code server, reached from the desktop/mobile/web apps through T3 Connect
# (a cloudflared tunnel to 127.0.0.1:3773; nothing is exposed on the tailnet).
#
# Sign-in and link state live in ~/.t3/userdata, set up once by hand:
#   t3 connect login --headless && t3 connect link
#   sudo systemctl restart t3code
{
  config,
  pkgs,
  username,
  ...
}:
let
  t3code = pkgs.callPackage ../../pkgs/agents/t3code.nix { };
  homeDir = config.users.users.${username}.home;
in
{
  # `t3 pair`, `t3 connect status`, `t3 project …` talk to the running server.
  environment.systemPackages = [ t3code ];

  systemd.services.t3code = {
    description = "T3 Code server (T3 Connect host)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    # Agent sessions run in this unit's cgroup, and one of them may be the
    # rebuild itself — same hazard as claude-remote-control. New versions land
    # on `systemctl restart t3code` or the next boot.
    restartIfChanged = false;

    serviceConfig = {
      # A system unit as the human (see dsh.nix): user units here can stop
      # despite Linger=yes, out of systemd-failed-alert's sight.
      User = username;
      Group = config.users.users.${username}.group;
      WorkingDirectory = homeDir;

      ExecStart = "${t3code}/bin/t3 serve --no-browser";

      # Upstream's own unit (`t3 service install`) uses these.
      KillMode = "mixed";
      Restart = "always";
      RestartSec = 5;
      # SIGTERM exits 130, which would mark every clean stop as failed.
      SuccessExitStatus = 130;

      Environment = [
        "HOME=${homeDir}"
        # Providers (claude, codex) and the tools their sessions call.
        "PATH=/etc/profiles/per-user/${username}/bin:/run/wrappers/bin:/run/current-system/sw/bin"
        "SHELL=/etc/profiles/per-user/${username}/bin/zsh"
        # Otherwise T3 Connect downloads its own cloudflared into ~/.t3.
        "T3CODE_CLOUDFLARED_PATH=${pkgs.cloudflared}/bin/cloudflared"
      ];
    };
  };

  nic.services.t3code = {
    backup     = [ "none" ];
    backupNote = "Thread history in ~/.t3/userdata; same class as ~/.claude, the durable output is commits.";
  };
}
