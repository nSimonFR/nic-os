# SideStore LAN-free refresh reflector.
#
# SideStore re-signs sideloaded apps every 7 days without a computer: it runs the
# "computer" side (minimuxer) on the device itself and uses an on-device VPN
# (LocalDevVPN / StosVPN) to loop traffic destined for the fixed address 10.7.0.1
# back to the phone, so iOS believes a real iTunes host is present.
#
# This module moves that loopback OFF the device. rpi5 advertises 10.7.0.1/32 as a
# Tailscale subnet route (see configuration.nix), so the phone's 10.7.0.1 packets
# arrive here on tailscale0, and a stateless nftables rule swaps source/destination
# (ports preserved) to hairpin them straight back to the phone — exactly what
# StosVPN does, but on the tailnet instead of a per-device VPN. The phone then
# refreshes over Wi-Fi or cellular with only Tailscale running, no SideStore VPN.
#
# Reference (Method 1b, whole-network, by @KusakabeShi):
#   https://lantian.pub/en/article/modify-computer/sidestore-without-stosvpn-across-lan.lantian/
#
# Design notes:
#   - Implemented as an INDEPENDENT nftables table loaded by a oneshot, NOT via
#     networking.nftables.*: enabling the nftables firewall backend would break the
#     iptables-string rules in sumeria-mitm.nix. An independent table coexists fine
#     with the default iptables-nft firewall and Tailscale's own netfilter tables.
#   - Scoped to iifname "tailscale0" so ordinary LAN traffic to 10.7.0.1 is left
#     alone (on the LAN it currently routes out the default gateway, unchanged).
#   - A `filter`-type prerouting chain at priority -350 runs before raw (-300) and
#     conntrack (-200), and before Tailscale's subnet-router forwarding, so the
#     packet is reflected before any route lookup could send it out the LAN default
#     gateway. `notrack` (set pre-conntrack) keeps conntrack from mangling the
#     stateless swap. (A `nat`-type chain can't be used here: the kernel requires
#     nat chains to have priority > -200, and this is a raw payload swap, not NAT.)

{ config, lib, pkgs, ... }:

let
  cfg = config.services.sidestore-reflector;

  # StosVPN's fixed virtual-computer address — not configurable in SideStore.
  virtualComputerIp = "10.7.0.1";

  rules = pkgs.writeText "sidestore-reflector.nft" ''
    table ip sidestore {
      chain prerouting {
        type filter hook prerouting priority -350; policy accept;
        iifname "tailscale0" ip daddr ${virtualComputerIp} ip daddr set ip saddr ip saddr set ${virtualComputerIp} notrack
      }
    }
  '';
in
{
  options.services.sidestore-reflector = {
    enable = lib.mkEnableOption "SideStore 10.7.0.1 tailnet reflector" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.sidestore-reflector = {
      description = "SideStore 10.7.0.1 tailnet reflector (nftables hairpin)";
      after = [ "tailscaled.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # An independent table; delete-on-stop makes it fully reversible.
        ExecStart = "${pkgs.nftables}/bin/nft -f ${rules}";
        ExecStop = "${pkgs.nftables}/bin/nft delete table ip sidestore";
      };
    };
  };
}
