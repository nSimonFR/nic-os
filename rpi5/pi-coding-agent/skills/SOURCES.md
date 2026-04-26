# Vendored skill sources

Anthropic-authored Agent Skills, copied wholesale (with `LICENSE.txt` and bundled
`scripts/` / `references/` / `templates/`) into this directory. Pi reads them
straight from `~/.pi/agent/skills/<name>/SKILL.md`.

To bump: re-clone upstream at the new commit, `cp -r` the chosen subdirs back in,
update the commit hashes below.

## Sources

| Skill | Upstream repo | Path | Pinned commit |
|---|---|---|---|
| algorithmic-art | anthropics/skills | `skills/algorithmic-art` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| brand-guidelines | anthropics/skills | `skills/brand-guidelines` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| canvas-design | anthropics/skills | `skills/canvas-design` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| claude-api | anthropics/skills | `skills/claude-api` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| doc-coauthoring | anthropics/skills | `skills/doc-coauthoring` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| docx | anthropics/skills | `skills/docx` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| frontend-design | anthropics/skills | `skills/frontend-design` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| internal-comms | anthropics/skills | `skills/internal-comms` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| mcp-builder | anthropics/skills | `skills/mcp-builder` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| pdf | anthropics/skills | `skills/pdf` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| pptx | anthropics/skills | `skills/pptx` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| skill-creator | anthropics/skills | `skills/skill-creator` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| slack-gif-creator | anthropics/skills | `skills/slack-gif-creator` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| theme-factory | anthropics/skills | `skills/theme-factory` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| webapp-testing | anthropics/skills | `skills/webapp-testing` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| web-artifacts-builder | anthropics/skills | `skills/web-artifacts-builder` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| xlsx | anthropics/skills | `skills/xlsx` | 5128e1865d670f5d6c9cef000e6dfc4e951fb5b9 |
| claude-md-improver | anthropics/claude-plugins-official | `plugins/claude-md-management/skills/claude-md-improver` | 020446a4294f09d9c32e60bff0c4ae8fb39205cb |
| writing-rules | anthropics/claude-plugins-official | `plugins/hookify/skills/writing-rules` | 020446a4294f09d9c32e60bff0c4ae8fb39205cb |
| build-mcp-app | anthropics/claude-plugins-official | `plugins/mcp-server-dev/skills/build-mcp-app` | 020446a4294f09d9c32e60bff0c4ae8fb39205cb |
| build-mcpb | anthropics/claude-plugins-official | `plugins/mcp-server-dev/skills/build-mcpb` | 020446a4294f09d9c32e60bff0c4ae8fb39205cb |
| build-mcp-server | anthropics/claude-plugins-official | `plugins/mcp-server-dev/skills/build-mcp-server` | 020446a4294f09d9c32e60bff0c4ae8fb39205cb |
| session-report | anthropics/claude-plugins-official | `plugins/session-report/skills/session-report` | 020446a4294f09d9c32e60bff0c4ae8fb39205cb |

## Skipped from the upstream repos (and why)

- `code-review`, `code-simplifier` (claude-plugins-official) — overlap with the
  user's existing built-in `/review` and `/simplify` skills.
- `claude-code-setup`, `plugin-dev`, `example-plugin` — Claude-Code-runtime-specific.
- All `*-lsp/` plugins — MCP-based LSP integrations; user opted out of MCP wiring.
- `commit-commands`, `pr-review-toolkit`, `feature-dev`, `agent-sdk-dev`,
  `ralph-loop`, `hookify` (top-level), `security-guidance`,
  `explanatory-output-style`, `learning-output-style`, `math-olympiad` — these
  are Claude Code *plugins* (commands/agents/hooks layout), not Skills. Pi's
  skill loader doesn't read that format.

## Caveat

A few skills reference Claude-Code-specific tool names in their `tools:` /
`allowed-tools:` frontmatter (e.g. `Task`, `NotebookEdit`). Pi ignores unknown
tool names without crashing — the skill body still loads, it just can't invoke
those tools.
