# hosts/rpi5/dsh.nix
#
# DeepSeek Harness (`dsh`) — the Web UI, served on the tailnet.
#
# dsh deleted its TUI package upstream on 2026-08-04, so Web is its only
# interactive surface (ACP, JSON-RPC and one-shot `headless` are the rest).
# That is why an agent the user drives interactively is a *service* here rather
# than a shell alias the way `pi` is.
#
# The binary, its Aperture route (~/.dsh/cordis.patch.yml) and its skills all
# come from home/dsh — this module owns only the unit, the sleep policy and the
# public face. Both surfaces share one derivation (home/dsh/package.nix), so
# `dsh --profile headless` in a shell and this unit can never drift apart.
{
  config,
  lib,
  pkgs,
  inputs,
  username,
  tailnetFqdn,
  ...
}:
let
  dsh = import ../../home/dsh/package.nix { inherit pkgs lib inputs; };

  homeDir = config.users.users.${username}.home;

  internalPort = 13360; # dsh's own bind (loopback only — it refuses --host 0.0.0.0)
  proxyPort    = 8360;  # socket-activate proxy listen; Tailscale Serve → here
  publicPort   = 3950;  # tailnet HTTPS, declared once in nic.services.dsh.public below
in
{
  systemd.services.dsh-web = {
    description = "DeepSeek Harness Web UI";
    after = [ "network-online.target" "tailscaled.service" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      # Runs as the human, not a DynamicUser: this is a coding agent, and its
      # workspace, git identity, ssh keys and ~/.dsh all belong to nsimon. A
      # system unit rather than a systemd.user.service — user units on this box
      # have a live failure mode where user@1001 stops despite Linger=yes and
      # systemd-failed-alert cannot see them.
      User  = username;
      Group = config.users.users.${username}.group;

      WorkingDirectory = homeDir;

      # `dsh` binds 127.0.0.1 and rejects --host 0.0.0.0 with a usage error, so
      # Tailscale Serve proxies to loopback — which means requests arrive
      # carrying the tailnet authority in Host, and the /api browser-trust
      # fence refuses any authority it was not told about. Both spellings are
      # passed because the authority a browser sends for HTTPS on a non-443
      # port includes that port, while some clients drop it.
      ExecStart = lib.concatStringsSep " " [
        (lib.getExe dsh)
        "web"
        "--no-open" # headless box: there is no browser to hand off to
        "--port ${toString internalPort}"
        "--trusted-host ${tailnetFqdn}:${toString publicPort}"
        "--trusted-host ${tailnetFqdn}"
      ];

      Restart    = "on-failure";
      RestartSec = 5;

      # The Pi has 3.9 GB and an OOM thrash here takes the whole box down via
      # the watchdog. A long session with a big context is the realistic way
      # this grows, so bound it: MemoryHigh reclaims first, MemoryMax is the
      # wall.
      MemoryHigh = "1G";
      MemoryMax  = "1500M";
    };

    environment = {
      HOME = homeDir;
      # dsh loads AGENTS.md/CLAUDE.md and resolves credentials from the
      # inherited environment; nothing else is needed — the Aperture key and
      # the telemetry opt-out are baked into the wrapper (home/dsh/package.nix).
      NODE_ENV = "production";
    };
  };

  # ── Socket-activated idle sleep (hosts/rpi5/lib/socket-activate.nix) ────────
  # An open browser tab holds a connection, so the idle timer only trips once
  # nobody is actually using it. Sessions are persisted as JSONL under ~/.dsh,
  # so an idle stop loses nothing.
  services.socketActivate.dsh = {
    enable   = true;
    realUnit = "dsh-web.service";
    listen   = [ "127.0.0.1:${toString proxyPort}" ];
    backend  = "127.0.0.1:${toString internalPort}";
    idleSec  = 900;
    readyProbe = {
      # The SPA index off the web server's fallback seat. expectStatus is
      # pinned to what bring-up actually observed — see the module header of
      # socket-activate.nix on why a wrong code here fails the first wake.
      url          = "http://127.0.0.1:${toString internalPort}/";
      expectStatus = 200;
      # Node + the whole Cordis plugin tree on an ARM board: generous.
      timeoutSec   = 120;
    };
  };

  # ── Service registration (hosts/rpi5/lib/service-registration.nix) ──────────
  nic.services.dsh = {
    # ~/.dsh holds session JSONL, settings.yaml and .credentials.yaml — none of
    # it under /mnt/data, so restic does not see it. Deliberate: it is the same
    # class of state as ~/.pi/sessions and ~/.claude, neither of which is backed
    # up either. The durable artefacts of a session are the commits it makes.
    backup     = [ "none" ];
    backupNote = "Agent scratch state in ~/.dsh; transcripts are not worth a Storj slot.";

    heavyUnits    = [ "dsh-web.service" ];
    heavyPriority = 120;

    public = {
      # Row 4, the making row: Wakapi, Forgejo, here, Aperture. Moved out of
      # Backend — it is an interactive agent the user drives from a browser, so it
      # belongs with the other things it is used to build, not with the
      # never-visited plumbing tiles. Backend is down to three as a result.
      order   = 180;
      port    = publicPort;
      backend = "http://127.0.0.1:${toString proxyPort}";
      tile = {
        name        = "DeepSeek Harness";
        icon        = "si-deepseek";
        category    = "Apps";
        description = "Agent harness (dsh) — Aperture-routed";
        # Reads ~/.dsh/sessions off disk (nicos_scripts/homepage/stats.py
        # fetch_dsh), NOT dsh's HTTP API: dsh-web is socket-activated with a 900s
        # idle timer and a MemoryMax of 1500M, so polling the API would wake a
        # heavyweight Node process once a day to read three numbers.
        widget = {
          type = "customapi";
          url = "http://127.0.0.1:8087/dsh";
          refreshInterval = 3600000;
          mappings = [
            # `prompts` counts user/message records, not transcript lines — the
            # bulk of a session log is streaming chunk fragments, so a line count
            # measures how the stream was flushed rather than anything real.
            #
            # `last` is an age rather than a count-in-window: agent use is bursty,
            # and "sessions in the last 7 days" reads 0 most of the time (it is 0
            # right now, against 5 over 30 days). Same call as Reactive Resume's
            # Updated.
            #
            # No `workspaces` field. It is 2, and it is 2 because there are two
            # checkouts on this box.
            { field = "sessions"; label = "Sessions"; format = "number"; }
            { field = "prompts";  label = "Prompts";  format = "number"; }
            { field = "last";     label = "Last";     format = "number"; suffix = "d ago"; }
          ];
        };
      };
    };
  };
}
