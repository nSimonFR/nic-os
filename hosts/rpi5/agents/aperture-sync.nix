# aperture-sync — keeps the Aperture AI gateway config in step with the gate.
#
# The base config below (declared gate models + aliases, Anthropic ids, grants,
# exporters) is built at eval time. aperture-config-sync (nicos-scripts) adds
# the gate's runtime-discovered models and PUTs it at boot and every 10 min,
# only when it changed.
#
# Aperture is a Tailscale-managed proxy on the tailnet — it is NOT self-hosted.
# Auth comes from Tailscale identity (the RPi5 node is an admin via grants).
{
  config,
  pkgs,
  lib,
  apertureUrl,
  tailnetFqdn,
  unstablePkgs,
  ...
}:
let
  gateCfg = config.services.tiny-llm-gate.settings;

  # Set by tiny-llm-gate only on a router model's responses: the tier it served.
  servedModelHeader = "x-litellm-model-id";

  # Collect every model name a client might send: canonical models + aliases.
  modelNames = builtins.attrNames (gateCfg.models or { });
  aliasNames = builtins.attrNames (gateCfg.aliases or { });
  allModels = lib.unique (modelNames ++ aliasNames);

  # MCP connectors, aggregated at `<aperture>/v1/mcp` as `<id>_<tool>`. Aperture reaches
  # them over the tailnet (never loopback) and only by URL: no stdio servers.
  # Ids: letters and digits only.
  #
  # `env:NAME` secrets are filled from this unit's EnvironmentFiles by
  # aperture-config-sync, so no token enters the store.
  #
  # Aperture polls a shared-credential connector every few seconds, which would keep a
  # socket-activated backend awake for good; `send_caller_identity` turns that off
  # (measured: 0 connections in 60 s, against ~10/min for a polled one).
  publicUrl = name: config.nic.services.${name}.public.publicUrl;
  sleepy = {
    send_caller_identity = true;
  };
  bearer = var: {
    auth = {
      type = "bearer_token";
      secret = "env:${var}";
    };
  };
  connectors = lib.mapAttrs (_: c: { protocol = "mcp"; } // c) {
    notes.url = "${publicUrl "open-knowledge"}/mcp";
    wealthfolio = {
      url = "${publicUrl "wealthfolio"}/mcp";
    }
    // bearer "WEALTHFOLIO_MCP_TOKEN";
    sure = {
      url = "${publicUrl "sure-root"}/sure/mcp";
    }
    // bearer "MCP_API_TOKEN"
    // sleepy;
    airtrail = {
      url = "${publicUrl "airtrail"}/api/mcp";
    }
    // bearer "AIRTRAIL_MCP_TOKEN"
    // sleepy;
    trains = {
      url = "${publicUrl "train-prices-mcp"}/mcp";
    }
    // sleepy;
    freereps = {
      url = "${publicUrl "freereps-mcp"}/mcp";
    }
    // sleepy;
    # Assist API only: the tools act on the entities exposed to voice assistants.
    homeassistant = {
      url = "${publicUrl "home-assistant"}/api/mcp";
    }
    // bearer "HA_TOKEN";
    memos = {
      url = "${publicUrl "memos"}/mcp";
    }
    // bearer "MEMOS_TOKEN";
    rxresume = {
      url = "${publicUrl "reactive-resume"}/mcp";
      auth = {
        type = "api_key";
        secret = "env:RXRESUME_API_KEY";
        name = "x-api-key";
        "in" = "header";
      };
    }
    // sleepy;
    dawarich = {
      url = "${publicUrl "dawarich"}/api/v1/mcp";
    }
    // bearer "DAWARICH_API_KEY"
    // sleepy;
    # forgejo-mcp passes this read-only token through to Forgejo.
    forgejo = {
      url = "${publicUrl "forgejo-mcp"}/mcp";
    }
    // bearer "FORGEJO_MCP_TOKEN"
    // sleepy;
    searxng = {
      url = "${publicUrl "searxng-mcp"}/mcp";
    }
    // sleepy;
    # Stdio servers behind mcp-stdio-bridge (mcp-bridges.nix). Sending tools are
    # gated in Hermes and denied to Claude Code.
    mail = {
      url = "${publicUrl "mail-mcp"}/mcp";
    }
    // bearer "MAIL_MCP_TOKEN"
    // sleepy;
    mtg = {
      url = "${publicUrl "mtg-mcp"}/mcp";
    }
    // sleepy;
    karakeep = {
      url = "${publicUrl "karakeep-mcp"}/mcp";
    }
    // bearer "KARAKEEP_MCP_TOKEN"
    // sleepy;
    nextcloud = {
      url = "${publicUrl "nextcloud-mcp"}/mcp";
    }
    // bearer "NEXTCLOUD_MCP_TOKEN"
    // sleepy;
    immich = {
      url = "${publicUrl "immich-mcp"}/mcp";
    }
    // bearer "IMMICH_MCP_TOKEN"
    // sleepy;
    messaging = {
      url = "${publicUrl "messaging-mcp"}/mcp";
    }
    // bearer "MESSAGING_MCP_TOKEN"
    // sleepy;
    # Per-user OAuth: connect once under Connectors in the Aperture portal.
    calcom = {
      url = "https://mcp.cal.com/mcp";
      auth.type = "oauth2_dcr";
    };
    openaidocs.url = "https://developers.openai.com/mcp";
    # Linear's hosted MCP takes a personal API key as a bearer token.
    linear = {
      url = "https://mcp.linear.app/mcp";
    }
    // bearer "LINEAR_KEY";
    lineartrusk = {
      url = "https://mcp.linear.app/mcp";
    }
    // bearer "LINEAR_KEY_TRUSK";
  };
  # Tools granted per connector (default: all). A grant also filters tools/list, which
  # is what every client pays for in context: Cal.com alone serves 74 tools / 229 KB,
  # Linear 60 / 98 KB per workspace.
  linearTools = [
    "get_issue"
    "list_issues"
    "save_issue"
    "list_issue_statuses"
    "get_issue_status"
    "list_issue_labels"
    "list_comments"
    "save_comment"
    "list_cycles"
    "list_projects"
    "get_project"
    "save_project"
    "list_milestones"
    "get_milestone"
    "list_documents"
    "get_document"
    "get_attachment"
    "list_teams"
    "get_team"
    "list_users"
    "get_user"
    "get_workspace"
  ];
  connectorTools = {
    calcom = [
      "get_me"
      "get_availability"
      "get_busy_times"
      "get_bookings"
      "get_booking"
      "get_event_types"
      "get_event_type"
      "get_schedules"
      "get_default_schedule"
      "get_connected_calendars"
      "create_booking"
      "cancel_booking"
      "reschedule_booking"
    ];
    # Its token is read-only: the write tools could only fail.
    forgejo = [
      "get_*"
      "list_*"
      "search_*"
      "check_*"
      "download_*"
    ];
    linear = linearTools;
    lineartrusk = linearTools;
  };
  # Not `<id>/**`: that also opens the raw `/v1/connectors/<id>/` proxy path.
  connectorGrants = lib.concatMap (
    id:
    map (t: "${id}/tools/${t}") (connectorTools.${id} or [ "**" ])
    ++ [
      "${id}/resources/**"
      "${id}/templates/**"
    ]
  ) (builtins.attrNames connectors);
  connectorSecretFiles = with config.age.secrets; [
    wealthfolio-mcp-token.path
    sure-mcp-env.path
    airtrail-mcp-token.path
    # HA_TOKEN and DAWARICH_API_KEY, shared with Agent Vault and homepage.
    agent-brokered-env.path
  ];
  # Raw single-value secrets, read by name from $CREDENTIALS_DIRECTORY.
  connectorCredentials =
    with config.age.secrets;
    {
      MEMOS_TOKEN = memos-token.path;
      RXRESUME_API_KEY = rxresume-api-key.path;
      FORGEJO_MCP_TOKEN = forgejo-mcp-token.path;
    }
    // {
      # Generated by mcp-tokens.service (mcp-bridges.nix).
      MAIL_MCP_TOKEN = "/var/lib/mcp-tokens/mail";
      MESSAGING_MCP_TOKEN = "/var/lib/mcp-tokens/messaging";
      KARAKEEP_MCP_TOKEN = "/var/lib/mcp-tokens/karakeep";
      NEXTCLOUD_MCP_TOKEN = "/var/lib/mcp-tokens/nextcloud";
      IMMICH_MCP_TOKEN = "/var/lib/mcp-tokens/immich";
    };

  # Claude ids for the Anthropic passthrough. The base is what the claude-code
  # binary knows, which covers the short aliases it sends (`claude-haiku-4-5`)
  # that Anthropic's /v1/models omits; aperture-config-sync adds that live list
  # on top, so a new Claude model routes without a rebuild.
  anthropicModelsFile = pkgs.callPackage ../../../pkgs/agents/claude-anthropic-models.nix {
    inherit (unstablePkgs) claude-code;
  };
  anthropicModels = lib.unique (
    builtins.fromJSON (builtins.readFile anthropicModelsFile)
    # Asale routes have to be listed here too, or Aperture refuses them on /v1/messages.
    ++ builtins.attrNames (gateCfg.anthropic.routes or { })
  );

  # The inner config that Aperture manages — this gets JSON-encoded into a
  # string value inside the PUT envelope.
  apertureConfig = builtins.toJSON {
    providers = {
      rpi5-gate = {
        baseurl = "https://${tailnetFqdn}:4001";
        apikey = "unused";
        models = allModels;
        compatibility = {
          openai_chat = true;
          # Codex (wire_api = "responses") on the Mac comes through Aperture.
          openai_responses = true;
          gemini_generate_content = true;
        };
        name = "tiny-llm-gate (RPi5)";
      };
      rpi5-gate-anthropic = {
        baseurl = "https://${tailnetFqdn}:4001";
        apikey = "unused";
        models = anthropicModels;
        compatibility = {
          anthropic_messages = true;
        };
        name = "Claude Code (Anthropic passthrough)";
      };
    };
    grants = [
      {
        # The owner identity, not `*` and not `autogroup:member`.
        #
        # `*` also matched the tag:ingress relays Tailscale runs for Funnel,
        # owned by another user id — that is what we are narrowing away from.
        #
        # `autogroup:member` was the first attempt and Aperture rejects it
        # outright, with HTTP 403:
        #
        #   config would remove admin role:admin for you (nSimonFR@github)
        #
        # Aperture refuses any config that would strip the *calling* identity's
        # admin, and it does not expand autogroups when evaluating that guard —
        # so a lone `autogroup:member` reads to it as "removes your admin" even
        # though every device of ours is untagged and therefore a member. The
        # syntax itself is fine: `[ "*" "autogroup:member" ]` is accepted,
        # because `*` satisfies the guard. Only the sole-autogroup form fails.
        #
        # Naming the identity directly satisfies the guard and is *tighter*
        # than the autogroup: it covers every device authenticating as this
        # user (rpi5 included, which this module's own PUT needs) and excludes
        # the tagged relays. Verified live against the Aperture API — this form
        # PUTs 200 where `[ "autogroup:member" ]` PUTs 403.
        #
        # The inference grant below deliberately stays at `*`; narrowing it is
        # a separate change with a tailnet-wide blast radius.
        src = [ "nSimonFR@github" ];
        app = {
          "tailscale.com/cap/aperture" = [
            { role = "admin"; }
            # Opens the /metrics Prometheus endpoint (403 "read_metrics grant
            # required" without it — admin does NOT imply it). Scraped by the
            # OTel bridge so Aperture's gateway-side view (tokens, cost, request
            # durations, active users) lands in the same pipeline as Claude
            # Code's own OTLP telemetry. Floating capability object: it carries
            # no `models`, so it is not tied to model access.
            { read_metrics = true; }
            # Admins need it too, to filter by the header indexed below.
            { filterable_headers = [ servedModelHeader ]; }
            # Deny-by-default: a connector is callable only when granted.
            { connectors = connectorGrants; }
          ];
        };
      }
      {
        src = [ "*" ];
        app = {
          "tailscale.com/cap/aperture" = [
            {
              role = "user";
              models = "**";
            }
          ];
        };
      }
    ];
    connectors.servers = connectors;
    # Aperture attributes usage to the model the client asked for (`smart`), not
    # the tier a gate router served. Indexing the gate's served-model response
    # header makes Logs / Model Activity filterable by it; indexed values outlive
    # capture retention.
    database.headers.filterable = [ { name = servedModelHeader; } ];
    # Periodic export of usage logs to Storj's S3-compatible gateway.
    # access_key_id / access_secret are placeholders here; the sync script
    # rewrites them from /run/agenix/aperture-s3-export before PUTing so the
    # real credentials never enter /nix/store.
    exporters = {
      s3 = {
        bucket_name = "aperture-exports";
        region = "us-east-1";
        endpoint = "https://gateway.storjshare.io";
        access_key_id = "__FROM_AGENIX__";
        access_secret = "__FROM_AGENIX__";
      };
    };
  };

  configFile = pkgs.writeText "aperture-inner-config.json" apertureConfig;

  isEnabled = apertureUrl != "http://127.0.0.1:4001";
