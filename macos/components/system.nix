{ ... }:
{
  keyboard = {
    enableKeyMapping = true;
    remapCapsLockToEscape = true;
    nonUS.remapTilde = true;
  };

  defaults = {
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
      AppleInterfaceStyle = "Dark";
    };
  };

  # activationScripts.postUserActivation.text = ''
  #   echo "Upgrading Homebrew Casks..."
  #   brew upgrade --casks
  # '';
}