{ username, ... }:
{
  primaryUser = username;
  
  stateVersion = 5;
  
  keyboard = {
    enableKeyMapping = true;
    remapCapsLockToEscape = true;
    nonUS.remapTilde = true;
  };

  defaults = {
    loginwindow.GuestEnabled = false;
    spaces.spans-displays = false;
    screencapture.location = "/tmp";

    dock = {
      autohide = true;
      mru-spaces = false;
      minimize-to-application = true;
      show-recents = false;
    };

    finder = {
      AppleShowAllFiles = true;
      AppleShowAllExtensions = true;
      _FXShowPosixPathInTitle = true;
      FXEnableExtensionChangeWarning = false;
      CreateDesktop = false;
      FXPreferredViewStyle = "Nlsv"; # list view
      ShowPathbar = true;
    };

    CustomUserPreferences = {
      "com.apple.AppleMultitouchTrackpad" = {
        DragLock = false;
        Dragging = false;
        TrackpadThreeFingerDrag = true;
      };

      "com.apple.finder" = {
        NewWindowTargetPath = "file:///tmp";
        ShowExternalHardDrivesOnDesktop = true;
        ShowHardDrivesOnDesktop = true;
        ShowMountedServersOnDesktop = true;
        ShowRemovableMediaOnDesktop = true;
        _FXSortFoldersFirst = true;
        # When performing a search, search the current folder by default
        FXDefaultSearchScope = "SCcf";
        DisableAllAnimations = true;
      };

      "com.apple.screensaver" = {
        # Require password immediately after sleep or screen saver begins
        askForPassword = 1;
        askForPasswordDelay = 0;
      };

      "com.apple.AdLib" = {
        allowApplePersonalizedAdvertising = false;
      };

      "com.apple.print.PrintingPrefs" = {
        # Automatically quit printer app once the print jobs complete
        "Quit When Finished" = true;
      };

      "com.apple.SoftwareUpdate" = {
        AutomaticCheckEnabled = true;
        # Check for software updates daily, not just once per week
        ScheduleFrequency = 1;
        # Download newly available updates in background
        AutomaticDownload = 1;
        # Install System data files & security updates
        CriticalUpdateInstall = 1;
      };

      "com.apple.TimeMachine".DoNotOfferNewDisksForBackup = true;
      # Prevent Photos from opening automatically when devices are plugged in:
      "com.apple.ImageCapture".disableHotPlug = true;
      # Turn on app auto-update
      "com.apple.commerce".AutoUpdate = true;
    };

    NSGlobalDomain = {
      AppleICUForce24HourTime = true;
      AppleInterfaceStyleSwitchesAutomatically = false;
      AppleShowScrollBars = "WhenScrolling";
      NSNavPanelExpandedStateForSaveMode = true;
      "com.apple.mouse.tapBehavior" = 1;
      "com.apple.trackpad.scaling" = 1.0;
      _HIHideMenuBar = false;
      AppleInterfaceStyle = "Dark";
    };
  };
}
