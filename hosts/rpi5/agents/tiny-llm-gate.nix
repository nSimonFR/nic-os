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
  username,
  ...
}:
let
  port = 4001;
  beastApi = "${beastOllamaUrl}/v1";
  llmModels = import ../../../shared/llm-models.nix;

  # The TypeSafe key lives in Agent Vault's root-only KEY=VAL file; the gate's
  # DynamicUser gets just that one key, in its runtime dir.
  typesafeKeyFile = "/run/tiny-llm-gate/typesafe-api-key";
  logNamespace = "tinyllmgate";
  logDir = "/var/log/journal/%m.${logNamespace}";
  typesafeKey = pkgs.writeShellApplication {
    name = "tiny-llm-gate-typesafe-key";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
    ];
    text = ''
      umask 077
      sed -n 's/^\(export \)\{0,1\}TYPESAFE_API_KEY=//p' ${config.age.secrets.agent-brokered-env.path} \
        | head -n1 | tr -d "'\"" > ${typesafeKeyFile}
      chown --reference=/run/tiny-llm-gate ${typesafeKeyFile}
    '';
  };

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
      "/run/agenix/asale-api-key"
      "/run/agenix/tiny-llm-gate-management-key"
    ];

    settings = {
      listen = "127.0.0.1:${toString port}";

      # CLIProxyAPI-compatible /v0/management: T3 Code's usage hub reads the
      # quota of acct1 and the codex provider. Tokens stay in the gate.
      management.key_file = "/run/agenix/tiny-llm-gate-management-key";

      # GET /codex/models: the picker (patterns over declared + discovered
      # models) in Codex CLI's catalog format. rpi5's
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
          discover = true;
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
          discover = true;
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
          # Its /models lists ~390 paid models (images, audio, old gens);
          # only current and future GPT generations become routable.
          discover = true;
          discover_prefix = "asale-";
          discover_only = [
            "gpt-6*"
            "gpt-7*"
            "gpt-8*"
            "gpt-9*"
          ];
        };

        # oMLX on the Mac (M3 Pro, MLX backend). Reached via the Mac's
        # `tailscale serve` HTTPS endpoint so the cert is auto-issued by
        # Tailscale. Mac may be offline (laptop); requests fail in that case,
        # same posture as codex when its OAuth token is stale.
        omlx = {
          type = "openai";
          base_url = "https://macbook-pro-appleosx-15.gate-mintaka.ts.net:8443/v1";
          api_key = "unused";
          discover = true;
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

      # Declared models only; the rest is discovered. See shared/llm-models.nix.
      models = llmModels.gate;
      inherit (llmModels) aliases;

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
      # `smart`: Jev reads each user turn and serves it on Luna, or on Sol when
      # a question fires. Thresholds are a first guess; tune from the
      # `route_signals` log field. Astra stays a manual /model pick.
      routers.smart = {
        classifier = {
          model = "jev-1.13.0";
          auth = {
            type = "bearer";
            token_file = typesafeKeyFile;
          };
        };
        tiers = [
          "gpt-6-luna"
          "gpt-6.1-sol"
        ];
        on_error = "gpt-6.1-sol";
        questions = {
          multi_step_tools = {
            instructions = "Will answering need several actions or tool calls (searching, reading files, running commands, querying services) rather than one direct reply?";
            escalate_to = "gpt-6.1-sol";
            threshold = 0.5;
          };
          deep_reasoning = {
            instructions = "Does it ask for debugging, root-cause analysis, planning, a design or a non-trivial calculation, rather than a lookup, a short fact or small talk?";
            escalate_to = "gpt-6.1-sol";
            threshold = 0.4;
          };
          high_stakes = {
            instructions = "Would a wrong or careless answer risk money, security, health, legal trouble, data loss or a production system?";
            escalate_to = "gpt-6.1-sol";
            threshold = 0.4;
          };
        };
      };

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
      RuntimeDirectory = "tiny-llm-gate";
      RuntimeDirectoryMode = "0700";
      ExecStartPre = [
        "-+${pkgs.coreutils}/bin/chown --reference=/var/lib/tiny-llm-gate /var/lib/tiny-llm-gate/codex-credentials.json"
        # "-": a missing key only disables the router's classifier (turns go to on_error).
        "-+${lib.getExe typesafeKey}"
      ];
      # Own journal, readable by ${username} (ACL below) without systemd-journal,
      # which would expose every unit's logs: `journalctl --namespace=${logNamespace}`.
      LogNamespace = logNamespace;
    };
  };

  systemd.tmpfiles.rules = [
    "d ${logDir} 2755 root systemd-journal - -"
    "A+ ${logDir} - - - - u:${username}:r-x,d:u:${username}:r-x"
  ];
  # A namespace defaults to 10% of the disk; the main journal has 500M.
  environment.etc."systemd/journald@${logNamespace}.conf".text = ''
    [Journal]
    SystemMaxUse=100M
  '';

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────────
  nic.services.tiny-llm-gate = {
    backup = [ "none" ];
    backupNote =
      "the only state is /var/lib/tiny-llm-gate/codex-credentials.json, a "
      + "self-rotating ChatGPT OAuth credential. It cannot be restored from a "
      + "backup usefully — a stale copy is already invalid — so recovery is "
      + "re-seeding it from a fresh ChatGPT refresh token. Everything else the "
      + "gate serves is config from the store.";

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
