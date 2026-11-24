{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homebrew;
in
{
  homebrew = {
    enable = true;

    global.brewfile = true;
    caskArgs.language = "en-GB";

    onActivation = {
      # autoUpdate = true;
      # upgrade = true;
      # Homebrew 7 removed `brew bundle --cleanup`, which nix-darwin 25.11 still passes
      # (fixed on master, 2026-06). The zap runs below instead.
      cleanup = "none";
    };

    taps = [
      "homebrew/cask-versions"
      "jorgelbg/tap"
      "koekeishiya/formulae"
      "dbt-labs/dbt"
      "auth0/auth0-cli"
      "Sikarugir-App/sikarugir"
      "RhetTbull/osxphotos"
      "manaflow-ai/cmux"
      "growlyx/tap"
      "stablyai/orca"
      {
        name = "jundot/omlx";
        clone_target = "https://github.com/jundot/omlx";
      }
    ];

    brews = [
      "auth0"
      "cookcli"
      "helm"
      "omlx"
      "pinentry-touchid"
      "RhetTbull/osxphotos/osxphotos"
      "growlyx/tap/tailmux"
      "wakeonlan"
    ];

    casks = [
      "bitwarden"
      "android-studio"
      "arc"
      "beekeeper-studio"
      "claude"
      "cmux"
      "cursor"
      "cyberduck"
      "disk-inventory-x"
      "docker-desktop"
      "epic-games"
      "firefox@developer-edition"
      "ghostty"
      "godot"
      "google-chrome"
      "gramps"
      "iterm2"
      "keyboardcleantool"
      "ledger-wallet"
      "linear"
      "maccy"
      "macmediakeyforwarder"
      "obsidian"
      # Qualified: the bare `orca` cask is plotly's, not Stably's agent IDE.
      "stablyai/orca/orca"
      "plex"
      "postman"
      "qbittorrent"
      "raycast"
      "rewind"
      "rocket"
      "sikarugir"
      "slack"
      "steam"
      "t3-code"
      "stolendata-mpv"
      "spotify"
      "telegram"
      "thaw"
      "transmission"
      "warp"
      "webtorrent"
      "whatsapp"
      "zed"
      "zen"
    ];

    masApps = {
      Aware = 1082170746;
      Xcode = 497799835;
      Spark = 6445813049;
      Amphetamine = 937984704;
      TheUnarchiver = 425424353;
      AutoMute = 1118136179;
      Timepage = 989178902;
    };
  };

  # Replaces onActivation.cleanup = "zap"; same content as nix-darwin's Brewfile,
  # so the same store path. Non-fatal: cleanup errors on a keg whose tap dropped
  # its formula (dbt-postgres), and `set -e` then aborted the whole deploy.
  system.activationScripts.homebrew.text = lib.mkAfter ''
    if [ -f "${cfg.prefix}/bin/brew" ]; then
      PATH="${cfg.prefix}/bin:$PATH" \
      sudo --preserve-env=PATH --user=${lib.escapeShellArg cfg.user} --set-home \
        env HOMEBREW_NO_AUTO_UPDATE=1 \
        brew bundle cleanup --file='${pkgs.writeText "Brewfile" cfg.brewfile}' --force --zap \
        || echo "warning: brew bundle cleanup failed; nothing was removed" >&2
    fi
  '';
}