in
{
  systemd.services.aperture-config-sync = lib.mkIf isEnabled {
    description = "Sync Aperture config with tiny-llm-gate's model list";
    after = [
      "network-online.target"
      "tiny-llm-gate.service"
      "claude-oauth-extract.service"
      "mcp-tokens.service"
    ];
    wants = [
      "network-online.target"
      "mcp-tokens.service"
    ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ configFile ];
    environment = {
      APERTURE_URL = apertureUrl;
      APERTURE_BASE_CONFIG = "${configFile}";
      APERTURE_APPLY = "1";
      # Claude Code's OAuth token: Anthropic's /v1/models accepts it (2026-11-10).
      ANTHROPIC_TOKEN_FILE = "/run/claude-oauth/token";
      APERTURE_CONNECTOR_SECRETS = lib.concatStringsSep " " (
        [
          "WEALTHFOLIO_MCP_TOKEN"
          "MCP_API_TOKEN"
          "AIRTRAIL_MCP_TOKEN"
          "HA_TOKEN"
          "DAWARICH_API_KEY"
          "LINEAR_KEY"
          "LINEAR_KEY_TRUSK"
        ]
        ++ builtins.attrNames connectorCredentials
      );
    };
    serviceConfig = {
      Type = "oneshot";
      # STORJ_S3_ACCESS_KEY / STORJ_S3_ACCESS_SECRET for exporters.s3, then the
      # connector tokens.
      EnvironmentFile = [ "/run/agenix/aperture-s3-export" ] ++ connectorSecretFiles;
      LoadCredential = lib.mapAttrsToList (name: path: "${name}:${path}") connectorCredentials;
      ExecStart = "${pkgs.nicos-scripts}/bin/aperture-config-sync";
    };
  };

  systemd.timers.aperture-config-sync = lib.mkIf isEnabled {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "10min";
    };
  };

  # ── Dashboard tile ───────────────────────────────────────────────────────────
  #
  # `nic.externalTiles`, not `nic.services.aperture.public`: Aperture is
  # Tailscale-managed on the tailnet, so there is no unit here, no port to bind
  # and nothing for `tailscale serve` to forward — `public` would mean inventing a
  # mandatory `port` and `backend` and having tailscale-serve.nix emit a command
  # for a service this host does not run.
  #
  # It was a homepage bookmark until now, which is why the most expensive thing on
  # the box had no numbers next to it: bookmarks cannot carry a widget. The three
  # figures come from Aperture's Prometheus endpoint, which the `read_metrics`
  # grant above is what opens — see fetch_aperture for why the first two are RATES
  # (every counter Aperture exposes is all-time monotonic) and for the codex
  # zero-usage caveat that makes tokens/day an Anthropic-side figure.
  nic.externalTiles = lib.mkIf isEnabled [
    {
      # Closes row 5, "making" (Forgejo, Wakapi, Reactive Resume): this is the
      # gateway the coding agents actually run on, so it sits with what they
      # produce rather than with the two keep-the-box-safe tiles on row 6. The
      # Backend category renders after Apps regardless of these numbers — `order`
      # only sorts WITHIN a category — so this does not need to stay below
      # tiny-llm-gate's 300.
      order = 170;
      href = "${apertureUrl}/ui";
      tile = {
        name = "Aperture";
        # Not in dashboard-icons, and the bookmark's `tailscale.svg` was borrowed
        # rather than right. mdi needs no pinned CDN URL to go stale.
        icon = "mdi-chart-timeline-variant";
        category = "Apps";
        description = "LLM usage & cost (Tailscale Aperture)";
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/aperture";
          refreshInterval = 3600000;
          mappings = [
            # All three are pre-formatted text, compacted in the fetcher —
            # homepage's `number` would render nine figures wider than the tile.
            #
            # The labels are deliberately unitless. The first two values carry
            # their own unit ("65M/day" once a rate can be differenced, "913M
            # total" before that), because a rate needs two readings hours apart
            # and a "Tokens/day" label over a first-fetch placeholder would be
            # mislabelled — see fetch_aperture, which also explains why the
            # instance start time cannot stand in as a denominator.
            {
              field = "tokens";
              label = "Tokens";
              format = "text";
            }
            {
              field = "requests";
              label = "Requests";
              format = "text";
            }
            {
              field = "cached";
              label = "Cached";
              format = "text";
            }
          ];
        };
      };
    }
  ];
}
