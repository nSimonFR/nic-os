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
  ];

  brews = [
    "helm"
    "dbt-postgres"
    "pinentry-touchid"
  ];

  casks = [
    "1password"
    "android-studio"
    "cyberduck"
    "docker"
    "firefox-developer-edition"
    "godot"
    "google-chrome"
    "iterm2"
    "linear-linear"
    "maccy"
    "macmediakeyforwarder"
    "mpv"
    "plex"
    "postman"
    "rewind"
    "rocket"
    "slack"
    "steam"
    "spotify"
    "telegram"
    "vanilla"
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
