# nic-os

Author all commits and PRs as **nSimonFR-ai** (never nSimonFR). Commits:
`git -c user.name="nSimonFR-ai" commit …`. PRs: `GH_TOKEN=$(gh auth token --user
nSimonfr-ai) gh pr create …` (per-command, keeps nSimonFR active for merging).
nSimonFR owns/merges — nSimonFR-ai can't self-merge (main branch protection).

## Agent skills

New agent skills live in **`shared/skills/<name>/SKILL.md`** — `home/claude.nix`
auto-discovers the directory (`builtins.readDir`) and wires it into all four
agents (Claude Code `~/.claude/skills/`, Codex, pi, picoclaw). Adding a skill is
just adding the directory + committing; **no `claude.nix` edit**. Never leave a
skill as a loose real file under `~/.claude/skills/` — that's unmanaged and has
to be migrated back here later.

- Slash-command skills: also add the name to `claudeSlashCommandSkills` in `home/claude.nix`.
- Agent-specific skill that must NOT be shared (e.g. `telegram`, Claude-only —
  picoclaw *is* the Telegram bot) → `home/claude-skills/<name>/` with an explicit
  `home.file` line in `home/claude.nix` (see the telegram example).
- After adding, if a real dir already exists at `~/.claude/skills/<name>`,
  `rm -rf` it before the next switch so home-manager can symlink without a clobber.
