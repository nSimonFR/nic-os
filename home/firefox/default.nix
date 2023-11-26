{ pkgs, username, ... }:
{
  programs.firefox = {
    enable = true;
    
    package = 
      if pkgs.stdenv.hostPlatform.isDarwin then
        # TODO MacOS:
        # brew install --cask firefox
        pkgs.runCommand "firefox-0.0.0" { } "mkdir $out"
      else
        pkgs.firefox;
        
    profiles.${username} = {
      userChrome = builtins.readFile ./userChrome.css;
      userContent = builtins.readFile ./userContent.css;
    };
  };

  xdg.mimeApps.defaultApplications = {
    "text/html" = ["firefox.desktop"];
    "text/xml" = ["firefox.desktop"];
    "x-scheme-handler/http" = ["firefox.desktop"];
    "x-scheme-handler/https" = ["firefox.desktop"];
  };
}