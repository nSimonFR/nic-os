---
name: t3-agents
description: "Launch, follow or message a coding agent thread in T3 Code."
---

# Coding agents in T3 Code

The `t3` MCP server is the T3 Code server on rpi5. You are an outside client there,
not a thread: launch top-level threads with `t3_thread_launch`. `delegate_task` and
`task_*` need a parent thread, so they are not yours.

Each write call (launch, send, interrupt) waits for the user's approval in Telegram.
A refusal is final: do not retry it.

## Launch

1. `t3_project_list` → `projectId`. Match the repo the user named; if two fit, ask.
2. `t3_thread_launch` with `projectId`, a short `title`, and the task in `message`.
   For a code change, give it its own worktree:
   `workspaceStrategy: {type:"worktree", baseRef:"main", branch:"<type>/<slug>", startFromOrigin:true}`.
   Omitting it runs in the project root, where the user's own work lives.
3. Send the user the `link` it returns, verbatim.

The agent has none of this conversation. The `message` stands alone: goal, evidence
verbatim (errors, paths, IDs), what "done" looks like, and what it may do: commit,
push, PR only if the user said so.

## Follow

- `t3_thread_wait` on the `threadId` until the turn ends; a timeout is not a failure.
- `t3_thread_read` for the result. Report what the agent did with its proof (PR URL,
  test output). What it says about itself is a claim; say so when nothing backs it.
- A question from the agent is the user's: relay it verbatim, answer it with
  `t3_thread_send` only once they have.

Existing threads: `t3_thread_list` / `t3_thread_search`, then read before sending.

## When the tools are missing

The login lasts 30 days. If no `t3_*` tool exists, tell the user to run
`hermes mcp login t3` on rpi5; do not try another route.
