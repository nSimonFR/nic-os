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
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ configFile ];
    environment = {
      APERTURE_URL = apertureUrl;
      APERTURE_BASE_CONFIG = "${configFile}";
      APERTURE_APPLY = "1";
      # Claude Code's OAuth token: Anthropic's /v1/models accepts it (2026-11-10).
      ANTHROPIC_TOKEN_FILE = "/run/claude-oauth/token";
    };
    serviceConfig = {
      Type = "oneshot";
      # STORJ_S3_ACCESS_KEY / STORJ_S3_ACCESS_SECRET for exporters.s3.
      EnvironmentFile = "/run/agenix/aperture-s3-export";
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
