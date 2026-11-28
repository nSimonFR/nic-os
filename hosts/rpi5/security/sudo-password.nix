# hosts/rpi5/security/sudo-password.nix
#
# sudo for nsimon on the Unix password, after mac-sudo (sudo-ssh-agent.nix).
# Agents run as nsimon, so sudo caches nothing: one password prompt, one command.
# Set or change it as root: `mac-sudo passwd nsimon`.
{
  security.sudo.extraRules = [
    {
      users = [ "nsimon" ];
      commands = [ { command = "ALL"; } ];
    }
  ];
  # A cached sudo would turn one prompt into minutes of root for every agent.
  security.sudo.extraConfig = ''
    Defaults:nsimon timestamp_timeout=0
  '';
}
