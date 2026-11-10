# Coding and chat agents, and their plumbing: Claude Code, Cyrus, T3, the LLM gate, Entire.
{
  imports = [
    ./entire.nix
    ./cyrus.nix
    ./t3code.nix
    ./tiny-llm-gate.nix
    ./aperture-sync.nix
    ./claude/claude-remote-control.nix
    ./claude/claude-account-healthcheck.nix
    ./claude/claude-notify-aggregator.nix
    ./claude/claude-context-baseline.nix
    ./claude/claude-window-anchor.nix
    ./claude/t3-settle-retro.nix
  ];
}
