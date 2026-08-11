# GuiHash/ha-intratone — reverse-engineered Home Assistant integration for the
# Intratone (Cogelec) cloud intercom.
#
# Goal is on-demand remote door open via the "Clé mobile" / mobipass access
# locks (pure REST, POST /api/access/open/clemobil) — the visiophone
# audio/video path (go2rtc + ffmpeg) is left off (video opt-in, default false).
#
# `python3Packages` must be HA's own (unstable-overridden) set so the deps match
# the ABI of the HA binary — the caller passes
# config.services.home-assistant.package.python3Packages.
#
# Wired into services.home-assistant.customComponents: hosts/rpi5/home-assistant.nix.
{
  buildHomeAssistantComponent,
  fetchFromGitHub,
  python3Packages,
}:

buildHomeAssistantComponent rec {
  owner = "GuiHash";
  domain = "intratone";
  # renovate: datasource=github-releases depName=GuiHash/ha-intratone extractVersion=^v(?<version>.+)$
  version = "0.3.2";
  src = fetchFromGitHub {
    owner = "GuiHash";
    repo = "ha-intratone";
    rev = "v${version}";
    hash = "sha256-BkvdaY1oacmZM+bqTzxBf36G1jTkYK0wbxJRb4oIonY=";
  };
  dependencies = with python3Packages; [
    firebase-messaging
    voip-utils
  ];
}
