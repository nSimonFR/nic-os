# herdr's headless server on the Linux hosts, so remote sessions outlive the
# thing that opened them.
#
# The split matters for how this is used: `herdr --remote rpi5` (or a saved
# machine, `herdr machine add`) runs the CLIENT on the Mac and reaches the
# SERVER over plain OpenSSH — the panes, PTYs and agent processes all live on
# the remote. Closing the laptop therefore drops only the client; the work keeps
# running. But that only holds while a server is up, and started by hand it dies
# with the first reboot, which is what this unit fixes.
#
# Linux only. The Mac runs `herdr` interactively and starts its own server on
# demand, so a launchd agent would only race it.
{
  config,
  pkgs,
  lib,
  unstablePkgs,
  ...
}:

let
  # Exit 1 when a herdr server already answers on the API socket, which tells
  # systemd to skip the unit instead of starting a second one that cannot bind.
  #
  # gnugrep is listed explicitly because writeShellApplication only PREPENDS
  # runtimeInputs to the ambient PATH, and a systemd --user unit's PATH carries
  # no coreutils at all. Left out, the guard dies on "grep: command not found",
  # the pipeline is false, and it reports ABSENT against a server that is up —
  # re-arming the exact loop this script exists to break. It passed by hand only
  # because an interactive shell lends it a grep the unit never has.
  herdrServerAbsent = pkgs.writeShellApplication {
    name = "herdr-server-absent";
    runtimeInputs = [ unstablePkgs.herdr pkgs.gnugrep ];
    text = ''
      if herdr status server 2>/dev/null | grep -q '^status: running'; then
        exit 1
      fi
      exit 0
    '';
  };
in

{
  # ---------------------------------------------------------------------------
  # Tab-bar plan-usage readout (every host)
  #
  # `ui.tab_bar_right` is the one status surface herdr has that is not a
  # navigation target, which is why the readout lives there and not in the
  # sidebar. The alternatives were all tried and rejected: a space row and an
  # agent row are both clickable and, because rate limits are per ACCOUNT, would
  # repeat one number per space; a decorative "machine" entry is only reachable
  # by hand-writing ~/.local/state/herdr/client/endpoints.json, has no socket
  # API, and is still clickable.
  #
  # Colour is emoji, not ANSI: herdr strips ESC sequences from tab-bar command
  # output, so no threshold colouring is possible any other way. The published
  # plugins confirm the constraint rather than solving it — speardragon's tints
  # each segment by BRAND, never by how close a window is, and senna-lang's
  # colours live in a PANE, which is a real terminal.
  #
  # Not a herdr plugin, deliberately. Both candidates read Claude usage from a
  # source that is wrong here: ~/.claude.json has no cachedUsageUtilization key,
  # and the statusLine-capture route rewrites statusLine.command in
  # ~/.claude/settings.json — an out-of-store symlink into this repo, so the
  # installer edits the checkout (observed: it did, and pointed the setting at a
  # Mac-local absolute path shared with the Linux hosts).
  #
  # Every host, not just darwin. A `type = "command"` entry is resolved by the
  # SERVER, so `herdr --remote rpi5` renders rpi5's config.toml, not the Mac's —
  # leaving every remote space without a bar until rpi5 carries this too. The
  # reader is cross-platform for the same reason: it reads the login Keychain on
  # darwin and ~/.claude/.credentials.json on Linux, which is the form Claude
  # Code uses there and which rpi5 already has.
  # ---------------------------------------------------------------------------

  # Pins the interpreter so the command does not depend on whichever python3 the
  # server happens to find on PATH (it resolved to Xcode's). Called by NAME from
  # config.toml — a store path baked into a writable config would dangle on GC.
  home.packages = [
    (pkgs.writeShellApplication {
      name = "herdr-usage-bar";
      runtimeInputs = [ pkgs.python3 ];
      # `codex`, and `security` on darwin, come from the ambient PATH, which
      # writeShellApplication prepends to rather than replaces.
      text = ''
        exec python3 "$HOME/.config/herdr/usage-bar.py" "$@"
      '';
    })
  ];

  # Delivery differs by host, and deliberately so.
  #
  # The Mac gets out-of-store symlinks into the checkout: config.toml HAS to be
  # writable there because herdr rewrites it itself (onboarding, the theme
  # picker), and usage-bar.py being editable means a threshold can be retuned
  # and picked up on the next 60s tick with no rebuild — the same trade
  # home/dotfiles/claude-theme.json makes.
  #
  # The Linux hosts get store copies. An out-of-store symlink there would point
  # into a checkout that is not guaranteed to be current — rpi5's was several
  # commits behind when this landed, so the link would simply have dangled — and
  # BeAsT may have no checkout at all. The cost is a read-only config.toml,
  # which is acceptable precisely because those hosts run the HEADLESS server:
  # the settings UI that writes to it lives in the client, which is the Mac.
  home.file =
    let
      inCheckout = rel: config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/${rel}";
      deliver = rel: stored: if pkgs.stdenv.isDarwin then inCheckout rel else stored;
    in
    {
      ".config/herdr/config.toml".source =
        deliver "home/dotfiles/herdr-config.toml" ./dotfiles/herdr-config.toml;

      ".config/herdr/usage-bar.py".source =
        deliver "home/herdr/usage-bar.py" ./herdr/usage-bar.py;
    };

  systemd.user.services.herdr = lib.mkIf pkgs.stdenv.isLinux {
    Unit = {
      Description = "herdr headless server";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Install.WantedBy = [ "default.target" ];
    Service = {
      Type = "simple";
      # `herdr server` is the headless form; bare `herdr` would try to open a
      # TUI and exit for want of a terminal.
      ExecStart = "${unstablePkgs.herdr}/bin/herdr server";

      # Yield to a server that is already up rather than fighting it.
      #
      # An interactive `herdr` starts a server on demand, and that one detaches
      # from this unit's cgroup and keeps the API socket. `herdr server` then
      # exits 1 with "herdr server is already running", Restart=on-failure fires
      # five seconds later, and the pair loops forever: observed on rpi5 at
      # restart counter 5072, against a stray server that had been up nine
      # hours. A failing ExecCondition marks the start as SKIPPED rather than
      # failed, so systemd stops retrying and the journal stays readable.
      #
      # ExecStartPre cannot be used for this — it would have to stop the running
      # server, killing live panes, which is the opposite of what the unit is
      # for.
      ExecCondition = "${herdrServerAbsent}/bin/herdr-server-absent";

      Restart = "on-failure";
      # A genuine failure loop now costs six journal lines a minute, not thirty.
      RestartSec = "30s";
    };
  };
}
