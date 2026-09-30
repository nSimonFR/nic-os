---
name: herdr-handoff
description: "Hand off, pick up or commit coding work in a Herdr pane."
---

# Hand a task to a Herdr agent

A **handoff** gives one coding agent one task in its own workspace, and ends with a
report you can back with tool output. `herdr-remote` holds the rules for driving Herdr
from outside a pane; they all apply here. `herdr agent`, `herdr pane` and
`herdr workspace` (run bare) print the exact syntax.

## Rules

- Every ID and name you use came from JSON Herdr returned in this task, or from the
  user. When two candidates fit, ask which one.
- Touch only the workspace you created, or the one the user named for a pickup.
- `blocked` is the user's decision: relay the question verbatim and wait for their
  answer. Send keys for it only when they have given you that answer.
- "Done", "tests pass", "committed" reach the user only with the output that shows
  it. What the agent says about itself is a claim, not evidence.

## 1. Preflight

All of these, before creating anything:

- `herdr status` shows the server running. If not, tell the user and stop; the
  server is theirs to start.
- The repo exists: `git -C <repo> rev-parse --show-toplevel`. Default `$HOME/nic-os`.
  Note `git -C <repo> status --short` and the current branch: another session's
  uncommitted work there is not the agent's to commit.
- The agent kind the user asked for (default `claude`) is in `herdr agent`'s list.
- The name you'll use, `[a-z][a-z0-9_-]{0,31}`, is free in `herdr agent list`.

## 2. Workspace and agent

```bash
r=$(herdr workspace create --cwd "<repo>" --label "<short task label>" --no-focus)
ws=$(jq -er .result.workspace.workspace_id <<<"$r")
pane=$(jq -er .result.root_pane.pane_id <<<"$r")
herdr agent start <name> --kind <kind> --pane "$pane"
```

`jq -e` fails on a missing field: stop there and show the user `$r`, rather than
carrying an empty ID forward. `agent_not_ready` means the agent stopped at a startup
dialog (Claude's folder trust in an untrusted dir): read it with
`herdr agent read <name> --source visible` and ask the user.

## 3. The prompt

The agent has none of this conversation. Write the prompt so it stands alone:

- **Goal** and the evidence the user gave (errors, log lines, paths, IDs), verbatim.
- **Repo** and **branch**: create `<type>/<slug>` from the default branch unless the
  user named one or asked to continue an existing branch.
- **Done when**: the checkable end state, e.g. the named tests pass, and which command
  proves it.
- **Authority**: exactly what the user allowed. Commit only if they said so; push and
  PR only if they said so, following the repo's `CLAUDE.md`/`AGENTS.md`. Absent
  either, the prompt says "do not commit" / "do not push or open a PR".
- **Report**: end with a short summary: root cause or result, files changed, test
  commands with their pass/fail lines, commit SHA if any.

```bash
herdr agent prompt <name> "<prompt>" --wait --timeout 600000
```

Tell the user it has started: workspace label, agent name, kind, repo. Then monitor.

## 4. Monitor

`herdr agent get <name>` gives the state; `herdr agent read <name> --source
recent-unwrapped --lines 120` shows the work.

- `working`: check again later; long tasks outlive any `--timeout`. A timeout or
  `agent_prompt_stalled` is not a lost prompt: read the pane before sending anything.
- `blocked`: read the dialog with `--source visible`, relay it, wait (see Rules).
- `idle` / `done`: the turn has finished. Go to Verify.
- `unknown`, or no agent in the pane: read it and tell the user what you see.

## 5. Pickup and resume

For work already running, or a session the user wants continued:

1. Find it in `herdr workspace list` and `herdr agent list` by the label or agent name
   the user gave. No unique match: list the candidates and ask.
2. `herdr agent get` + `herdr agent read` to learn where it stands before sending
   anything.
3. Agent live and `idle`/`done`: prompt the next step as in §3, including any new
   authority (e.g. "the user now authorises a commit").
4. Agent gone, pane at its shell: restart it in that pane with the agent's own resume
   argument (Claude: `herdr agent start <name> --kind claude --pane <pane> --
   --continue`), then read before prompting.

## 6. Verify

Check what the agent reports against the repo itself:

```bash
git -C <repo> status --short
git -C <repo> log --oneline -3
git -C <repo> show --stat HEAD      # when it claims a commit
```

Tests count when their output is in the pane (`agent read`), or when you rerun the
command it names with `herdr pane run` + `pane wait-output` in that pane. A claim
with no matching output goes back to the agent as a question, or to the user as
unverified.

## 7. Commit and PR

Only within the authority the user gave, and through the agent, so the repo's own
rules (author identity, push script, PR account) apply. After it reports, confirm the
SHA with `git log` and, for a PR, its full URL with `gh pr view <branch> --json url`.

## 8. Report

Send the user:

- workspace **label** and agent **name** (so they can open it in Herdr);
- state: finished / running / blocked on "<question>";
- the verified result: branch, commit SHA, files, test lines, PR URL, and anything the
  agent claimed that you could not confirm, marked as such.

Close the workspace only if the user asks.
