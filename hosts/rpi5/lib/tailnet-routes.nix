# hosts/rpi5/lib/tailnet-routes.nix
#
# mkRouteReconciler: keep a service's hostnames advertised as Tailscale subnet
# routes (so tailnet clients' traffic to them flows through this node), and
# optionally mirror the resolved IPs into ipsets for iptables to match on.
#
# `tailscale set --advertise-routes=` is ABSOLUTE: it replaces the node's whole
# route list. Advertising only one service's IPs therefore withdrew 10.7.0.1/32 and
# silently killed SideStore refresh (2026-09-14). So this reconciles instead of
# overwriting: take what the node advertises today, drop this reconciler's previous
# IPs, add the current ones, and leave every other route alone. The comparison is
# against live prefs rather than the state file so it also heals the reverse
# clobber — tailscale-autoconnect runs `tailscale up --advertise-routes=<static
# list>` on every boot, which drops these IPs. Several reconcilers run at boot, so
# the read-modify-write is serialized on a lock.
{ pkgs }:
{
  name,
  hosts,
  stateFile,
  ipv6 ? false,
  ipset4 ? null,
  ipset6 ? null,
}:
let
  inherit (pkgs) lib;
  fillSet = family: set: ''
    ipset create -exist ${set} hash:ip family ${family}
    ipset create -exist ${set}-next hash:ip family ${family}
    ipset flush ${set}-next
    for ip in $(echo "$NEW_IPS" | grep -${if family == "inet" then "v" else ""}F ':' | cut -d/ -f1 || true); do
      ipset add -exist ${set}-next "$ip"
    done
    ipset swap ${set}-next ${set}
    ipset destroy ${set}-next
  '';
in
pkgs.writeShellApplication {
  name = "${name}-route-update";
  runtimeInputs = with pkgs; [ dig gnugrep coreutils jq tailscale util-linux ipset ];
  text = ''
    exec 9>/run/tailnet-routes.lock
    flock 9

    # `|| true` is load-bearing: writeShellApplication sets `-o pipefail`, so an
    # empty dig — DNS not up yet on the boot run — makes `grep` exit 1 and kills
    # the script *at the assignment*, before the guard below. That is how the
    # 2026-09-21 boot left the Lydia routes withdrawn (interception silently
    # down) until the next daily timer, which is exactly what the boot run is
    # supposed to prevent.
    HOSTS=(${lib.escapeShellArgs hosts})
    NEW_IPS=$(
      for h in "''${HOSTS[@]}"; do
        dig +short "$h" A | grep -E '^[0-9.]+$' | sed 's|$|/32|' || true
        ${lib.optionalString ipv6 ''dig +short "$h" AAAA | grep -E '^[0-9a-f:]+$' | grep ':' | sed 's|$|/128|' || true''}
      done | sort -u
    )
    if [ -z "$NEW_IPS" ]; then
      echo "[${name}-route] DNS lookup failed, keeping current routes"
      exit 0
    fi

    # Exit-node advertisement is rendered into AdvertiseRoutes as the two
    # default routes but is a separate pref — never pass it back to --advertise-routes.
    CURRENT=$(tailscale debug prefs \
      | jq -r '.AdvertiseRoutes[]?' \
      | grep -vE '^(0\.0\.0\.0/0|::/0)$' | sort || true)
    PREV=$(tr ',' '\n' < "${stateFile}" 2>/dev/null | grep -v '^$' | sort || true)
    OTHERS=$(comm -23 <(echo "$CURRENT") <(echo "$PREV"))
    DESIRED=$(printf '%s\n%s\n' "$OTHERS" "$NEW_IPS" | grep -v '^$' | sort -u)

    if [ "$DESIRED" != "$CURRENT" ]; then
      echo "[${name}-route] routes changed: $(echo "$CURRENT" | paste -sd, -) -> $(echo "$DESIRED" | paste -sd, -)"
      tailscale set --advertise-routes="$(echo "$DESIRED" | paste -sd, -)"
    fi
    echo "$NEW_IPS" | paste -sd, - > "${stateFile}"
    ${lib.optionalString (ipset4 != null) (fillSet "inet" ipset4)}
    ${lib.optionalString (ipset6 != null) (fillSet "inet6" ipset6)}
  '';
}
