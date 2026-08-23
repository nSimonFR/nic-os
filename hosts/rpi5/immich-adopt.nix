{ pkgs, config, ... }:
# immich-adopt — keep Alfie's uploads as photos *I* own.
#
# Partner sharing (a row in Immich's `partner` table, Alfie -> Nico) already
# makes his library visible in my timeline and addable to my albums: the server's
# `Permission.AssetShare` check resolves to owner-OR-partner. What it does not do
# is make the assets mine. They stay on his quota, and the day he deletes a photo
# — or his account — it leaves my albums with it.
#
# So this timer takes the durable half: `immich-adopt --from-owner` walks his
# library and re-uploads each original under my ownership, then puts my copy in
# `§ Alfie x Nico`. Costs a second copy on disk (~700 MB for his current 174, on
# a 687 GB disk with 582 GB free) and buys independence from his account.
#
# Deliberately NOT using --replace: his originals keep their album entries, so he
# keeps his contributor credit and any comments on them. The album ends up holding
# both copies of the older shots; that is the price of not rewriting his history.
#
# The state file (StateDirectory below) is what keeps a daily run cheap — an
# already-adopted asset is not re-downloaded. Losing it is survivable, not fatal:
# the server rejects a duplicate checksum per owner and hands back the existing
# id, so a rebuilt cursor re-links instead of re-copying.
let
  alfie = "ae7e0e93-266c-4cc0-a061-64512ddb0480";
  albumAlfieNico = "694c5656-d748-4c95-8846-1eda2a7632fc";
in
{
  systemd.services.immich-adopt-alfie = {
    description = "Adopt Alfie's Immich uploads into Nico's library";
    # Nothing to adopt if the API is not up, and a failed run is retried by the
    # timer rather than being worth an alert.
    after = [ "immich-server.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Runs as `immich` purely to read the api key: agenix cannot chown a secret
      # to a DynamicUser, and this needs nothing else the immich user has.
      User = "immich";
      Group = "immich";
      StateDirectory = "immich-adopt";
      ExecStart = "${pkgs.nicos-scripts}/bin/immich-adopt --apply";
      # A partial run is normal (one unreadable original should not fail the
      # unit); the script logs FAILED per asset and exits 0.
      Restart = "no";
    };
    environment = {
      IMMICH_ADOPT_OWNER = alfie;
      IMMICH_ADOPT_TARGET = albumAlfieNico;
      IMMICH_ADOPT_STATE = "/var/lib/immich-adopt/state.json";
      # Same plaintext as immich-api-key, decrypted for the immich user — see
      # secrets.nix. Shared with the CLIP sidecar, which needs the same thing.
      IMMICH_API_KEY_FILE = config.age.secrets.immich-clip-api-key.path;
    };
  };

  systemd.timers.immich-adopt-alfie = {
    description = "Daily adopt of Alfie's Immich uploads";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Nightly, after the 03:00 nightly tasks have settled. Persistent so a Pi
      # that was off still catches up on the next boot.
      OnCalendar = "04:20";
      RandomizedDelaySec = "20min";
      Persistent = true;
    };
  };
}
