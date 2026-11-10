# tiny-llm-gate — single Go binary replacing LiteLLM and affine-embed-proxy.
#
# Listens on :4001 (formerly LiteLLM), serves both OpenAI and Gemini
# protocols, and speaks the ChatGPT/Codex Responses API natively (native
# `type: codex` provider, v0.9.1) for proper token counts and tool_calls —
# no external codex-proxy. Target RSS: < 15 MiB.
{
  config,
  pkgs,
  lib,
  inputs,
  beastOllamaUrl,
  ...
}:
let
  port = 4001;
  beastApi = "${beastOllamaUrl}/v1";
  llmModels = import ../../../shared/llm-models.nix;

in
{
  imports = [ inputs.tiny-llm-gate.nixosModules.default ];

  services.tiny-llm-gate = {
    enable = true;
    package = inputs.tiny-llm-gate.packages.${pkgs.stdenv.hostPlatform.system}.default;

    # A /v1/messages body may be 32 MiB, held whole plus a copy when the
    # model id is rewritten.
    memoryMax = "128M";
    goMemLimit = "96MiB";
    secretPaths = [
      "/run/agenix/affine-mcp-http-token"
      "/run/agenix/asale-api-key"
      "/run/agenix/tiny-llm-gate-management-key"
    ];

    settings = {
      listen = "127.0.0.1:${toString port}";

      # CLIProxyAPI-compatible /v0/management: T3 Code's usage hub reads the
      # quota of acct1 and the codex provider. Tokens stay in the gate.
      management.key_file = "/run/agenix/tiny-llm-gate-management-key";

      # GET /codex/models: the picker list in Codex CLI's catalog format. rpi5's
      # ~/.codex/config.toml points codexproxy's model_catalog_url here, so T3
      # Code's Codex harness lists exactly these.
      codex_catalog = {
        provider = "codex";
        models = llmModels.picker;
        template = "gpt-6-luna";
      };

      providers = {
        # Ollama on beast — no auth, plain OpenAI-compat.
        ollama = {
          type = "openai";
          base_url = beastApi;
          api_key = "ollama";
        };

        # Codex: native ChatGPT/Codex Responses API. The gate POSTs directly
        # to chatgpt.com/backend-api/codex/responses, translating OpenAI chat
        # ↔ Codex Responses in-process (tool calls, streaming, token counts,
        # reasoning effort). /v1/responses on a codex hop skips translation and
        # forwards the body as-is: Codex CLI's code-mode tools (additional_tools,
        # custom `exec`) only survive that path. Authenticated by a
        # self-refreshing ChatGPT OAuth credential — the gate refreshes against auth.openai.com and persists
        # the rotated token BACK to `file`, so it must live on writable state
        # (StateDirectory below), not a read-only secret path. Seeded once from
        # a valid ChatGPT refresh token.
        codex = {
          type = "codex";
          base_url = "https://chatgpt.com/backend-api/codex";
          auth = {
            type = "oauth_chatgpt";
            file = "/var/lib/tiny-llm-gate/codex-credentials.json";
          };
        };

        # Asale's shared-capacity market, explicitly selected by model id.
        # No automatic fallback points here: spending USDT is a manual switch.
        asale = {
          type = "openai";
          base_url = "https://gw.asale.ai/v1";
          auth = {
            type = "bearer";
            token_file = "/run/agenix/asale-api-key";
          };
        };

        # oMLX on the Mac (M3 Pro, MLX backend). Reached via the Mac's
        # `tailscale serve` HTTPS endpoint so the cert is auto-issued by
        # Tailscale. Mac may be offline (laptop); requests fail in that case,
        # same posture as codex when its OAuth token is stale.
        omlx = {
          type = "openai";
          base_url = "https://macbook-pro-appleosx-15.gate-mintaka.ts.net:8443/v1";
          api_key = "unused";
        };

        # Claude, spoken natively (v0.9.4): the gate translates OpenAI chat ↔
        # Anthropic Messages in-process and authenticates via the SHARED OAuth
        # account pool defined in the `anthropic` block below (no own auth) —
        # currently a single account, see there. Lets any frontend route to
        # Claude — used as "auto"'s last-resort fallback so the assistant still
        # answers when BOTH beast (ollama) and codex are down.
        claude = {
          type = "anthropic";
          base_url = "https://api.anthropic.com";
        };
      };

      # Defined in shared/llm-models.nix.
      models = llmModels.gate;
      inherit (llmModels) aliases;

      # MCP transport bridges — replaces the 2-process supergateway chain
      # (~187 MB) with a native Go bridge (~1 MB overhead).
      #
      # AFFiNE bridge points at affine-mcp.service (DAWNCR0W) on :7021, NOT
      # AFFiNE's native MCP — the latter only exposes 3 read tools.
      mcp_bridges = {
        affine = {
          frontend = "sse";
          backend = "streamable_http";
          upstream_url = "http://127.0.0.1:7021/mcp";
          path_prefix = "/mcp/affine";
          auth = {
            type = "bearer";
            token_file = "/run/agenix/affine-mcp-http-token";
          };
        };
      };

      # Anthropic passthrough proxy — Aperture sits in front (Claude Code's
      # ANTHROPIC_BASE_URL points at Aperture), and forwards /v1/messages
      # here with its own apikey. We strip that apikey and replace it with
      # the current Claude Code access token, kept fresh by a sidecar
      # (claude-oauth-extract.service) that tracks ~/.claude/.credentials.json.
      # tiny-llm-gate re-reads the token file on every request (FileBearer
      # auth), so rotation is transparent. Aperture sees the full real
      # request and response bodies for observability.
      #
      # acct2's keep-warm sidecar (claude/claude-oauth-2.nix) was REMOVED
      # 2026-09-02 — it had been failing since 2026-08-30, so /run/claude-oauth-2
      # was empty and the "warm spare" it existed to preserve was already gone.
      # See the acct2 block below for what re-enabling now costs.
      #
      # Single account for now: acct1, the daily-driver login (team plan).
      # A one-element `accounts` list is valid — the gate only rejects `auth`
      # and `accounts` set together (internal/config/config.go), there is no
      # minimum length. With one account there is nothing to switch to, so the
      # gate's sticky-until-429 failover is inert (naive round-robin was
      # rejected as ToS-adjacent, and is not what this ever did).
      anthropic = {
        upstream = "https://api.anthropic.com";

        # Opt-in Asale models on the Anthropic surface, picked by `claude-asale`
        # (zsh/aliases.zsh). Not Haiku: Claude Code forces tool_choice for
        # WebSearch, which Asale answers with a 400.
        # Also claude-token-refresh's ping (asale-luna), so it opens no 5h window.
        routes =
          lib.mapAttrs'
            (
              tier: model:
              lib.nameValuePair "asale-${tier}" {
                upstream = "https://gw.asale.ai";
                inherit model;
                auth = {
                  type = "bearer";
                  token_file = "/run/agenix/asale-api-key";
                };
              }
            )
            {
              luna = "gpt-6-luna";
              sol = "gpt-6.1-sol";
              astra = "gpt-6-astra";
            };

        accounts = [
          {
            name = "acct1";
            auth = {
              type = "bearer";
              token_file = "/run/claude-oauth/token";
            };
          }
          # acct2 (gate-only spare, max plan — hosts/rpi5/claude/claude-oauth-2.nix)
          # DISABLED 2026-08-18: the token is valid and minutes-fresh, but the
          # ORGANIZATION this account belongs to disallows OAuth API access, so
          # every raw-passthrough request 403s with
          # `oauth_not_allowed_for_organization` — 614 × 403 and 0 × 200 on the
          # day it was caught. The gate handled that CORRECTLY: it reads 403 as
          # reason=auth_error and fails over to acct1 with a 900 s cooldown, so
          # failover was never the problem — it just had nothing to fail over
          # to. Keeping acct2 listed only bought a wasted switch + cooldown on
          # every flap, and an hourly Telegram page for an accepted state.
          #
          # Re-enabling is no longer just an uncomment: acct2's keep-warm
          # sidecar was deleted 2026-09-02 (it had been failing since 08-30, so
          # /run/claude-oauth-2/token did not exist anyway), so it also means
          # restoring hosts/rpi5/claude/claude-oauth-2.nix from git history —
          #   git log --diff-filter=D -- hosts/rpi5/claude/claude-oauth-2.nix
          #   git show <that-commit>^:hosts/rpi5/claude/claude-oauth-2.nix
          # — plus its configuration.nix import, the acct2 probe + page in
          # claude-account-healthcheck.nix, and the extract-2 wants/after on
          # this unit. And a fresh
          #   CLAUDE_CONFIG_DIR=~/.claude-secondary claude
          # login is NOT sufficient and on its own will not help: the refusal is
          # org policy, not a stale credential. acct2 can only serve the gate
          # again once that account is outside the team/enterprise org, or that
          # org enables OAuth API access. Prove it on the passthrough route
          # before re-enabling — `acct2=OK` from anthropic-account-healthcheck is
          # a weaker signal that lagged the real onset by ~3.5 h:
          #   curl -s -o /dev/null -w '%{http_code}\n' -X POST \
          #     http://127.0.0.1:4001/v1/messages -H 'x-api-key: dummy' \
          #     -H 'content-type: application/json' \
          #     -H 'anthropic-version: 2023-06-01' \
          #     -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
          # {
          #   name = "acct2";
          #   auth = {
          #     type = "bearer";
          #     token_file = "/run/claude-oauth-2/token";
          #   };
          # }
        ];
      };
    };
  };

  # Starts after claude-oauth-extract so /run/claude-oauth/token exists before
  # the Anthropic handler validates the token file at startup. (codex is now
  # native — no external codex-proxy to order after.)
  #
  # Do NOT order after affine.service / affine-mcp.service: affine.service is
  # itself ordered after tiny-llm-gate.service (AFFiNE's copilot calls into
  # this gateway), and affine-mcp.service is ordered after affine.service —
  # adding the reverse edges here forms an unbreakable systemd ordering cycle
  # that leaves all three services dead at boot. The MCP bridge routes are
  # static config: tiny-llm-gate registers them at startup and proxies
  # lazily, so upstream readiness is not a startup-time requirement.
  systemd.services.tiny-llm-gate = {
    after = [
      "network.target"
      "claude-oauth-extract.service"
    ];
    wants = [ "claude-oauth-extract.service" ];

    # Writable state for the codex provider's OAuth credentials. The native
    # oauth_chatgpt loader refreshes the ChatGPT access token and persists the
    # rotated refresh token back to codex-credentials.json, so — unlike the
    # read-only /run/claude-oauth/token — the file must live on a path the
    # DynamicUser can write. systemd owns the StateDirectory itself as the
    # runtime DynamicUser, but does NOT reliably re-chown a credentials file
    # seeded out-of-band: a root-owned seed stays root-owned and the gate gets
    # EACCES at startup. The ExecStartPre chown forces the seed file to match
    # the StateDirectory's runtime owner on each start.
    #   "+" runs it as root (the DynamicUser can't chown);
    #   "-" tolerates a missing file — on a fresh box codex simply stays
    #       disabled (non-fatal provider init) until the file is seeded, while
    #       the rest of the gate keeps serving.
    # Seed once with a valid ChatGPT refresh token; the gate owns rotation
    # writes thereafter (as the same DynamicUser, so ownership stays correct).
    serviceConfig = {
      StateDirectory = "tiny-llm-gate";
      StateDirectoryMode = "0700";
      ExecStartPre = [
        "-+${pkgs.coreutils}/bin/chown --reference=/var/lib/tiny-llm-gate /var/lib/tiny-llm-gate/codex-credentials.json"
      ];
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.tiny-llm-gate = {
    backup = [ "none" ];
    backupNote =
      "the only state is /var/lib/tiny-llm-gate/codex-credentials.json, a "
      + "self-rotating ChatGPT OAuth credential. It cannot be restored from a "
      + "backup usefully — a stale copy is already invalid — so recovery is "
      + "re-seeding it from a fresh ChatGPT refresh token. Everything else the "
      + "gate serves is config from the store.";
    # Deliberately NOT heavy: the gate is what every agent on this box reaches
    # inference through, including whatever is driving the rebuild.
    heavyUnits = [ ];

    public = {
      order = 300;
      port = 4001;
      backend = "http://127.0.0.1:4001";
      tile = {
        name = "tiny-llm-gate";
        icon = "mdi-brain";
        category = "Backend";
        description = "LLM gateway (OpenAI + Gemini + Anthropic + native Codex)";
      };
    };
  };
}
