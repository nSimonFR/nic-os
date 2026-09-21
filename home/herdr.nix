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

{
  # ---------------------------------------------------------------------------
  # Tab-bar plan-usage readout (darwin only)
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
  # Linux is excluded: rpi5 runs the headless server, where there is no client
  # tab bar to render into and no Claude Keychain entry to read.
  # ---------------------------------------------------------------------------

  # Pins the interpreter so the command does not depend on whichever python3 the
  # server happens to find on PATH (it resolved to Xcode's). Called by NAME from
  # config.toml — a store path baked into a writable config would dangle on GC.
  home.packages = lib.mkIf pkgs.stdenv.isDarwin [
    (pkgs.writeShellApplication {
      name = "herdr-usage-bar";
      runtimeInputs = [ pkgs.python3 ];
      # `codex` and `security` come from the ambient PATH, which
      # writeShellApplication prepends to rather than replaces.
      text = ''
        exec python3 "$HOME/.config/herdr/usage-bar.py" "$@"
      '';
    })
  ];

  # Both out-of-store symlinks. config.toml has to be writable because herdr
  # rewrites it itself; usage-bar.py is writable for the same reason the Claude
  # theme is — retune the thresholds and the next 60s tick picks it up, no
  # rebuild.
  home.file = lib.mkIf pkgs.stdenv.isDarwin {
    ".config/herdr/config.toml".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/dotfiles/herdr-config.toml";

    ".config/herdr/usage-bar.py".source =
      config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nic-os/home/herdr/usage-bar.py";
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
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
