# hosts/rpi5/sudo-ssh-agent.nix
#
# sudo on a Bitwarden SSH-agent signature, for when the user is at the Mac:
# the Mac reverse-forwards its Bitwarden agent to `agentSock`
# (hosts/nbookpro/sudo-agent-forward.nix) and `mac-sudo cmd` points pam_rssh
# at it. Plain `sudo` never asks the Mac, so the phone's TOTP path
# (sudo-totp.nix) can't stall on a prompt nobody is there to answer; a refused
# or missing signature falls through to TOTP.
#
# The tunnel comes in over Tailscale SSH, so tailscaled (root) owns the socket:
# only root, i.e. pam_rssh, can reach the agent. Bitwarden must still ask on
# every use (Settings → SSH agent → "Always"), or `mac-sudo` is silent root.
{ lib, pkgs, ... }:
let
  # The sudo key: its own Bitwarden SSH key item, never a login key.
  sudoKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBneog7+eqJyvLrDJoqjdtvlCz7dn4qp7VsXo7P1HeK1 rpi5 sudo" ];
  agentSock = "/home/nsimon/.ssh/sudo-agent.sock";
in
lib.mkIf (sudoKeys != [ ]) {
  security.pam.rssh = {
    enable = true;
    # Root-owned: a user-writable key file would let nsimon enrol its own key.
    settings.auth_key_file = "/etc/ssh/sudo_keys/$ruser";
  };
  security.pam.services.sudo.rssh = true;
  environment.etc."ssh/sudo_keys/nsimon".text = lib.concatLines sudoKeys;

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "mac-sudo";
      text = ''SSH_AUTH_SOCK=${agentSock} exec /run/wrappers/bin/sudo "$@"'';
    })
  ];
}
