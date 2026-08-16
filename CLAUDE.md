# nic-os

Author all commits, pushes and PRs as **nSimonFR-ai** (never nSimonFR). Commits:
`git -c user.name="nSimonFR-ai" commit …`. Pushes: `./scripts/push-ai` (takes any
`git push` args — protection rejects an approval from the last pusher, so a push
as nSimonFR deadlocks the PR). PRs: `GH_TOKEN=$(gh auth token --user
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

## Python scripts

Don't inline logic in a `.nix` string, and don't wire a loose
`${pkgs.python3}/bin/python3 ${./scripts/foo.py}`: a bare file in the store has
no importable sibling, so it can't share helpers and can't be tested.

Every system-invoked Python script lives in the **`nicos-scripts`** package
(`hosts/rpi5/scripts/lib/`, built by `pkgs/services/nicos-scripts.nix`) — 12 entry points, 387
tests. `hosts/rpi5/scripts/` and `home/scripts/` hold only shell now:

- shared helpers in `nicos_scripts/` (`logs`, `httpjson`, `state`, `secrets`, `ryot`);
- one module per script under `nicos_scripts/{connectors,papra,claude,homepage}/`
  + a `[project.scripts]` entry in `pyproject.toml`; units call
  `${pkgs.nicos-scripts}/bin/<name>`;
- nothing read from the environment at import time — a frozen `Config.from_env(env)`
  read in `main()`, and every I/O call takes an injectable seam (`opener=`, `run=`,
  `log=`, `sleep=`). `pythonImportsCheck` imports every module in the sandbox, so an
  `os.environ[...]` or a `connect()` at module level fails the build, not the timer;
- anything destructive defaults to the SAFE value (`dry_run=True`), so a Config
  built with no env cannot write;
- tests in `hosts/rpi5/scripts/lib/tests/`. They run in the package's `checkPhase`:
  `nix build .#checks.aarch64-linux.nicos-scripts` (pure Python, so
  `x86_64-linux` works too — run the checks on beast, not the Pi). In-tree:
  `nix develop` then `cd hosts/rpi5/scripts/lib && pytest`.

The exception is `hosts/rpi5/hermes/skills/*/scripts/*.py` (~1,000 lines): those are
invoked **by the model**, by the path each SKILL.md documents, so their interface
is already a hand-runnable argv rather than a systemd unit. Leave them there.

Shell scripts: prefer `writeShellApplication` (it runs shellcheck) over
`writeShellScript`.
