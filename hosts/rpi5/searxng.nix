# hosts/rpi5/searxng.nix
#
# SearXNG — metasearch (https://docs.searxng.org/). Holds no index: it fans a
# query out to upstream engines from this box and merges the results, so the
# engines see the Pi and never a browser cookie. Module and package both come
# from nixpkgs; this file is only the rpi5-specific half.
#
# Flask's built-in server, not uWSGI: upstream reserves uWSGI for public or
# large instances, and the module's uwsgi instance is a host-wide singleton a
# second consumer would have to negotiate with. Upstream's "the built-in server
# logs all queries" warning does not apply — searx/__init__.py pins the werkzeug
# logger to WARNING unless `general.debug` is set (verified: searched a marker
# string, grepped the journal, zero hits).
{ config, tailnetFqdn, ... }:
let
  internalPort = 13349; # Flask bind, loopback only
  proxyPort = 8380; # socket-activate proxy; Tailscale Serve → here
in
{
  services.searx = {
    enable = true;
    domain = tailnetFqdn; # only read under configureNginx, which is off

    # SEARXNG_SECRET, envsubst'd into /run/searx/settings.yml by searx-init.
    # Upstream's default is the store-readable literal "ultrasecretkey".
    environmentFile = "/run/agenix/searxng-env";

    settings = {
      # Merge over upstream's settings.yml. The attrset form means the same as
      # `true`, plus it drops three engines outright — `disabled` would not:
      # SearXNG still runs a disabled engine's init() at import, and all three
      # fail there (wikidata's SPARQL endpoint 403s; ahmia and torch want a Tor
      # proxy this box does not have). Plain `wikipedia` is unaffected.
      use_default_settings.engines.remove = [
        "wikidata"
        "ahmia"
        "torch"
      ];

      general = {
        instance_name = "nic-os search";
        debug = false; # load-bearing: this is what keeps queries out of the journal
        enable_metrics = false; # in-memory only, wiped by every restart
      };

      # Preferences live here, not in a cookie: SearXNG has no accounts, so the
      # preferences page's 21 cookies are per-browser and per-device, share a
      # port-blind jar with every other app on this host, and carry no SameSite
      # (a POST search from the URL bar can drop them). Server-side they hold
      # everywhere, and a cookie is only needed to deviate.
      server = {
        port = internalPort;
        bind_address = "127.0.0.1";
        # opensearch.xml and other absolute links are built from this, so it has
        # to be the Serve origin rather than the loopback bind.
        base_url = "${config.nic.services.searxng.public.publicUrl}/";
        secret_key = "$SEARXNG_SECRET";
        image_proxy = true; # thumbnails via this box, not the origin host
      };

      search = {
        # json on top of the default html: the agents on this box get a search
        # API at /search?q=…&format=json, which wakes the service like any
        # other request.
        formats = [
          "html"
          "json"
        ];
        # One upstream request per keystroke — only affordable because the
        # service no longer sleeps; it used to race a cold start.
        autocomplete = "google";
      };

      ui = {
        center_alignment = true;
        results_on_new_tab = true;
        theme_args.simple_style = "black";
      };

      # All eleven upstream entries, restated deliberately: `plugins` is the one
      # key update_settings assigns wholesale instead of merging
      # (settings_loader.py:142-144), so listing only the two flipped here would
      # deactivate the other nine. Quoted names are entry points, not a path.
      plugins = {
        "searx.plugins.calculator.SXNGPlugin".active = true;
        "searx.plugins.infinite_scroll.SXNGPlugin".active = true; # upstream: false
        "searx.plugins.hash_plugin.SXNGPlugin".active = true;
        "searx.plugins.self_info.SXNGPlugin".active = true;
        "searx.plugins.unit_converter.SXNGPlugin".active = true;
        "searx.plugins.ahmia_filter.SXNGPlugin".active = true;
        "searx.plugins.hostnames.SXNGPlugin".active = true;
        "searx.plugins.time_zone.SXNGPlugin".active = true;
        "searx.plugins.oa_doi_rewrite.SXNGPlugin".active = true; # upstream: false
        "searx.plugins.tor_check.SXNGPlugin".active = false;
        "searx.plugins.tracker_url_remover.SXNGPlugin".active = true;
      };

      # Upstream's default general set — google, duckduckgo, startpage, brave —
      # all four refuse this instance, measured 2026-09-01 from the box's own
      # residential IP: access denied, CAPTCHA, CAPTCHA, 429. Nothing else in
      # that set searches the open web, so as shipped the first query returns
      # zero results and four error toasts.
      #
      # The replacements are a measurement, not a taste: each was queried alone
      # through /search?format=json and kept only if it answered. Rejected:
      # mojeek, presearch, qwant (CAPTCHA/denied); yahoo, stract, right dao,
      # yep, ask (HTTP errors); yacy, mwmbl (timeouts); crowdview (forum-only);
      # encyclosearch (dilutes a general query).
      #
      # Blocks come and go — re-testing one is flipping `disabled` here, or
      # ticking it under Preferences → Engines for one browser, no rebuild.
      engines = [
        # Google, via the only engine upstream still ships working. The plain
        # `google` web engine is marked `inactive: true` in this snapshot —
        # retired, not merely off, so `disabled = false` cannot bring it back.
        # Forcing `inactive = false` does register it and it fetches without
        # error, but every query returns zero results: Google's markup no longer
        # matches its XPaths, which is what retirement means here. `google cse`
        # goes through cse.google.com's element API, needs no key, and returns
        # Google's own index (20/page, EN and FR both fine).
        #
        # This is also why the package is pinned forward in overlays.nix: 25.11's
        # snapshot predates google_cse and its plain `google` 403s outright.
        { name = "google cse"; disabled = false; }
        { name = "duckduckgo"; disabled = true; }
        { name = "startpage"; disabled = true; }
        { name = "brave"; disabled = true; }

        { name = "bing"; disabled = false; } # carries the result set
        { name = "fynd"; disabled = false; }
        { name = "seznam"; disabled = false; }
        # The only other real general index here. Queries reach it from this box
        # rather than the browser, which is the point of a metasearch proxy.
        { name = "yandex"; disabled = false; }
        { name = "wiby"; disabled = false; } # small-web long tail
        { name = "searchmysite"; disabled = false; }
      ];
    };
  };

  # Lazy-start, no idle sleep (hosts/rpi5/lib/socket-activate.nix): the first
  # request after a boot starts it, and then it stays up. Measured 2026-09-02:
  # 138 MB RSS cold, ~147 MB after one search, settling ~175-185 MB once the
  # engine caches are warm. That is the standing cost of `idleSec = null`, and
  # it is deliberate — as a browser's default search engine the ~10 s cold start
  # landed on a keystroke, which is the one place it is not affordable.
  #
  # searx-init is RemainAfterExit with RuntimeDirectoryPreserve, so /run/searx
  # would survive a sleep if one is ever restored here.
  services.socketActivate.searxng = {
    enable = true;
    realUnit = "searx.service";
    listen = [ "127.0.0.1:${toString proxyPort}" ];
    backend = "127.0.0.1:${toString internalPort}";
    idleSec = null;
    readyProbe = {
      # Returns a literal "OK" with no template, engine or cookie involved.
      url = "http://127.0.0.1:${toString internalPort}/healthz";
      expectStatus = 200;
      timeoutSec = 90; # ~10 s measured cold; the rest is page-cache margin
    };
  };

  systemd.services.searx.serviceConfig = {
    # SearXNG's expiring SQLite cache (engine tokens, tracker patterns) lives at
    # $TMPDIR/sxng_cache_*.db. Under PrivateTmp it dies with the unit, so point
    # TMPDIR at a cache dir that outlives a restart (and would have outlived an
    # idle-stop, back when there was one).
    CacheDirectory = "searx";
    CacheDirectoryMode = "0700";
    Environment = [ "TMPDIR=/var/cache/searx" ];

    # It fetches attacker-influenced URLs and parses the HTML that comes back,
    # so box it in: network and its own cache dir, nothing else.
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
      # Needed despite the process only speaking TCP: glibc's NSS uses a Unix
      # socket, and every query here starts with a DNS lookup.
      "AF_UNIX"
    ];

    # No MemoryHigh/MemoryMax: this Pi boots with cgroup_disable=memory, so
    # systemd accepts both and silently ignores them — it would read as a guard
    # where there is none. earlyoom (configuration.nix) is the backstop.
  };

  nic.services.searxng = {
    backup = [ "none" ];
    backupNote =
      "stateless — settings come from the Nix store, /var/cache/searx holds only "
      + "re-fetchable engine data, and preferences live in the visitor's cookie";

    heavyUnits = [ "searx.service" ];
    # Load-bearing now that it no longer sleeps: ~175 MB is held for as long as
    # the box is up, and a rebuild has about 250 MB of slack to work with.
    heavyPriority = 165;

    public = {
      order = 195;
      port = 3970;
      backend = "http://127.0.0.1:${toString proxyPort}";
      # NEVER: a public metasearch instance is an open proxy that gets this
      # box's IP CAPTCHA'd. (All three funnel ports are allocated regardless.)
      funnel = false;
      # Routed but renders nothing: homepage's search bar points straight here,
      # so a tile would just be a card you click to reach a box you type into.
      # `order` still sequences the serve command, and is asserted unique.
      tile = null;
    };
  };
}
