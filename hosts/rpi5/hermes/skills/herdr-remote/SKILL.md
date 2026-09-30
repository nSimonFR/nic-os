---
name: herdr-remote
description: "Start and drive coding agents (Claude, Codex, …) or commands in Herdr panes from outside Herdr — e.g. from Telegram. Use when the user asks to open, launch, prompt, read or close something in Herdr and HERDR_ENV is not 1. Supersedes the `herdr` skill's HERDR_ENV check for this case."
---

# Herdr, driven from outside

You (Hermes) do not run in a Herdr pane, so `HERDR_ENV` is unset and the `herdr` skill
tells you to stop. That check exists because an outside caller has no pane of its own
and `--current` / the focused pane would point at the user's work. The rules below
remove that risk, so you **may** use `herdr` here. Keep the `herdr` skill for the
command reference (`herdr --help`, `herdr agent`, `herdr pane`).

The `herdr` on PATH reaches the user's server at `~/.config/herdr/herdr.sock`. Check it
is up with `herdr status`; if not, say so and stop — never start, stop or restart the
server.

## Rules

- **Never** use `--current`, and never omit a target: there is no calling pane, and a
  default lands on whatever the user has focused.
- Work in a workspace **you created**, with `--no-focus`, so the user's screen does not
  move. Touch another pane or agent only if the user named it.
- Take every ID from the JSON a command returns; don't guess `w1:p1`.
- Close only what you created, and only when the user asked or the task is done and
  they won't want to look at it.
- An agent at `blocked` is asking for approval: read it and relay the question to the
  user. Do not answer it yourself.

## Start an agent

```bash
r=$(herdr workspace create --cwd "$HOME/nic-os" --label "<short task label>" --no-focus)
ws=$(jq -r .result.workspace.workspace_id <<<"$r")
pane=$(jq -r .result.root_pane.pane_id <<<"$r")
herdr agent start <name> --kind claude --pane "$pane"
herdr agent prompt <name> "<the task>" --wait --timeout 600000
herdr agent read <name> --source recent-unwrapped --lines 120
```

- `--cwd`: the repo the task is about; default `$HOME/nic-os`. Claude stops at a
  "trust this folder?" dialog (`agent_not_ready`) in any dir not yet trusted — `$HOME`
  included. Read it with `herdr agent read <name> --source visible` and ask the user.
- `<name>`: unique, `[a-z][a-z0-9_-]{0,31}`; check `herdr agent list` first.
- `--kind`: what the user asked for; `claude` otherwise. `herdr agent` lists kinds.
- A second agent for the same task: `herdr pane split "$pane" --direction right --no-focus`,
  then start it in `.result.pane.pane_id`.

A long task will outlive `--timeout`. Tell the user it is running and in which workspace
(its label), then check later with `herdr agent get <name>`. `idle` or `done` means it
has finished.

A timeout does not mean the prompt was lost. Read the pane before you send it again.

## Run a plain command

```bash
herdr pane run "$pane" "<command>"
herdr pane wait-output "$pane" --match "<text>" --timeout 120000
herdr pane read "$pane" --source recent-unwrapped --lines 120
```

`pane read` prints plain text, not JSON.

## Report back

Send the user the workspace label and agent name, so they can open it in Herdr on their
phone or laptop and pick up where it is.
