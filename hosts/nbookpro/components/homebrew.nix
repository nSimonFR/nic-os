{ config, lib, pkgs, ... }:
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
      {
        name = "jundot/omlx";
        clone_target = "https://github.com/jundot/omlx";
      }
    ];

    brews = [
      "auth0"
      "cookcli"
      "dbt-postgres"
      "helm"
      "omlx"
      "pinentry-touchid"
      "RhetTbull/osxphotos/osxphotos"
      "tailscale"
      "tun2proxy"
      "wakeonlan"
    ];

    casks = [
      "affine"
      "bitwarden"
      "android-studio"
      "arc"
      "beekeeper-studio"
      "beeper"
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
      "jordanbaird-ice"
      "keyboardcleantool"
      "ledger-wallet"
      "linear"
      "maccy"
      "macmediakeyforwarder"
      "obsidian"
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
      "tailscale-app"
      "stolendata-mpv"
      "spotify"
      "telegram"
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
  # so the same store path.
  system.activationScripts.homebrew.text = lib.mkAfter ''
    if [ -f "${cfg.brewPrefix}/brew" ]; then
      PATH="${cfg.brewPrefix}:$PATH" \
      sudo --preserve-env=PATH --user=${lib.escapeShellArg cfg.user} --set-home \
        env HOMEBREW_NO_AUTO_UPDATE=1 \
        brew bundle cleanup --file='${pkgs.writeText "Brewfile" cfg.brewfile}' --force --zap
    fi
  '';
}
