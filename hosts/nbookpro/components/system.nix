{ username, ... }:
{
  primaryUser = username;

  stateVersion = 5;

  # Post-rebuild: reload yabai scripting addition + restart tun2proxy, and make
  # sure Remote Login is on.
  #
  # sshd is what Moshi's Easy Pair (`moshi-hook host setup`, see home/moshi.nix)
  # connects over before upgrading to mosh — it installs the phone's public key
  # into ~/.ssh/authorized_keys but cannot turn the service on. macOS has no
  # nix-darwin option for it: `systemsetup -setremotelogin` is the documented
  # switch and needs Full Disk Access for whichever terminal drives the rebuild,
  # so it falls back to the TCC-free launchctl pair. Both are idempotent, and
  # the guard keeps the common case down to one read.
  activationScripts.postActivation.text = ''
    sudo yabai --load-sa 2>/dev/null || true
    launchctl kickstart -k system/org.nixos.tun2proxy-work 2>/dev/null || true

    if ! systemsetup -getremotelogin 2>/dev/null | grep -qx "Remote Login: On"; then
      systemsetup -setremotelogin on >/dev/null 2>&1 || {
        launchctl enable system/com.apple.sshd 2>/dev/null
        launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null
      } || true
    fi
  '';
  
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
