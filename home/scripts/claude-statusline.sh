#!/usr/bin/env bash
# Claude Code status line, styled after the spaceship-prompt zsh theme this
# machine already uses (home/zsh.nix → zplug spaceship-prompt/spaceship-prompt).
#
# Spaceship traits reproduced deliberately:
#   - dir      cyan bold, truncated to the *repo root* (SPACESHIP_DIR_TRUNC_REPO,
#              on by default) so it reads `nic-os/home/scripts`, not `~/n/h/s`;
#              outside a repo, the last 3 components with `~` for $HOME.
#   -   git    magenta branch, red status symbols (+staged !modified ?untracked
#              »renamed ✘deleted $stashed) and ⇡⇣ divergence counts.
#   - exec     yellow elapsed time.
# The remaining segments are the Claude-specific half of the prompt: model,
# context-window gauge, session cost, and the net diff this session has written.
#
# Wired as settings.json `statusLine` → ~/.claude/hooks/statusline (home/claude.nix,
# which is also what puts jq/git/coreutils on PATH). Claude Code re-runs this on a
# 300ms debounce after every state change, so it must stay cheap: exactly one
# `jq` and one `git status` per render, no network, no subshell loops.
#
# Always exits 0 and always prints something — a failing status line command
# leaves the user staring at a blank bar with no clue why.
set +e

esc=$'\033'
reset="${esc}[0m"
dim="${esc}[2m"
red="${esc}[31m"
green="${esc}[32m"
yellow="${esc}[33m"
magenta="${esc}[35m"
cyan_b="${esc}[1;36m"

# `read -d ''` slurps stdin whole (no NUL in the payload, so it stops at EOF and
# returns non-zero with $input already set). Avoids forking `cat` — the only
# external commands this script may use are jq, git and awk, which is exactly
# what the wrapper in home/claude.nix pins onto PATH.
IFS= read -r -d '' input

