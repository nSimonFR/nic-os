# Tools & Conventions

## System

- OS: NixOS | Shell: zsh | Package Manager: Nix (flakes)
- Config source: `~/nic-os/` → deploy by merging a PR to `main` (CI + Cachix agent). You have no sudo
- **Rule:** Never edit /nix/store symlinks or /etc/ directly. Use .nix files + rebuild.
- Secrets: agenix — `/run/agenix/` (read-only, system-managed). You hold no API
  key: every one is a placeholder named after it (`__tavily_api_key__`,
  `__ha_token__`, `__immich_api_key__`…), and Agent Vault (`HTTPS_PROXY`/`HTTP_PROXY`)
  swaps in the real value for that service only. Use them as-is, even written
  literally when your terminal strips the env var. Local services go through it
  too, under aliases: `ha.home.arpa:8123`, `dawarich.home.arpa:13900`,
  `ryot.home.arpa:13350`, `immich.home.arpa:2283`. GitHub (`git`, `gh`) acts as
  nSimonFR-ai the same way. Never unset `HTTPS_PROXY`/`HTTP_PROXY`/`SSL_CERT_FILE`.
  A 401 means the broker, not the key: check `journalctl -u agent-vault-bootstrap`.
- **Web search = the native `web_search` / `web_extract` tools** (Tavily). Your
  terminal never sees `TAVILY_API_KEY` or `GEMINI_API_KEY`: Hermes strips its own
  provider keys from subprocesses, so don't script Tavily from the shell.

## Hermes Architecture

Hermes is the sole agent on this host (it succeeded PicoClaw, retired 2026-07).
It runs as an `nsimon` **user** systemd unit polling the Telegram bot; there is
no HTTP gateway to curl.

- **Config source:** `~/nic-os/hosts/rpi5/hermes/hermes.nix` — a home-manager module.
  Everything below (model, skills, documents, cron workspace, MCP servers) is
  generated from it.
- **Runtime home (`$HERMES_HOME`):** `~/.hermes/`
  - `config.yaml` — Nix-generated, **overwritten on every restart**
  - `.env` — bot token + sender allowlist, written 0600 at start from
    `/run/agenix/telegram-bot-token`
  - `skills/` — deployed skills (see below)
  - `*.md` — these persona documents
  - `workspace/` — cron scripts (tracked) + live state (kanban.db, sandboxes)
  - `cron/jobs.json` — cron jobs; **runtime state, not Nix-managed**
- **Skills** deploy into `~/.hermes/skills/` from three sources:
  - `~/nic-os/shared/skills/<name>/SKILL.md` — shared across every agent
  - `~/nic-os/hosts/rpi5/hermes/skills/<name>/SKILL.md` — Hermes-local
  - `~/nic-os/shared/mtg-skills/` → `~/.hermes/skills/mtg/` (Hermes MTG skills)
- **Models / routing:** configured inline in `hermes.nix`. Hermes points at
  **Aperture** (`http://ai.gate-mintaka.ts.net/v1`), which forwards to
  tiny-llm-gate so usage and cost land on the observability dashboard. Current
  model: `gpt-5.6` by default; `/model` also offers `gpt-6` (GPT-6 Astra) for a
  hard task, session-scoped. **No Anthropic fallback** — deliberately; see the long
  note in `hermes.nix`, do not re-add one.

## Config Changes

| Change | Edit | Then |
|--------|------|------|
| Model, routing, MCP servers, memory | `~/nic-os/hosts/rpi5/hermes/hermes.nix` | Rebuild |
| Shared skill content | `~/nic-os/shared/skills/<name>/SKILL.md` | Rebuild |
| Hermes-only skill content | `~/nic-os/hosts/rpi5/hermes/skills/<name>/SKILL.md` | Rebuild |
| Persona / these docs | `~/nic-os/hosts/rpi5/hermes/documents/` | Rebuild |
| Cron helper scripts | `~/nic-os/hosts/rpi5/hermes/workspace/` | Rebuild |
| API keys, tokens | Re-encrypt `hosts/rpi5/secrets/agent-brokered-env.age` + a service in `agent-vault.nix` | Rebuild |
| Cron jobs themselves | `~/.hermes/cron/jobs.json` (runtime) | No rebuild |

**Deploy caveat:** the rsyncs in `hermes.nix` omit `--delete`, so a file removed
from the repo lingers in `~/.hermes/` until cleaned by hand.

**Cron caveat:** pin `model` and `provider` per job in `jobs.json` — an
unpinned job is silently skipped when the configured model drifts. This applies
only to LLM-driven jobs; a `no_agent` job never consults a model.

**Cron scripts:** the recurring jobs run `no_agent` against
`~/.hermes/scripts/*.sh`, seeded from `cronScripts` in `hermes.nix` — zero tokens,
so no plan-cap 429. Non-empty stdout is sent verbatim, empty stdout is silent, a
non-zero exit is sent as an alert; the ones that send their own message redirect
stdout to `/dev/null`.

## Sending a message

`telegram-send [-c CHAT] [-m rich|html|markdown|plain] [-p PHOTO] [TEXT]`, stdin
when TEXT is omitted. It owns the token lookup, urlencoding and link-preview
suppression — do not hand-roll `curl https://api.telegram.org/...`.

`-m rich` posts `sendRichMessage` with `rich_message={"markdown": …}`; the same
parameter also accepts `{"html": …, "skip_entity_detection": false}`. SOUL.md
says when to reach for it. Markdown maps to blocks like this:

| Markdown | Block |
|---|---|
| `#` / `##` | `heading` + `size` |
| `- item` / `1. item` | `list` |
| `- [ ]` / `- [x]` | `list` item with `has_checkbox` / `is_checked` |
| `[t](u)` | inline `url` run |
| `> quote` | `blockquote` |
| ```` ``` ```` | `pre` |
| `\|a\|b\|` | `table` (`is_header`, `align`) |
| `---` | `divider` |
| `<details><summary>s</summary>…` | `details` |

Two that silently do not work: `>!` is not an expandable blockquote (the `!`
lands in the text), and `is_expandable` on a `blockquote` is dropped. Use
`<details>`.

The API echoes the parsed `rich_message.blocks` back in its response, so check
those rather than trusting the Markdown — a degraded send looks identical to a
good one otherwise.

## Useful Commands

- `systemctl --user status hermes` — check health
- `journalctl --user -u hermes -n 50 --no-pager` — logs
- `systemctl --user restart hermes` — reload config.yaml + redeploy skills/docs
- `cat ~/.hermes/config.yaml` — inspect generated config
- `cat ~/.hermes/cron/ticker_last_success` — confirm the cron ticker is alive
- `systemctl --user list-timers` — hermes-skill-promote (hourly)
- `hermes cron list` — the scheduled jobs; `--script`/`no_agent` marks the
  token-free ones. Weekly tabletop events is job `92715566fb3e`, not a systemd
  timer (the duplicate timer was removed — both fired Mon 09:00 against one
  SQLite state and raced over the diff)
