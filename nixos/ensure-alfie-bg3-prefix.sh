#!/usr/bin/env bash
# Ensure alfie's Baldur's Gate 3 Proton prefix is redirected to a path she owns.
#
# WHY: /mnt/games is NTFS (ntfs3, mounted uid=1000), so every file there — including
# the shared Proton prefix at SteamLibrary/steamapps/compatdata/1086940/pfx — is
# reported as owned by nsimon (uid 1000). Wine refuses a prefix that "is not owned by
# you", so BG3 launched and instantly died ONLY for alfie (uid 1001), while nsimon's
# worked. Fix: give alfie a per-user prefix in her home (real ext4 ownership) via a
# Steam per-game launch option (STEAM_COMPAT_DATA_PATH override).
#
# Steam preserves launch options across restarts, but they live in alfie's home and are
# not declarative. This oneshot re-asserts the option idempotently at boot (ordered
# before display-manager, so Steam is not running), so the fix survives a Steam config
# reset and is reproducible from the NixOS config. Safe: backs up, validates brace
# balance, only writes when the BG3 app block exists and the option is genuinely missing.
set -uo pipefail

APP=1086940
PREFIX_PARENT=/home/alfie/proton-prefixes
OPT="STEAM_COMPAT_DATA_PATH=${PREFIX_PARENT}/${APP} %command%"
MARKER="proton-prefixes/${APP}"

# Never race Steam's own writes to localconfig.vdf.
if pgrep -u alfie -x steam >/dev/null 2>&1; then
  echo "steam is running for alfie; skipping launch-option re-assert"
  exit 0
fi

shopt -s nullglob
found=0
for LC in /home/alfie/.local/share/Steam/userdata/*/config/localconfig.vdf; do
  found=1
  if grep -q "$MARKER" "$LC"; then
    echo "launch option already present: $LC"
    continue
  fi

  tmp="$(mktemp)"
  awk -v app="$APP" -v opt="$OPT" '
    function indent(s){ match(s, /^\t*/); return substr(s, 1, RLENGTH) }
    BEGIN { inapps=0; armed=0; done=0 }
    {
      print $0
      s=$0; gsub(/^[ \t]+|[ \t]+$/, "", s)
      if (s == "\"apps\"") { inapps=1 }
      if (inapps && !done && s == "\"" app "\"") { armed=1; next }
      if (armed && s == "{") {
        print indent($0) "\t\"LaunchOptions\"\t\t\"" opt "\""
        armed=0; done=1
      } else if (armed) { armed=0 }
    }' "$LC" > "$tmp"

  ob=$(tr -cd '{' < "$tmp" | wc -c)
  cb=$(tr -cd '}' < "$tmp" | wc -c)
  if [ "$ob" = "$cb" ] && grep -q "$MARKER" "$tmp"; then
    cp -a "$LC" "$LC.bak-bg3prefix"
    cat "$tmp" > "$LC"   # truncate-rewrite preserves owner/mode
    echo "patched launch option into: $LC"
  else
    # BG3 app block not present yet, or validation failed — leave file untouched.
    echo "no change ($LC): BG3 app block absent or validation failed (braces $ob/$cb)"
  fi
  rm -f "$tmp"
done

[ "$found" = 1 ] || echo "no alfie localconfig.vdf yet; nothing to do"
exit 0