# One jq pass for everything, joined on US (0x1f). NOT tab: tab is IFS-whitespace,
# so `read` collapses runs of it and strips leading/trailing — an absent optional
# key (fast_mode, effort, agent, pr) would silently shift every later field left.
# A non-whitespace IFS char preserves empty fields positionally.
IFS=$'\037' read -r cwd model ctx_used ctx_size cost dur_ms added removed \
  fast effort agent_name pr_num rl5h < <(
  printf '%s' "$input" | jq -r '
    [ .cwd // "",
      (.model.display_name // .model.id // ""),
      (.context_window.used_percentage // 0),
      (.context_window.context_window_size // 0),
      (.cost.total_cost_usd // 0),
      (.cost.total_duration_ms // 0),
      (.cost.total_lines_added // 0),
      (.cost.total_lines_removed // 0),
      (if .fast_mode then "1" else "" end),
      (.effort.level // ""),
      (.agent.name // ""),
      (.pr.number // ""),
      (.rate_limits.five_hour.used_percentage // 0)
    ] | map(tostring) | join("\u001f")' 2>/dev/null
)
[ -z "$cwd" ] && cwd="$PWD"

out=""
sep=" ${dim}·${reset} "

# ── dir ────────────────────────────────────────────────────────────────────
# --show-toplevel resolves through a linked worktree to that worktree's root,
# which is what we want: a Claude Code worktree should read as its own root.
repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$repo_root" ]; then
  rel="${cwd#"$repo_root"}"
  dir="${repo_root##*/}${rel}"
else
  dir="${cwd/#$HOME/\~}"
  # Keep the last 3 components (spaceship's SPACESHIP_DIR_TRUNC=3). Pure
  # parameter expansion — no `rev`/`cut` fork, and it survives spaces in a path.
  if [[ $dir == */*/*/* ]]; then
    d1="${dir##*/}"
    d2="${dir%/*}"; d2="${d2##*/}"
    d3="${dir%/*/*}"; d3="${d3##*/}"
    dir="…/${d3}/${d2}/${d1}"
  fi
fi
out="${cyan_b}${dir}${reset}"

# ── git ────────────────────────────────────────────────────────────────────
# porcelain=v2 --branch gives branch name, ahead/behind and the file states in
# a SINGLE call — v1 would need a second `rev-list` for divergence.
if [ -n "$repo_root" ]; then
  git_status=$(git -C "$cwd" status --porcelain=v2 --branch --untracked-files=normal 2>/dev/null)
  branch=$(printf '%s' "$git_status" | awk '/^# branch.head /{print $3; exit}')
  [ "$branch" = "(detached)" ] && branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)

  if [ -n "$branch" ]; then
    flags=$(printf '%s' "$git_status" | awk '
      /^# branch\.ab /{ ahead=substr($3,2)+0; behind=substr($4,2)+0 }
      /^[12] /{
        x=substr($2,1,1); y=substr($2,2,1)
        if (x!="." && x!="?") staged=1
        if (x=="R" || y=="R") renamed=1
        if (x=="D" || y=="D") deleted=1
        if (y=="M") modified=1
      }
      /^\? /{ untracked=1 }
      END{
        s=""
        if (staged)    s=s "+"
        if (modified)  s=s "!"
        if (untracked) s=s "?"
        if (renamed)   s=s "»"
        if (deleted)   s=s "✘"
        if (ahead)     s=s "⇡" ahead
        if (behind)    s=s "⇣" behind
        print s
      }')
    # Stash is a separate ref, not part of `status` — one cheap plumbing call.
    git -C "$cwd" rev-parse --verify --quiet refs/stash >/dev/null 2>&1 && flags="${flags}\$"

    out="${out}${sep}${magenta} ${branch}${reset}"
    [ -n "$flags" ] && out="${out} ${red}${flags}${reset}"
  fi
fi

# ── model ──────────────────────────────────────────────────────────────────
# Strip the "(1M context)" suffix off the display name: the window size is
# already shown as a badge next to the context gauge, so it would be redundant
# and it is the single longest string in the payload.
model="${model% (1M context)}"
if [ -n "$model" ]; then
  out="${out}${sep}${green}✳ ${model}${reset}"
  [ -n "$fast" ] && out="${out}${yellow}⚡${reset}"
  case "$effort" in
    high|xhigh|max) out="${out}${dim}:${effort}${reset}" ;;
  esac
fi

# ── context window ─────────────────────────────────────────────────────────
# Ten-cell gauge; green under half, yellow past 50%, red past 75% — the point
# is to notice compaction coming without reading a number.
if [ "${ctx_size:-0}" != "0" ]; then
  pct=$(printf '%.0f' "${ctx_used:-0}" 2>/dev/null) || pct=0
  [ "$pct" -lt 0 ] && pct=0
  [ "$pct" -gt 100 ] && pct=100
  filled=$((pct / 10))
  bar=""
  for ((i = 1; i <= 10; i++)); do
    if ((i <= filled)); then bar="${bar}█"; else bar="${bar}░"; fi
  done
  if [ "$pct" -ge 75 ]; then c="$red"; elif [ "$pct" -ge 50 ]; then c="$yellow"; else c="$green"; fi
  if [ "$ctx_size" -ge 1000000 ]; then win="1M"; else win="$((ctx_size / 1000))k"; fi
  out="${out}${sep}${c}${bar}${reset} ${c}${pct}%${reset}${dim}/${win}${reset}"
fi

# ── elapsed ────────────────────────────────────────────────────────────────
if [ "${dur_ms:-0}" -gt 0 ] 2>/dev/null; then
  s=$((dur_ms / 1000))
  if   [ "$s" -lt 60 ];   then t="${s}s"
  elif [ "$s" -lt 3600 ]; then t="$((s / 60))m$((s % 60))s"
  else                         t="$((s / 3600))h$(((s % 3600) / 60))m"
  fi
  out="${out}${sep}${yellow}⏱ ${t}${reset}"
fi

# ── cost ───────────────────────────────────────────────────────────────────
if [ -n "$cost" ] && [ "$cost" != "0" ]; then
  out="${out}${sep}${dim}\$$(printf '%.2f' "$cost" 2>/dev/null || echo "$cost")${reset}"
fi

# ── net diff written this session ──────────────────────────────────────────
if [ "${added:-0}" != "0" ] || [ "${removed:-0}" != "0" ]; then
  out="${out}${sep}${green}+${added}${reset}${dim}/${reset}${red}-${removed}${reset}"
fi

# ── conditional tail ───────────────────────────────────────────────────────
# Only rendered when Claude Code actually emits the key, so the common case
# (an interactive session on no PR, well under the rate limit) stays quiet.
[ -n "$agent_name" ] && out="${out}${sep}${dim}⟐ ${agent_name}${reset}"
[ -n "$pr_num" ] && out="${out}${sep}${dim}PR#${pr_num}${reset}"
rl=$(printf '%.0f' "${rl5h:-0}" 2>/dev/null) || rl=0
[ "$rl" -ge 80 ] && out="${out}${sep}${red}5h ${rl}%${reset}"

printf '%s\n' "$out"
exit 0
