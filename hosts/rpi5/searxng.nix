# hosts/rpi5/searxng.nix
#
# SearXNG — privacy-respecting metasearch engine (https://docs.searxng.org/).
# It holds no index of its own: every query is fanned out to upstream engines
# (DuckDuckGo, Wikipedia, …) from *this* box and the results merged, so the
# engines see the Pi's IP and never a browser cookie.
#
# nixpkgs already ships the module (services.searx) and the package, so unlike
# freereps/showmycards there is nothing to package here — this file is the
# rpi5-specific half: which server to run, when it may sleep, and how it is
# reached.
#
# ── Flask's built-in server, not uWSGI ───────────────────────────────────────
# `configureUwsgi` is left off, so the unit runs `searxng-run` — Flask's
# threaded dev server. Upstream reserves uWSGI for "public or large instances"
# and calls it unnecessary for LAN-only use, which is what this is: one user,
# on the tailnet, behind Tailscale Serve. uWSGI would also cost an emperor
# process plus a vassal for the same single worker, and the module's uwsgi
# instance is a host-wide singleton — a second consumer would have to negotiate
# with this one.
#
# Upstream warns that "the built-in HTTP server logs all queries by default",
# which would matter here — werkzeug writes an access line per request, and a
# GET (a bookmarked `?q=`, or the JSON API below) carries the query in the URL.
# It does not apply to this configuration: searx/__init__.py pins the werkzeug
# logger to WARNING unless `general.debug` is set, and debug stays false below,
# so the INFO access lines are dropped before journald sees them. Verified by
# searching for a marker string and grepping the unit's journal for it — zero
# hits. `general.debug` is therefore load-bearing, not decoration: turning it on
# swaps in _logging_config_debug() and starts recording every query.
#
# ── No limiter, therefore no valkey ──────────────────────────────────────────
# `redisCreateLocally` would start a *second* Redis server (the box already runs
# one) purely so the bot-detection limiter has somewhere to keep counters. The
# limiter exists to stop strangers scraping a public instance; nothing here is
# public — Tailscale Serve publishes on the tailnet only and this port is not
# funnelled — so the counters would guard against a threat that cannot reach
# the port. `server.limiter` stays false and no valkey is configured.
{
  config,
  pkgs,
  lib,
  tailnetFqdn,
  ...
}:
let
  internalPort = 13349; # Flask bind (real backend, localhost only)
  proxyPort = 8380; # socket-activate proxy listen; Tailscale Serve → here
  # External tailnet HTTPS port: declared once in nic.services.searxng.public
  # below, which also derives publicUrl for server.base_url.
