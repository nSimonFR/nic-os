# Security invariants, checked at eval time so CI refuses to deploy a config
# that breaks one. Everything here is about what the LAN and the internet can
# reach; tailnet-only exposure is policed by nic.services.*.public instead
# (an internet-reachable service must set authenticated = true).
{ config, lib, ... }:

let
  fw  = config.networking.firewall;
  ssh = config.services.openssh.settings;

  # What the LAN may reach. 22 = sshd (keys only, below), 53 = blocky,
  # 41641/udp = tailscale NAT traversal.
  lanTcp = [ 22 53 ];
  lanUdp = [ 53 41641 ];

  extra = allowed: ports: lib.subtractLists allowed ports;

  # Per-interface openings bypass the global lists; only the tailnet may have them.
  nonTailnetIfaces = lib.filterAttrs (n: _: n != "tailscale0") fw.interfaces;
  ifaceOpenings = lib.concatLists (lib.mapAttrsToList (n: i:
    lib.optional
      (i.allowedTCPPorts != [ ] || i.allowedUDPPorts != [ ]
        || i.allowedTCPPortRanges != [ ] || i.allowedUDPPortRanges != [ ])
      n) nonTailnetIfaces);
in
{
  assertions = [
    {
      assertion = fw.enable;
      message = "security-policy: networking.firewall must stay enabled.";
    }
    {
      assertion = extra lanTcp fw.allowedTCPPorts == [ ]
        && extra lanUdp fw.allowedUDPPorts == [ ]
        && fw.allowedTCPPortRanges == [ ] && fw.allowedUDPPortRanges == [ ];
      message =
        "security-policy: a module opened a port to the LAN: tcp "
        + toString (extra lanTcp fw.allowedTCPPorts) + " udp "
        + toString (extra lanUdp fw.allowedUDPPorts)
        + ". Use networking.firewall.interfaces.tailscale0 (or openFirewall = false), "
        + "or add it to lanTcp/lanUdp in hosts/rpi5/security-policy.nix on purpose.";
    }
    {
      assertion = ifaceOpenings == [ ];
      message =
        "security-policy: ports opened on non-tailnet interface(s) "
        + toString ifaceOpenings + ".";
    }
    {
      assertion = extra [ "tailscale0" "lo" ] fw.trustedInterfaces == [ ];
      message =
        "security-policy: only tailscale0 may be a trusted interface, got "
        + toString fw.trustedInterfaces + ".";
    }
    {
      assertion = ssh.PasswordAuthentication == false
        && ssh.KbdInteractiveAuthentication == false
        && ssh.PermitRootLogin == "no";
      message =
        "security-policy: sshd must be keys-only with no root login "
        + "(PasswordAuthentication, KbdInteractiveAuthentication = false; PermitRootLogin = \"no\").";
    }
    {
      assertion = config.users.users.root.openssh.authorizedKeys.keys == [ ]
        && config.users.users.root.openssh.authorizedKeys.keyFiles == [ ];
      message = "security-policy: root must have no SSH authorized keys.";
    }
    # Agents run as nsimon and Agent Vault's keys are root-only, so nsimon must
    # have no path to root.
    {
      # extraRules always holds NixOS's own %wheel rule, so look for nsimon by name.
      assertion = !(lib.elem "wheel" config.users.users.nsimon.extraGroups)
        && !(lib.elem "nsimon" config.users.groups.wheel.members)
        && !(lib.elem "nsimon" config.nix.settings.trusted-users)
        && !(lib.any (r: lib.elem "nsimon" (r.users or [ ])) config.security.sudo.extraRules);
      message = "security-policy: nsimon must not be in wheel, a trusted nix user, or in a sudo rule.";
    }
  ];
}
