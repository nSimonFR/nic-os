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
  ];

  brews = [
    "auth0"
    "helm"
    "dbt-postgres"
    "pinentry-touchid"
  ];

  casks = [
    "1password"
    "android-studio"
    "arc"
    "beeper"
    "cursor"
    "cyberduck"
    "disk-inventory-x"
    "docker"
    "firefox@developer-edition"
    "godot"
    "google-chrome"
    "gramps"
    "iterm2"
    "jordanbaird-ice"
    "keyboardcleantool"
    "ledger-live"
    "linear-linear"
    "maccy"
    "macmediakeyforwarder"
    "obsidian"
    "plex"
    "postman"
    "rewind"
    "rocket"
    "slack"
    "steam"
    "stolendata-mpv"
    "spotify"
    "telegram"
    "transmission"
    "webtorrent"
    "whatsapp"
    "zed"
  ];

  masApps = {
    Aware = 1082170746;
    Xcode = 497799835;
    Spark = 6445813049;
    Amphetamine = 937984704;
    TheUnarchiver = 425424353;
    AutoMute = 1118136179;
  };
}