in
{
  services.searx = {
    enable = true;

    # Only read when configureNginx is set, which it is not — nginx here is the
    # 443 path-mux (front-proxy.nix) and SearXNG is not behind it. Set anyway so
    # the option carries the right answer if that ever changes.
    domain = tailnetFqdn;

    # SEARXNG_SECRET. Signs the preferences cookie and the link token, so it
    # must not be the store-readable "ultrasecretkey" the upstream defaults
    # carry. envsubst expands the $SEARXNG_SECRET below from this file when
    # searx-init writes /run/searx/settings.yml (mode 0600, tmpfs).
    environmentFile = "/run/agenix/searxng-env";

    settings = {
      # Merge these over upstream's settings.yml rather than replacing it —
      # otherwise every engine definition would have to be restated here. The
      # attrset form means the same thing as `true` (settings_loader's
      # is_use_default_settings accepts either) and additionally drops three
      # engines from the instance outright.
      #
      # Dropped, not disabled, because `disabled` is only "don't query it by
      # default": SearXNG still builds a processor for the engine and still runs
      # its init() at import. These three can never succeed, so that init is
      # pure cold-start cost and a traceback in the journal every time —
      #
      #   wikidata  init() probes query.wikidata.org/sparql, which answers 403
      #             to this instance. Plain `wikipedia` is a different engine
      #             and stays.
      #   ahmia     onion engines. Both need `outgoing.using_tor_proxy` and a
      #   torch     Tor daemon; there is none on this box, so both fail to load.
      use_default_settings.engines.remove = [
        "wikidata"
        "ahmia"
        "torch"
      ];

      general = {
        instance_name = "nic-os search";
        # Restating upstream's default, because it is what keeps queries out of
        # the journal — see the logging note in the header. Spelled out so a
        # future "let's see what's going on" flip is made deliberately.
        debug = false;
        # In-memory histograms per engine, exposed at /stats. They are wiped by
        # every idle-stop below — a 10-minute window of timings nobody reads —
        # so this only buys per-request bookkeeping. Off.
        enable_metrics = false;
      };

      server = {
        port = internalPort;
        # Loopback only: Tailscale Serve reaches this through the proxy on
        # 127.0.0.1, and a wildcard bind would expose it on the LAN too.
        bind_address = "127.0.0.1";
        # Absolute links (opensearch.xml, the "search on" URLs) are built from
        # this, so it has to be the Serve origin and not the loopback bind.
        base_url = "${config.nic.services.searxng.public.publicUrl}/";
        secret_key = "$SEARXNG_SECRET";
      };

      search = {
        # html is upstream's default; json makes the same instance a search API
        # for the agents on this box, which is half the point of running it
        # here — one `curl 'http://127.0.0.1:8380/search?q=…&format=json'`
        # instead of a per-agent API key at some SaaS. It also wakes the
        # service like any other request.
        formats = [
          "html"
          "json"
        ];
        # Left off deliberately: autocomplete fires an upstream request per
        # keystroke, which on a service that sleeps every 10 minutes means a
        # cold start triggered by typing rather than by searching.
        autocomplete = "";
      };

      # ── Which engines actually answer this box ───────────────────────────
      # Upstream's default general set is google, duckduckgo, startpage and
      # brave plus a handful of answer-only engines (wikipedia, wikidata,
      # currency, the dictionaries). Every one of those four refuses this
      # instance, measured 2026-09-01 from the box's own residential SFR IP in
      # Paris — not a datacenter range, so this is the engines objecting to
      # SearXNG's request shape rather than to where it sits:
      #
      #   google      access denied      duckduckgo  CAPTCHA (lite/ returns 202)
      #   startpage   CAPTCHA            brave       429 too many requests
      #
      # Left as shipped, the very first query on this instance returns zero
      # results and four error toasts, because nothing else in the default set
      # searches the open web. So the defaults are corrected in both
      # directions, and the correction is a measurement rather than a taste:
      # each name below was queried on its own through /search?format=json and
      # kept only if it came back with usable results.
      #
      # Also tried and NOT kept: mojeek and presearch (CAPTCHA / access
      # denied), qwant (access denied), yahoo, stract, right dao, yep, ask
      # (HTTP errors), yacy and mwmbl (timeouts, mwmbl crashed one worker),
      # crowdview (forum-only, empty on ordinary queries), encyclosearch
      # (encyclopedia-only, so it dilutes a general query).
      #
      # None of this is permanent — engine blocks come and go. Re-testing one
      # is flipping its `disabled` here, or just ticking it for one browser
      # under Preferences → Engines, which needs no rebuild at all.
      engines = [
        # Off: measured refusals. Enabled they cost a request timeout and an
        # error banner on every single search.
        { name = "google"; disabled = true; }
        { name = "duckduckgo"; disabled = true; }
        { name = "startpage"; disabled = true; }
        { name = "brave"; disabled = true; }

        # On: the ones that answered. bing carries the result set; fynd and
        # seznam are independent enough to shuffle the ranking rather than
        # echo it.
        { name = "bing"; disabled = false; }
        { name = "fynd"; disabled = false; }
        { name = "seznam"; disabled = false; }
        # The only other engine here with a real general index of its own.
        # Queries reach it from this box, never from the browser — no cookie,
        # no client IP — which is the whole reason a metasearch proxy can use
        # an engine one would not visit directly.
        { name = "yandex"; disabled = false; }
        # Small-web long tail: both index the sort of hand-written pages the
        # big crawlers rank into oblivion, both are fast, and neither pretends
        # to be a general engine.
        { name = "wiby"; disabled = false; }
        { name = "searchmysite"; disabled = false; }
      ];
    };
  };

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ────────
  # Proxy on :8380 lazily starts searx.service on first connection and stops it
  # after idleSec — ~0 RAM at rest, 14-134 MB awake. Search is bursty by
  # nature (a few minutes of queries, then hours of nothing), so this is close
  # to the ideal shape for it.
  #
  # `searx-init` — the oneshot that renders settings.yml — is NOT stopped with
  # it: it is RemainAfterExit with RuntimeDirectoryPreserve=yes, so /run/searx
  # survives the sleep and only one envsubst run happens per boot.
  services.socketActivate.searxng = {
    enable = true;
    realUnit = "searx.service";
    listen = [ "127.0.0.1:${toString proxyPort}" ];
    backend = "127.0.0.1:${toString internalPort}";
    idleSec = 600;
    readyProbe = {
      # The one route that needs no template, no engine and no cookie — it
      # returns a literal "OK" (searx/webapp.py `health`). "/" would render the
      # full index page and depend on the theme assets.
      url = "http://127.0.0.1:${toString internalPort}/healthz";
      expectStatus = 200;
      # Importing searx pulls in flask, lxml, babel and ~200 engine modules and
      # then parses a 67 KB settings.yml before Flask binds. Measured at ~10 s
      # cold on the Pi; 90 s is the margin for a page-cache-cold first start.
      timeoutSec = 90;
    };
  };

  systemd.services.searx.serviceConfig = {
    # SearXNG keeps an expiring SQLite cache (searx/cache.py) whose default path
    # is $TMPDIR/sxng_cache_*.db — engine tokens, the tracker-pattern list, and
    # other things it would otherwise re-fetch from the network. Under
    # PrivateTmp that file dies with every idle-stop, so a service that sleeps
    # hourly would re-fetch hourly. Point TMPDIR at a StateDirectory-style cache
    # dir instead and the cache outlives the sleep.
    CacheDirectory = "searx";
    CacheDirectoryMode = "0700";
    Environment = [ "TMPDIR=/var/cache/searx" ];

    # A metasearch engine is, by construction, a process that fetches attacker-
    # influenced URLs and parses the HTML that comes back — worth boxing in. It
    # reaches the network and its own cache dir, and nothing else.
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      # Not optional despite this process only speaking TCP: glibc's NSS talks
      # to nscd over a Unix socket, so dropping it turns name resolution into a
      # startup failure that looks nothing like a sandbox problem — and every
      # single query here is a DNS lookup.
      "AF_UNIX"
    ];

    # No MemoryHigh/MemoryMax. This Pi boots with cgroup_disable=memory
    # (/proc/cmdline, injected by the RPi5 firmware via /chosen/bootargs), so
    # the memory controller is absent from cgroup.controllers and systemd
    # accepts both settings and silently ignores them — same reason
    # epicgames-freegames caps the Node heap in-process instead. Writing them
    # here would read as a guard where there is none; earlyoom
    # (configuration.nix) is the actual backstop.
    #
    # Measured instead: ~14 MB freshly started, ~134 MB with five concurrent
    # searches in flight. Peak tracks how many engines answer at once — each
    # response is parsed with lxml — and the engine list below is short, so it
    # stays well inside what the box can absorb.
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ─────────
  nic.services.searxng = {
    backup = [ "none" ];
    backupNote =
      "stateless — settings come from the Nix store, /var/cache/searx holds only "
      + "re-fetchable engine data, and user preferences live in the visitor's "
      + "own cookie. There is no server-side account, history or index.";

    heavyUnits = [ "searx.service" ];
    # Lightest of the lot and always socket-asleep anyway, so it sheds last:
    # after homepage (160).
    heavyPriority = 165;

    public = {
      order = 195; # in Apps, after ShowMyCards (190)
      port = 3970;
      backend = "http://127.0.0.1:${toString proxyPort}";
      # NEVER: all three funnel-capable ports are allocated, and a public
      # metasearch instance is an open proxy that upstream engines will rate-
      # limit or CAPTCHA this box's IP for.
      funnel = false;

      # No tile: routed, but it renders nothing on the dashboard. homepage's
      # search bar (homepage.nix `widgets.search`) is pointed straight at this
      # instance, so the entry point is the box you type into rather than a card
      # you click to reach a box you type into. A tile would only duplicate it.
      #
      # `order` still matters with no tile — it also sequences the serve
      # commands in tailscale-serve.nix, and is asserted unique.
      tile = null;
    };
  };
}
