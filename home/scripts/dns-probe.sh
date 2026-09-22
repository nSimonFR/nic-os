# Where DNS actually goes on this Mac, and how long it stays dead across a
# network switch. Read-only — it changes nothing.
#
#   dns-probe           one snapshot
#   dns-probe --watch   per-second timeline; start it BEFORE switching networks,
#                       because the interesting window closes in ~90s
#
# The switch is what breaks: tailscaled stays pinned to rpi5's IPv4 endpoint and
# only later moves to the v6 one, and every resolver on this host is behind that
# tunnel. Steady state on a tether looks perfect and proves nothing.

TS="${TS:-tailscale}"

lookup() { dscacheutil -q host -a name example.com 2>/dev/null | grep -q ip_address; }

watch_mode() {
  local state=up down_at=0 t now
  echo "watching — ^C to stop. Switch networks now."
  while true; do
    t=$(date +%H:%M:%S)
    now=$(date +%s)
    if lookup; then
      if [ "$state" = down ]; then
        printf '%s  OK    <- recovered after %ss\n' "$t" "$((now - down_at))"
      else
        printf '%s  OK\n' "$t"
      fi
      state=up
    else
      if [ "$state" != down ]; then
        down_at=$now
        state=down
        printf '%s  FAIL  <- DNS lost\n' "$t"
      else
        printf '%s  FAIL  (%ss)\n' "$t" "$((now - down_at))"
      fi
    fi
    sleep 1
  done
}

snapshot() {
  local v4 v6 gw4 verdict s e out

  printf '\n== link ==\n'
  v4=$(ipconfig getifaddr en0 2>/dev/null || true)
  v6=$(ifconfig en0 2>/dev/null | awk '/inet6 [23]/{print $2; exit}' || true)
  gw4=$(netstat -rn -f inet | awk '$1=="default" && $NF=="en0"{print $2; exit}' || true)
  # 192.0.0.0/29 is the RFC 7335 CLAT range: an IPv4 default route through it
  # means the link is IPv6-only and v4 is translated. `ipconfig getifaddr` does
  # not report the CLAT address, so the route is the only reliable tell.
  case "$gw4" in
    192.0.0.*) verdict="IPv6-only link, IPv4 via 464XLAT/NAT64 (CLAT gw $gw4)" ;;
    "")        verdict="no IPv4 default route on en0" ;;
    *)         verdict="native IPv4 (gw $gw4)" ;;
  esac
  echo "en0 v4:  ${v4:-none (translated)}"
  echo "en0 v6:  ${v6:-none}"
  echo "VERDICT: $verdict"

  printf '\n== resolver order (lowest order wins) ==\n'
  scutil --dns | awk '/^resolver #[1-3]$/,/^$/' \
    | grep -E "resolver #|nameserver|if_index|order" || true

  printf '\n== tailscale path to rpi5 ==\n'
  "$TS" status 2>/dev/null | grep -E "rpi5|nphone" || echo "(tailscale not reachable)"
  timeout 30 "$TS" netcheck 2>/dev/null \
    | grep -E "IPv4:|IPv6:|MappingVaries|Nearest DERP" || true

  printf '\n== resolvers, 2s budget each ==\n'
  for ns in 100.100.100.100 100.122.54.2 1.0.0.1 1.1.1.1 9.9.9.9; do
    s=$(date +%s%N)
    out=$(dig +time=2 +tries=1 +short "@$ns" example.com 2>&1 | head -1 || true)
    e=$(date +%s%N)
    printf '%-18s %5sms  %s\n' "$ns" "$(((e - s) / 1000000))" "${out:-<no answer>}"
  done

  printf '\n== what the system itself uses ==\n'
  s=$(date +%s%N)
  out=$(dscacheutil -q host -a name example.com 2>/dev/null | awk '/ip_address/{print $2; exit}' || true)
  e=$(date +%s%N)
  printf 'dscacheutil  %5sms  %s\n' "$(((e - s) / 1000000))" "${out:-<FAILED>}"

  cat <<'EOF'

== leak check (run separately, while tethered) ==
  sudo tcpdump -ni en0 'port 53 or port 853 or udp port 41641'
Plaintext 53 to a public resolver = queries the carrier can read.
Only UDP 41641 / 443 = clean.
EOF
}

case "${1:-}" in
  --watch) watch_mode ;;
  "")      snapshot ;;
  *)       echo "usage: dns-probe [--watch]" >&2; exit 2 ;;
esac
