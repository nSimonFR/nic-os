#!/usr/bin/env bash
# hermes-skill-promote — copy Hermes self-authored skills into the nic-os repo
# working tree so they can be reviewed and version-controlled by hand.
#
# Why this exists: Hermes' signature feature is that it writes its own SKILL.md
# skills from repeated workflows (see `hermes curator` / `hermes learning`). It
# writes them into $HERMES_SKILLS_DIR, intermixed with the skills we seed from
# the repo. Nothing flows back to the repo on its own, so those skills would
# never be versioned. This script bridges that gap — but stops short of git:
# it copies new skills into $DEST_SKILLS and leaves them UNTRACKED for a human
# to `git add` / commit / rebuild. No automatic commits (a malformed SKILL.md
# would break claude.nix skill discovery on every agent, and auto-committing
# LLM-generated content into a Nix-evaluated repo is a footgun).
#
# Classification: Hermes' `hermes skills list` Source column only says where a
# skill physically lives — `builtin` (inside the Hermes binary, re-seeded every
# start) vs `local` (any on-disk skill). It does NOT distinguish skills we seed
# from the repo from ones Hermes authored itself — both are `local`. So we can't
# key off Source alone. Instead:
#   promote = (on-disk skills) − (repo-seeded dirs) − (builtins)
# where repo-seeded dirs are excluded by DIRECTORY name ($SEEDED_SKILL_NAMES,
# computed in Nix from the SAME lineage list that seeds the runtime dir, plus a
# live listing of $DEST_SKILLS) and builtins by frontmatter `name:`. We map each
# runtime DIRECTORY to its `name:` (dir != name, e.g. dir `tavily-search` has
# name `tavily`) before the builtin check.
#
# Promote-once: a skill already present in $DEST_SKILLS is left alone, so a
# review edit you make before committing is never clobbered by a later run.
# Once you commit it, Hermes re-classifies it as `local` and it's excluded.
#
# Env (all set by the systemd unit wrapper):
#   HERMES_SKILLS_DIR   runtime skills dir             (~/.hermes/skills)
#   DEST_SKILLS         repo dest for new skills       (…/nic-os/shared/skills)
#   SEEDED_SKILL_NAMES  colon-separated dir names the repo seeds, from
#                       hermes.nix's skillLineages (required — see the
#                       fail-safe below)
#   TELEGRAM_SEND       one-shot Telegram sender       (optional; the wrapped
#                       shared/scripts/telegram-send.sh, already carrying the
#                       token path + chat id)
# Tools (hermes, systemctl, rsync, curl, awk, install) come from the wrapper PATH.
set -euo pipefail

HERMES_SKILLS_DIR="${HERMES_SKILLS_DIR:-$HOME/.hermes/skills}"
DEST_SKILLS="${DEST_SKILLS:?DEST_SKILLS must be set}"
SEEDED_SKILL_NAMES="${SEEDED_SKILL_NAMES:-}"
TELEGRAM_SEND="${TELEGRAM_SEND:-}"

log() { echo "hermes-skill-promote: $*"; }

# No skills get authored while Hermes is stopped — and running the (heavy Python)
# hermes CLI when the agent is inactive is pure waste. Skip cleanly.
if ! systemctl --user is-active --quiet hermes.service; then
  log "hermes.service inactive — nothing to do"
  exit 0
fi

[ -d "$HERMES_SKILLS_DIR" ] || { log "no skills dir at $HERMES_SKILLS_DIR"; exit 0; }

# builtinNames = frontmatter names Hermes ships inside its binary (Source=builtin).
# Fail SAFE: Hermes always has ~70 builtins; an empty list means the CLI failed
# to enumerate, and proceeding would misclassify every builtin as promotable and
# dump them all into the repo. So abort unless we got a non-empty builtin set.
listing="$(hermes skills list 2>/dev/null || true)"
builtinNames="$(printf '%s\n' "$listing" | awk -F'│' '
  NF>=6 && $4 !~ /Source/ {
    name=$2; src=$4;
    gsub(/^[ \t]+|[ \t]+$/, "", name); gsub(/^[ \t]+|[ \t]+$/, "", src);
    if (name != "" && src == "builtin") print name;
  }')"
if [ -z "$builtinNames" ]; then
  log "WARNING: no builtin skills enumerated from 'hermes skills list' — aborting (fail-safe)"
  exit 0
fi

# seededNames = repo-seeded DIRECTORY names, excluded because they are already
# versioned. Fail SAFE like the builtin set above: with no seeded names every
# repo-seeded skill reads as agent-authored and Hermes' private skills get
# auto-published to every general agent.
if [ -z "$SEEDED_SKILL_NAMES" ]; then
  log "WARNING: SEEDED_SKILL_NAMES is empty — aborting (fail-safe; see hermes.nix skillLineages)"
  exit 0
fi
# Unioned with a live $DEST_SKILLS listing, which catches skills promoted by an
# earlier run but not yet committed — Nix evaluates from the git index.
seededNames="$(
  {
    printf '%s\n' "$SEEDED_SKILL_NAMES" | tr ':' '\n'
    [ -d "$DEST_SKILLS" ] && ls -1 "$DEST_SKILLS"
  } 2>/dev/null | sed '/^[[:space:]]*$/d' | sort -u
)"

promoted=""
while IFS= read -r skdir; do
  [ -n "$skdir" ] || continue
  d="$(basename "$skdir")"
  smd="$skdir/SKILL.md"
  [ -f "$smd" ] || continue

  # Skip skills we seed from the repo (matched by directory name).
  printf '%s\n' "$seededNames" | grep -qxF "$d" && continue

  # Directory -> frontmatter name (first `name:` in the leading --- block).
  name="$(awk -F: '/^name:/ { sub(/^name:[ \t]*/, "", $0); gsub(/^[ \t]+|[ \t]+$/, "", $0); gsub(/["'"'"']/, "", $0); print; exit }' "$smd")"
  [ -n "$name" ] || continue

  # Skip Hermes builtins (matched by frontmatter name).
  printf '%s\n' "$builtinNames" | grep -qxF "$name" && continue

  # What remains is agent-authored (or hub-installed) → promote.
  dest="$DEST_SKILLS/$d"
  # Promote-once: never clobber a copy already in the repo working tree.
  if [ -e "$dest" ]; then
    continue
  fi

  install -d "$dest"
  rsync -a --delete "$skdir/" "$dest/"
  log "promoted new skill '$name' (dir: $d) -> $dest"
  promoted="$promoted $d"
done < <(find "$HERMES_SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

promoted="${promoted# }"
if [ -z "$promoted" ]; then
  log "nothing new to promote"
  exit 0
fi

log "promoted:$promoted"

# Best-effort Telegram nudge so the human knows to review + commit. Goes
# through the one-shot seam (shared/notify.nix `send`, wrapped with the token +
# chat id by hermes.nix) rather than hand-rolling the Bot API here.
if [ -x "$TELEGRAM_SEND" ]; then
  msg="🧠 Hermes wrote new skill(s): <b>$(printf '%s' "$promoted" | sed 's/ /, /g')</b>
Copied to <code>shared/skills/</code> in nic-os (untracked). Review, then <code>git add</code> + commit + rebuild to version them."
  "$TELEGRAM_SEND" "$msg" >/dev/null || log "telegram notify failed (non-fatal)"
fi
