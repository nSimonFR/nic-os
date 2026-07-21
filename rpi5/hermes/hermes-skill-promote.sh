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
# where repo-seeded dirs are excluded by DIRECTORY name ($DEST_SKILLS +
# $PICOCLAW_SKILLS, which we copy verbatim so dir names line up) and builtins by
# frontmatter `name:`. We map each runtime DIRECTORY to its `name:` (dir != name,
# e.g. dir `tavily-search` has name `tavily`) before the builtin check.
#
# Promote-once: a skill already present in $DEST_SKILLS is left alone, so a
# review edit you make before committing is never clobbered by a later run.
# Once you commit it, Hermes re-classifies it as `local` and it's excluded.
#
# Env (all set by the systemd unit wrapper):
#   HERMES_SKILLS_DIR   runtime skills dir             (~/.hermes/skills)
#   DEST_SKILLS         repo dest for new skills       (…/nic-os/shared/skills)
#   PICOCLAW_SKILLS     other repo-seeded skills dir   (…/rpi5/picoclaw/skills)
#   TG_CHAT_ID          Telegram chat id for the nudge (optional)
#   TG_TOKEN_FILE       file holding the bot token     (optional)
# Tools (hermes, systemctl, rsync, curl, awk, install) come from the wrapper PATH.
set -euo pipefail

HERMES_SKILLS_DIR="${HERMES_SKILLS_DIR:-$HOME/.hermes/skills}"
DEST_SKILLS="${DEST_SKILLS:?DEST_SKILLS must be set}"
PICOCLAW_SKILLS="${PICOCLAW_SKILLS:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
TG_TOKEN_FILE="${TG_TOKEN_FILE:-/run/agenix/telegram-bot-token}"

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

# seededDirs = DIRECTORY names we seed from the repo (shared/skills + picoclaw
# skills). These are already versioned, so exclude them by dir name. DEST_SKILLS
# doubles as a seed source, so anything already promoted is excluded here too.
seededDirs="$( { [ -d "$DEST_SKILLS" ] && ls -1 "$DEST_SKILLS"; [ -n "$PICOCLAW_SKILLS" ] && [ -d "$PICOCLAW_SKILLS" ] && ls -1 "$PICOCLAW_SKILLS"; } 2>/dev/null | sort -u)"

promoted=""
while IFS= read -r skdir; do
  [ -n "$skdir" ] || continue
  d="$(basename "$skdir")"
  smd="$skdir/SKILL.md"
  [ -f "$smd" ] || continue

  # Skip skills we seed from the repo (matched by directory name).
  printf '%s\n' "$seededDirs" | grep -qxF "$d" && continue

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

# Best-effort Telegram nudge so the human knows to review + commit.
if [ -n "$TG_CHAT_ID" ] && [ -r "$TG_TOKEN_FILE" ]; then
  token="$(cat "$TG_TOKEN_FILE")"
  msg="🧠 Hermes wrote new skill(s): <b>$(printf '%s' "$promoted" | sed 's/ /, /g')</b>
Copied to <code>shared/skills/</code> in nic-os (untracked). Review, then <code>git add</code> + commit + rebuild to version them."
  curl -sf -X POST "https://api.telegram.org/bot$token/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d parse_mode=HTML \
    --data-urlencode "text=$msg" >/dev/null || log "telegram notify failed (non-fatal)"
fi
