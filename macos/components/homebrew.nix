{...}:
{
  enable = true;

  global.brewfile = true;
  caskArgs.language = "en-GB";

  onActivation = {
    # autoUpdate = true;
    # upgrade = true;
    cleanup = "zap";
    # Homebrew 5.x requires --force / --force-cleanup / $HOMEBREW_ASK
    # for `brew bundle install --cleanup`.
    extraFlags = [ "--force-cleanup" ];
  };

  taps = [
    "homebrew/cask-versions"
    "jorgelbg/tap"
    "koekeishiya/formulae"
    "dbt-labs/dbt"
    "auth0/auth0-cli"
    "infisical/get-cli"
    "Sikarugir-App/sikarugir"
    "RhetTbull/osxphotos"
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
    "infisical"
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
}
