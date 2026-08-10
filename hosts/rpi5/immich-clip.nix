# CLIP content filter for Immich Workflows.
#
# Immich has a real workflow engine, and immich.nix already uses it (the
# `Auto-file screenshots` workflow). What the bundled `immich-plugin-core` cannot
# do is filter on what is IN a picture: its filters are filename, EXIF, type,
# date, location and missing-timezone. This adds that missing step:
#
#   AssetMetadataExtraction -> nic-clip#clipFilter(seedAlbum=…, albumIds=[…])
#
# Everything about HOW it works now lives in github:nSimonFR/immich-clip-filter —
# the sidecar, the WASM plugin, the pending queue, the drainer, and 169 unit plus
# 36 contract tests. Same arrangement as sure-nix / airtrail-nix / ryot-nix: a
# flake input plus a thin module holding only this host's configuration.
#
# The two facts worth keeping in front of whoever reads this file next:
#
#   * beast holds the GPU and is usually OFF, so most uploads have no CLIP
#     embedding when the workflow fires. Those are *undecided*, not "no": the
#     sidecar parks them on a queue and the drain timer finishes them once Immich
#     has caught up. Immich never re-queues missing embeddings on its own, so the
#     drainer also kicks its smartSearch job — without that, a parked asset waits
#     forever no matter how patient the timer is.
#   * the step is SELF-CONTAINED (it does its own type check and its own album
#     add) because Immich reads workflow_step with no ORDER BY, so a filter cannot
#     reliably gate a later action step. Do not chain assetAddToAlbums after it.
{ config, ... }:

let
  stateDir = "/var/lib/immich-clip";
in
{
  services.immich-clip-filter = {
    enable = true;

    # ⚠️ NOT the project's `clip-filter` default. This install registered the
    # plugin as `nic-clip` before the code was extracted, and four live workflow
    # steps point at that row: a step references a plugin_method belonging to one
    # plugin row, keyed by NAME. Renaming would make Immich import a second,
    # separate plugin, stop loading this one (it would no longer be in the
    # folder), and leave every existing step pointing at nothing — each then has
    # to be deleted and recreated by hand.
    #
    # Keeping the name AND the version means the upsert matches on
    # (name, version) and wasmBytes is updated in place, which is the only path
    # that leaves the workflows working.
    pluginName = "nic-clip";

    # Same key as immich-api-key, decrypted a second time for the immich user —
    # see secrets.nix. The sidecar runs as `immich` so that pg_hba's
    # `local all all peer` lets it read smart_search over the unix socket with no
    # password and no extra role.
    keyFile = config.age.secrets.immich-clip-api-key.path;

    inherit stateDir;

    # Ceiling on what a workflow step may ask to wait for. Immich's workflow queue
    # runs 5 jobs and the extism plugin pool holds 5 — an unbounded wait typed
    # into a config box could pin all of them during an import.
    maxWait = 120;
  };

  nic.services.immich-clip = {
    backup = [ "none" ];
    backupNote = ''
      Two things live in ${stateDir}, and only one of them matters.

      profiles/ is a cache: each profile records exactly what it was built from
      (the prompt, or the seed asset ids), so immich-clip-profile reproduces it
      byte for byte, and the embeddings it averages live in the immich database,
      which Immich's own backup covers.

      pending.sqlite holds the queue (transient) AND the exclusion table (not).
      The exclusions are the record of every photo taken out of an album by hand;
      losing them means the next backfill puts them all back. Neither is a source
      of truth for anything but that, which is why this is still `none` — but that
      is the file to think about if that ever changes.
    '';
  };
}
