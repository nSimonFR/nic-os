# ppaglier/voltalis-homeassistant — Home Assistant custom component.
#
# Fuller-featured Voltalis integration than the previous jdelahayes/ha-voltalis
# (sensor-only). Adds climate/thermostat control, water-heater, per-device
# preset/switch and global program selects. Same domain "voltalis" → this is a
# drop-in source swap. Config-entry data schema differs: ppaglier reads
# entry.data["username"] (jdelahayes stored "email") — the existing config entry
# must be migrated out-of-band (HA stopped; .storage/core.config_entries is
# HA-owned and rewritten at runtime, so it can't be patched from an activation
# script) or re-added via the UI.
#
# manifest requirements: aiohttp (HA core) + pydantic (>=2.12.2; HA ships 2.12.x).
# `python3Packages` must be HA's own set so the ABI matches the HA binary — the
# caller passes config.services.home-assistant.package.python3Packages.
#
# Wired into services.home-assistant.customComponents: rpi5/home-assistant.nix.
{
  buildHomeAssistantComponent,
  fetchFromGitHub,
  python3Packages,
}:

buildHomeAssistantComponent rec {
  owner = "ppaglier";
  domain = "voltalis";
  version = "0.6.6";
  src = fetchFromGitHub {
    owner = "ppaglier";
    repo = "voltalis-homeassistant";
    rev = version;
    hash = "sha256-uliKbPrgTYSJ8J+Mv9z3hLzdVz/dNJolNChjPNKroBE=";
  };
  dependencies = with python3Packages; [
    aiohttp
    pydantic
  ];
}
