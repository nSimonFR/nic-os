# nic-os

Author all commits and PRs as **nSimonFR-ai** (never nSimonFR). Commits:
`git -c user.name="nSimonFR-ai" commit …`. PRs: `GH_TOKEN=$(gh auth token --user
nSimonfr-ai) gh pr create …` (per-command, keeps nSimonFR active for merging).
nSimonFR owns/merges — nSimonFR-ai can't self-merge (main branch protection).

## Agent skills

A skill is a **directory** — `SKILL.md` plus whatever it needs at runtime
(`assets/`, `references/`, `scripts/`); all of it ships, via
`shared/skill-tree.nix`.

New skills → **`shared/skills/<name>/`**: `home/claude.nix` auto-discovers and
wires them into every agent — just add the dir + commit, no `claude.nix` edit.
Don't leave skills as loose files in `~/.claude/skills/` (unmanaged). Slash command
too? add the name to `claudeSlashCommandSkills`. Claude-only (e.g. `telegram`) →
`home/claude-skills/<name>/`, also auto-discovered (no `home.file` line needed).

**`shared/mtg-skills/`** is deliberately outside that auto-discovery: those
skills belong only to the two MTG surfaces (Hermes' `~/.hermes/skills/mtg/` and
the `claude-mtg` CLI in `home/claude-mtg.nix`), not to every agent. Enforced, not
coincidental: `hermes-skill-promote`'s exclusion set comes from `hermes.nix`'s
`skillLineages`.
