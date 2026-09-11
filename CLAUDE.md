# nic-os

Author commits, pushes and PRs as **nSimonFR-ai**, never nSimonFR — protection rejects
an approval from the last pusher, so pushing as nSimonFR deadlocks the PR. nSimonFR
owns/merges; nSimonFR-ai can't self-merge.

- commit — `git -c user.name="nSimonFR-ai" commit …`
- push — `./scripts/push-ai` (takes any `git push` args)
- PR — `GH_TOKEN=$(gh auth token --user nSimonfr-ai) gh pr create …` (per-command, keeps
  nSimonFR active for merging)

⚠️ `--user` matches gh's `hosts.yml` key — **`nSimonfr-ai`** (lowercase `fr`), not the
canonical `nSimonFR-ai`, which mints nothing while `gh pr create` hides the failure by
falling back to the active account. Check `gh auth status`; never hardcode a case —
`push-ai` resolves it case-insensitively.

## Agent skills

A skill is a **directory** — `SKILL.md` plus whatever it needs at runtime (`assets/`,
`references/`, `scripts/`); all of it ships via `shared/skill-tree.nix`.

- new skill → **`shared/skills/<name>/`**: `home/claude.nix` auto-discovers it — add the
  dir and commit, no `claude.nix` edit. Never loose files in `~/.claude/skills/`
  (unmanaged).
- slash command too? add the name to `claudeSlashCommandSkills`.
- Claude-only (e.g. `telegram`) → `home/claude-skills/<name>/`, also auto-discovered.
- **`shared/mtg-skills/`** is deliberately NOT auto-discovered: those belong only to
  Hermes' `~/.hermes/skills/mtg/` and the `claude-mtg` CLI (`home/claude-mtg.nix`).
  Enforced — `hermes-skill-promote`'s exclusion set comes from `hermes.nix`'s
  `skillLineages`.

## Python scripts

Never inline logic in a `.nix` string, and never wire a loose
`${pkgs.python3}/bin/python3 ${./scripts/foo.py}` — a bare store file has no importable
sibling, so it can't share helpers or be tested.

Every system-invoked Python script lives in the **`nicos-scripts`** package
(`hosts/rpi5/scripts/lib/`, built by `pkgs/services/nicos-scripts.nix`);
`hosts/rpi5/scripts/` and `home/scripts/` hold only shell.

- shared helpers in `nicos_scripts/` (`logs`, `httpjson`, `state`, `secrets`, `pg`, `ryot`);
- one module per script under `nicos_scripts/<area>/` + a `[project.scripts]` entry in
  `pyproject.toml`; units call `${pkgs.nicos-scripts}/bin/<name>`;
- no env read at import — freeze `Config.from_env(env)` in `main()`, and give every I/O
  call an injectable seam (`opener=`, `run=`, `log=`, `sleep=`). `pythonImportsCheck`
  catches a module-level `os.environ[...]`/`connect()` at build time, not in the timer;
- destructive defaults to the SAFE value (`dry_run=True`) — a Config built with no env
  cannot write;
- tests in `tests/`, run in `checkPhase`: `nix build .#checks.aarch64-linux.nicos-scripts`.
  In-tree: `nix develop`, then `cd hosts/rpi5/scripts/lib && pytest`.

Exception: `hosts/rpi5/hermes/skills/*/scripts/*.py` are invoked **by the model** at the
path each SKILL.md documents, so their interface is already a hand-runnable argv. Leave
them there.

Shell: prefer `writeShellApplication` (runs shellcheck) over `writeShellScript`.
