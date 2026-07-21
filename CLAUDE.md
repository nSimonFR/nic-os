# nic-os

Author all commits and PRs as **nSimonFR-ai** (never nSimonFR). Commits:
`git -c user.name="nSimonFR-ai" commit …`. PRs: `GH_TOKEN=$(gh auth token --user
nSimonfr-ai) gh pr create …` (per-command, keeps nSimonFR active for merging).
nSimonFR owns/merges — nSimonFR-ai can't self-merge (main branch protection).

## Agent skills

New skills → **`shared/skills/<name>/SKILL.md`**: `home/claude.nix` auto-discovers
and wires them into every agent — just add the dir + commit, no `claude.nix` edit.
Don't leave skills as loose files in `~/.claude/skills/` (unmanaged). Slash command
too? add the name to `claudeSlashCommandSkills`. Claude-only (e.g. `telegram`) →
`home/claude-skills/<name>/` + an explicit `home.file` line.
