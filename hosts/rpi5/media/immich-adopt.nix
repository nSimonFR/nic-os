{ pkgs, config, lib, ... }:
# immich-adopt — keep other people's shared photos as photos *I* own.
#
# An Immich asset has exactly one owner and album sharing does not change that:
# adding an asset to any album needs `Permission.AssetShare`, which resolves to
# owner-OR-partner and nothing else. Partner sharing fixes the permission but not
# the ownership — the assets stay on the sharer's quota, and the day they delete a
# photo (or their account) it leaves my albums with it. `immich-adopt` takes the
# durable half: re-upload the original under my ownership.
#
# One entry per person below. Each is either:
#   owner  = <user id>    every asset they own (needs partner sharing to read it)
#   source = <album id>   only what is in that album (no partner sharing needed)
# and both land in `target`. Adding a third person is an entry here, nothing else.
#
# Deliberately no `--replace` anywhere: the sharer keeps their own album entries,
# so they keep their contributor credit and any comments on them. The cost is that
# an album ends up holding both copies of anything adopted; that is the price of
# not rewriting someone else's history.
#
# Per-person state files (never one shared file — two units writing the same path
# would race) are what keep a nightly run cheap: an already-adopted asset is not
# re-downloaded. Losing one is survivable, not fatal — the server rejects a
# duplicate checksum per owner and hands back the existing id, so a rebuilt cursor
# re-links instead of re-copying.
let
  stateDir = "/var/lib/immich-adopt";

  jobs = {
    # Partner sharing is in place for Alfie, so his whole library is readable and
    # worth adopting wholesale — he is the continuous case.
    alfie = {
      description = "Alfie's uploads";
      owner = "ae7e0e93-266c-4cc0-a061-64512ddb0480";
      target = "694c5656-d748-4c95-8846-1eda2a7632fc"; # § Alfie x Nico
      at = "04:20";
    };
    # Bastien is NOT a partner — without that, his assets are only reachable
    # through the album he shared, so this is album-scoped by necessity rather
    # than by choice. It still needs to be a timer: anything he adds later is
    # otherwise unreachable, since I cannot add a non-partner's asset to my own
    # albums by hand either.
    bastien = {
      description = "Bastien's shared-album photos";
      source = "9471acd1-b85a-4a5f-8cb8-0d6a7447b56e"; # Nico & Bastien
      target = "f4b34838-dc6c-4fc8-b059-a44e015463c8"; # § Bastien x Nico
      at = "04:50";
    };
  };

  unitName = name: "immich-adopt-${name}";

  service = name: job: {
    description = "Adopt ${job.description} into Nico's library";
    # Nothing to adopt if the API is down, and a failed run is retried by the
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
      # A partial run is normal — one unreadable original should not fail the
      # unit. The script logs FAILED per asset and still exits 0.
      Restart = "no";
    };
    environment = {
      IMMICH_ADOPT_TARGET = job.target;
      IMMICH_ADOPT_STATE = "${stateDir}/${name}.json";
      # Same plaintext as immich-api-key, decrypted for the immich user — see
      # secrets.nix. Shared with the CLIP sidecar, which needs the same thing.
      IMMICH_API_KEY_FILE = config.age.secrets.immich-clip-api-key.path;
    }
    // lib.optionalAttrs (job ? owner) { IMMICH_ADOPT_OWNER = job.owner; }
    // lib.optionalAttrs (job ? source) { IMMICH_ADOPT_SOURCE = job.source; };
  };

  timer = name: job: {
    description = "Nightly adopt of ${job.description}";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Staggered per job: two of these as the same user, both pulling originals
      # over HTTP on a 3.9 GB Pi, is worth keeping apart. Persistent so a host
      # that was off still catches up on the next boot.
      OnCalendar = job.at;
      RandomizedDelaySec = "10min";
      Persistent = true;
    };
  };
in
{
  # A job with both, or neither, would silently adopt the wrong thing — the
  # script rejects it at runtime, but a timer is the worst place to find out.
  assertions = lib.mapAttrsToList (name: job: {
    assertion = (job ? owner) != (job ? source);
    message =
      "immich-adopt job '${name}' must set exactly one of `owner` (whole library) "
      + "or `source` (single album).";
  }) jobs;

  systemd.services = lib.mapAttrs' (n: j: lib.nameValuePair (unitName n) (service n j)) jobs;
  systemd.timers = lib.mapAttrs' (n: j: lib.nameValuePair (unitName n) (timer n j)) jobs;
}
