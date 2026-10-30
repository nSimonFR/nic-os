---
name: t3-agents
description: "Launch, follow or message a coding agent thread in T3 Code."
---

# Coding agents in T3 Code

The `t3_*` tools describe themselves; this adds what they leave to you.

- **Worktree by default.** A code change gets
  `workspaceStrategy: {type:"worktree", baseRef:"main", branch:"<type>/<slug>", startFromOrigin:true}`.
  The project root is where the user's own work lives.
- **The `message` stands alone**: the agent has none of this conversation. Goal,
  evidence verbatim (errors, paths, IDs), what "done" looks like, and its authority:
  commit, push, PR only if the user said so; otherwise "do not commit".
- **Report proof, not claims.** "Done", "tests pass", "PR opened" reach the user only
  with what backs them (`t3_thread_read` output, PR URL). Otherwise say it's unverified.
