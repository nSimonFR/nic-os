#!/usr/bin/env bash
# Give alfie her own Proton prefix for every game on the shared NTFS Steam library.
#
# WHY: /mnt/games/SteamLibrary is NTFS (ntfs3, mounted uid=1000), so every file there —
# including each game's Proton prefix under steamapps/compatdata/<appid> — is reported as
# owned by nsimon (uid 1000) no matter who created it. Wine refuses to use a prefix that
# "is not owned by you", so EVERY Proton game launched and instantly died for alfie
# (uid 1001), while nsimon's worked. (Native Linux games are unaffected — they have no
# prefix.) The fix is a per-game Steam launch option that redirects STEAM_COMPAT_DATA_PATH
# into alfie's home (ext4, real ownership), so Proton builds a fresh prefix she owns.
#
# This generalises the old BG3-only redirect to all installed library titles. Steam keeps
# launch options across restarts, but they live in alfie's home and are not declarative;
# this oneshot re-asserts them idempotently at boot (ordered before display-manager, so
# Steam is not running) so the fix survives a Steam config reset, covers newly-installed
# games on the next boot, and is reproducible from the NixOS config.
#
# Safe by construction: never runs while alfie's Steam is up; backs up before writing;
# validates brace balance and that the redirect landed before committing; only ever ADDS
# a redirect for a game that has none — it never clobbers a launch option alfie set herself.
set -uo pipefail

PREFIX_PARENT=/home/alfie/proton-prefixes
LIB=/mnt/games/SteamLibrary/steamapps

mkdir -p "$PREFIX_PARENT" 2>/dev/null || true

# Never race Steam's own writes to localconfig.vdf.
if pgrep -u alfie -x steam >/dev/null 2>&1; then
  echo "steam is running for alfie; skipping prefix redirect re-assert"
  exit 0
fi

# Appids installed on the NTFS library (these are the ones whose prefixes live on ntfs3).
mapfile -t APPS < <(ls "$LIB"/appmanifest_*.acf 2>/dev/null \
  | sed 's#.*appmanifest_##; s#\.acf$##' | grep -E '^[0-9]+$' | sort -un)
if [ "${#APPS[@]}" -eq 0 ]; then
  echo "no appmanifests under $LIB; nothing to do"
  exit 0
fi

# Inject (or create) the LaunchOptions redirect for one appid into a working copy.
# Reads the working file, writes the patched result to stdout. Idempotent at the caller.
inject_one() {
  local app="$1" opt="$2" src="$3"
  if grep -qE "^[[:space:]]+\"$app\"[[:space:]]*$" "$src"; then
    # App block exists: add LaunchOptions right after its opening brace.
    awk -v app="$app" -v opt="$opt" '
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
      }' "$src"
  else
    # No app block yet: create a minimal one right after the "apps" { line.
    awk -v app="$app" -v opt="$opt" '
      function indent(s){ match(s, /^\t*/); return substr(s, 1, RLENGTH) }
      BEGIN { armed=0; done=0 }
      {
        s=$0; gsub(/^[ \t]+|[ \t]+$/, "", s)
        if (!done && armed && s == "{") {
          print $0
          ind=indent($0) "\t"
          print ind "\"" app "\""
          print ind "{"
          print ind "\t\"LaunchOptions\"\t\t\"" opt "\""
          print ind "}"
          armed=0; done=1; next
        }
        print $0
        if (s == "\"apps\"") { armed=1 }
      }' "$src"
  fi
}

# Does this appid's block already carry a LaunchOptions line (custom or ours)? If so, leave
# it entirely alone — we must not clobber something alfie set deliberately.
has_launch_options() {
  local app="$1" src="$2"
  awk -v app="$app" '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN { inapps=0; inblk=0; depth=0; armed=0; found=0 }
    {
      s=trim($0)
      if (s == "\"apps\"") { inapps=1 }
      if (inapps && !inblk && !armed && s == "\"" app "\"") { armed=1; next }
      if (armed && s == "{") { inblk=1; depth=1; armed=0; next }
      else if (armed) { armed=0 }
      if (inblk) {
        if (s == "{") depth++
        else if (s == "}") { depth--; if (depth==0) inblk=0 }
        if (index(s, "\"LaunchOptions\"") == 1) found=1
      }
    }
    END { print found }' "$src"
}

shopt -s nullglob
found_lc=0
for LC in /home/alfie/.local/share/Steam/userdata/*/config/localconfig.vdf; do
  found_lc=1
  work="$(mktemp)"; cp "$LC" "$work"
  changed=0

  for APP in "${APPS[@]}"; do
    OPT="STEAM_COMPAT_DATA_PATH=${PREFIX_PARENT}/${APP} %command%"

    # Already redirected to alfie's prefix? Done.
    if grep -qF "STEAM_COMPAT_DATA_PATH=${PREFIX_PARENT}/${APP} " "$work"; then
      continue
    fi
    # Custom launch option present? Respect it.
    if [ "$(has_launch_options "$APP" "$work")" = "1" ]; then
      echo "skip $APP: existing custom LaunchOptions, leaving untouched"
      continue
    fi

    tmp="$(mktemp)"
    inject_one "$APP" "$OPT" "$work" > "$tmp"

    ob=$(tr -cd '{' < "$tmp" | wc -c)
    cb=$(tr -cd '}' < "$tmp" | wc -c)
    if [ "$ob" = "$cb" ] && grep -qF "$OPT" "$tmp"; then
      mv "$tmp" "$work"
      changed=1
      echo "redirect set: $APP"
    else
      echo "skip $APP: validation failed (braces $ob/$cb)"
      rm -f "$tmp"
    fi
  done

  if [ "$changed" = 1 ]; then
    cp -a "$LC" "$LC.bak-prefixes"
    cat "$work" > "$LC"   # truncate-rewrite preserves owner/mode
    echo "patched $LC"
  else
    echo "no change needed: $LC"
  fi
  rm -f "$work"
done

[ "$found_lc" = 1 ] || echo "no alfie localconfig.vdf yet; nothing to do"
exit 0
