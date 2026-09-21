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
  pkgs,
  lib,
  unstablePkgs,
  ...
}:

{
  # herdr's agent integrations, which are what make a restored pane come back as
  # the CONVERSATION it was rather than a bare shell: the hook reports
  # agent_session_id + agent_session_path, and `[session] resume_agents_on_restore`
  # (on by default) replays them after a server restart. Detection is a separate
  # thing and needs none of this — that is HERDR_AGENT, in home/claude.nix.
  #
  # Run rather than vendored, deliberately. The hook carries
  # HERDR_INTEGRATION_VERSION, so a checked-in copy goes stale the moment herdr
  # moves and `herdr integration status` starts reporting it outdated; letting
  # the installed herdr write its own keeps the two in lock-step. The artifact is
  # therefore generated rather than a store symlink — declared, not managed —
  # which is the same trade home/atuin.nix makes for its data dir.
  #
  # The installer also wants to register a SessionStart hook in
  # ~/.claude/settings.json, which is a read-only store symlink here, so that
  # half cannot work and is supplied from home/dotfiles/claude-settings.json
  # instead. Hence `|| true`: the script still lands, and a non-zero exit from
  # the half it cannot do must not fail the switch.
  home.activation.herdrIntegrations = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    for agent in claude codex pi; do
      run ${unstablePkgs.herdr}/bin/herdr integration install "$agent" || true
    done
  '';

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
