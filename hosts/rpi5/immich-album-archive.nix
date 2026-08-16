# Keep WhatsApp media out of the Immich timeline.
#
# The first attempt at this inferred provenance from EXIF ("make != Apple",
# missing timezone) and was reverted: WhatsApp strips metadata, but so do plenty
# of real cameras, so it flagged genuine photos and missed EXIF-less ones. See
# known_issue_immich_exif_filter_null_bail — do not rebuild that.
#
# What replaced it is provenance the phone records itself. WhatsApp's "Save to
# Camera Roll" writes into an iOS album called `WhatsApp`; the Immich mobile app
# mirrors device album membership onto the server. A photo is in that album iff
# WhatsApp put it there — no heuristic, and no false positive available.
#
# Why a timer rather than a workflow: Immich's workflow engine only triggers on
# AssetCreate / AssetMetadataExtraction. There is no "added to an album" event,
# and album membership is written after upload, so nothing exists to hang a
# workflow off. This reconciles instead.
#
# The gate matters as much as the schedule. Immich is socket-activated with a
# 30-minute idle sleep (immich.nix), so an ungated 15-minute timer would hold it
# awake permanently. IMMICH_ARCHIVE_ONLY_IF_AWAKE makes each tick a `systemctl
# is-active` and nothing more while Immich sleeps. That loses no coverage:
# membership is only written by an upload, and an upload is itself what wakes
# Immich.
{ config, pkgs, ... }:

{
  systemd.services.immich-album-archive = {
    description = "Archive WhatsApp-sourced assets out of the Immich timeline";
    after = [ "immich-server.service" ];
    environment = {
      IMMICH_URL = "http://127.0.0.1:2283";
      IMMICH_API_KEY_FILE = config.age.secrets.immich-api-key.path;
      IMMICH_ARCHIVE_ALBUMS = "WhatsApp";
      # The script dry-runs unless told otherwise; this is the opt-in.
      IMMICH_ARCHIVE_APPLY = "1";
      IMMICH_ARCHIVE_ONLY_IF_AWAKE = "immich-server.service";
    };
    serviceConfig = {
      Type = "oneshot";
      # nsimon owns the 0400 immich-api-key copy (secrets.nix), and the album is
      # his — the archive flip has to be made by the asset owner's key.
      User = "nsimon";
      ExecStart = "${pkgs.nicos-scripts}/bin/immich-album-archive";
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
    };
    path = [ pkgs.systemd ];
  };

  systemd.timers.immich-album-archive = {
    description = "Periodic WhatsApp-album archive reconcile";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "15min";
      Persistent = true;
    };
  };
}
