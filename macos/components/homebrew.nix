{...}:
{
  enable = true;

  global.brewfile = true;
  caskArgs.language = "en-GB";

  onActivation = {
    # autoUpdate = true;
    # upgrade = true;
    cleanup = "zap";
  };

  taps = [
    "homebrew/cask-versions"
    "jorgelbg/tap"
    "koekeishiya/formulae"
    "dbt-labs/dbt"
    "auth0/auth0-cli"
    "Sikarugir-App/sikarugir"
    "RhetTbull/osxphotos"
  ];

  brews = [
    "auth0"
    "cookcli"
    "dbt-postgres"
    "helm"
    "pinentry-touchid"
    "RhetTbull/osxphotos/osxphotos"
    "tailscale"
    "tun2proxy"
    "wakeonlan"
  ];

  casks = [
    "1password"
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
    "linear-linear"
    "maccy"
    "macmediakeyforwarder"
    "obsidian"
    "plex"
    "postman"
    "qbittorrent"
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
