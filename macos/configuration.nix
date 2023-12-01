{ config, pkgs, username, hostname, ... }:
{
  services.nix-daemon.enable = true;
  #nix.configureBuildUsers = true;

  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  networking.hostName = hostname;
  networking.localHostName = hostname;

  programs.zsh.enable = true;

  fonts.fonts = with pkgs; [
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    liberation_ttf
    fira-code
    fira-code-symbols
    font-awesome
    mplus-outline-fonts.githubRelease
    dina-font
    proggyfonts
  ];

  homebrew = {
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
      "pinentry-touchid"
    ];

    casks = [
      "1password"
      "iterm2"
      "linear-linear"
      "macmediakeyforwarder"
      "rewind"
      "firefox-developer-edition"
      "rocket"
      "slack"
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
  };

  system.activationScripts.postUserActivation.text = ''
   echo "Upgrading Homebrew Casks..."
   brew upgrade --casks
  '';

  #environment.systemPackages = [ pkgs.gcc ];

  security.pam.enableSudoTouchIdAuth = true;

  system.keyboard = {
    enableKeyMapping = true;
    remapCapsLockToEscape = true;
    nonUS.remapTilde = true;
  };

  system.defaults = {
    dock = {
      autohide = true;
      mru-spaces = false;
      minimize-to-application = true;
      show-recents = false;
    };

    spaces.spans-displays = false;
    screencapture.location = "/tmp";

    finder = {
      AppleShowAllExtensions = true;
      FXEnableExtensionChangeWarning = false;
      CreateDesktop = false;
      FXPreferredViewStyle = "Nlsv"; # list view
      ShowPathbar = true;
    };

    loginwindow.GuestEnabled = false;

    CustomUserPreferences = {
      # 3 finger dragging
      "com.apple.AppleMultitouchTrackpad".DragLock = false;
      "com.apple.AppleMultitouchTrackpad".Dragging = false;
      "com.apple.AppleMultitouchTrackpad".TrackpadThreeFingerDrag = true;

      # Finder's default location upon open
      #"com.apple.finder".NewWindowTargetPath = "file://${home}/";
    };

    NSGlobalDomain = {
      AppleICUForce24HourTime = true;
      AppleInterfaceStyleSwitchesAutomatically = true;
      AppleShowScrollBars = "WhenScrolling";
      NSNavPanelExpandedStateForSaveMode = true;
      "com.apple.mouse.tapBehavior" = 1;
      "com.apple.trackpad.scaling" = 1.0;
      _HIHideMenuBar = false;
    };
  };

  services.skhd.enable = true;
  services.skhd.skhdConfig = builtins.readFile ../home/dotfiles/skhdrc;

  services.yabai = {
    enable = true;
    package = (pkgs.yabai.overrideAttrs (o: rec {
      version = "6.0.1";
      src = builtins.fetchTarball {
        url = "https://github.com/koekeishiya/yabai/releases/download/v${version}/yabai-v${version}.tar.gz";
        sha256 = "08cs0h4x1ah3ipyj2dgskbpciwqfddc3ax8z176cadylr9svjrf0";
      };
    }));
    enableScriptingAddition = true;
    config = {
      layout = "stack";
      #window_border = "on";
      #window_border_width = 3;
      active_window_border_color = "0xff81a1c1";
      normal_window_border_color = "0xff3b4252";
      window_border_hidpi = "on";
      focus_follows_mouse = "autofocus";
      mouse_follows_focus = "on";
      #mouse_drop_action = "stack";
      #window_placement = "second_child";
      #window_opacity = "off";
      #window_topmost = "on";
      window_shadow = "float";
      #window_origin_display = "focused";
      #active_window_opacity = "1.0";
      #normal_window_opacity = "1.0";
      split_ratio = "0.50";
      #auto_balance = "on";
      mouse_modifier = "alt";
      mouse_action1 = "move";
      mouse_action2 = "resize";
      #top_padding = 10;
      #bottom_padding = 10;
      #left_padding = 10;
      #right_padding = 10;
      #window_gap = 10;
      #external_bar = "all:0:0";
    };
    extraConfig = ''
      yabai -m config --space 3 layout bsp
      yabai -m config --space 6 layout bsp
      yabai -m config --space 0 layout float

      yabai -m rule --add app='System Preferences' manage=off
      yabai -m rule --add label="Finder" app="^Finder$" title="(Co(py|nnect)|Move|Info|Pref)" manage=off
      yabai -m rule --add label="Firefox" app="^Firefox" title="^Opening" manage=off
      yabai -m rule --add label="Safari" app="^Safari$" title="^(General|(Tab|Password|Website|Extension)s|AutoFill|Se(arch|curity)|Privacy|Advance)$" manage=off
      yabai -m rule --add label="System Preferences" app="^System Preferences$" manage=off
      yabai -m rule --add label="Activity Monitor" app="^Activity Monitor$" manage=off
      yabai -m rule --add label="Calculator" app="^Calculator$" manage=off
      yabai -m rule --add label="Dictionary" app="^Dictionary$" manage=off
      yabai -m rule --add label="The Unarchiver" app="^The Unarchiver$" manage=off
      yabai -m rule --add label="Archive Utility" app="^Archive Utility$" manage=off
      yabai -m rule --add label="VirtualBox" app="^VirtualBox$" manage=off
      yabai -m rule --add label="Unclutter" app="^Unclutter$" manage=off
      yabai -m rule --add label="iStat" app=".*iStat.*" manage=off
      #yabai -m rule --add label="IINA" app="^IINA$" manage=off
    '';
  };

  services.activate-system.enable = true;

  # Silence the 'last login' shell message
  #home-manager.users.${username}.home.file.".hushlogin".text = "";
}
