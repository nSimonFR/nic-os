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
        enable_metrics = false; # in-memory only, wiped by every idle-stop
      };

      server = {
        port = internalPort;
        bind_address = "127.0.0.1";
        # opensearch.xml and other absolute links are built from this, so it has
        # to be the Serve origin rather than the loopback bind.
        base_url = "${config.nic.services.searxng.public.publicUrl}/";
        secret_key = "$SEARXNG_SECRET";
      };

      search = {
        # json on top of the default html: the agents on this box get a search
        # API at /search?q=…&format=json, which wakes the service like any
        # other request.
        formats = [
          "html"
          "json"
        ];
        # Off: one upstream request per keystroke would cold-start a service
        # that sleeps every 10 minutes.
        autocomplete = "";
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
        { name = "google"; disabled = true; }
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

  # Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix): ~0 RAM at
  # rest, 14-134 MB awake. searx-init is RemainAfterExit with
  # RuntimeDirectoryPreserve, so /run/searx survives the sleep.
  services.socketActivate.searxng = {
    enable = true;
    realUnit = "searx.service";
    listen = [ "127.0.0.1:${toString proxyPort}" ];
    backend = "127.0.0.1:${toString internalPort}";
    idleSec = 600;
    readyProbe = {
      # Returns a literal "OK" with no template, engine or cookie involved.
      url = "http://127.0.0.1:${toString internalPort}/healthz";
      expectStatus = 200;
      timeoutSec = 90; # ~10 s measured cold; the rest is page-cache margin
    };
  };

  systemd.services.searx.serviceConfig = {
    # SearXNG's expiring SQLite cache (engine tokens, tracker patterns) lives at
    # $TMPDIR/sxng_cache_*.db. Under PrivateTmp it would die with every
    # idle-stop, so point TMPDIR at a cache dir that outlives the sleep.
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
    heavyPriority = 165; # lightest, and socket-asleep anyway

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
