{...}:
{
  enable = true;

  global.brewfile = true;
  caskArgs.language = "en-GB";

  onActivation = {
    autoUpdate = true;
    upgrade = true;
    cleanup = "zap";
  };
  
  taps = [
    "homebrew/core"
    "homebrew/cask"
    "homebrew/cask-versions"
    "jorgelbg/tap"
    "koekeishiya/formulae"
  ];

  brews = [
    "helm"
    "pinentry-touchid"
  ];

  casks = [
    "1password"
    "android-studio"
    "cyberduck"
    "docker"
    "firefox-developer-edition"
    "iterm2"
    "linear-linear"
    "macmediakeyforwarder"
    "postman"
    "rewind"
    "rocket"
    "slack"
    "steam"
    "spotify"
    "telegram"
    "whatsapp"
  ];

  masApps = {
    Aware = 1082170746;
    Xcode = 497799835;
    Spark = 6445813049;
    Amphetamine = 937984704;
    TheUnarchiver = 425424353;
    AutoMute = 1118136179;
  };

  # TODO
  # - Unclutter
  # - Contexts.App
  # - AirBuddy
}