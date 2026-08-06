# hosts/rpi5/moxfield-sync.nix
#
# Makes ShowMyCards a read-only mirror of Moxfield.
#
# Moxfield is the single writer for BOTH halves of the data:
#
#   - deck contents      -> ShowMyCards lists
#   - the card collection, including which binder/box each card sits in
#                        -> ShowMyCards inventory + storage locations
#
# The second half used to be the argument for editing ShowMyCards directly: physical
# storage was thought to be a concept Moxfield had no representation for. It has one
# — trade binders — and the collection is public, so it reads with no auth at all
# (GET /v1/users/<user> -> collectionPublicId, then /v1/collections/search/<id>).
# With that, nothing needs to write to ShowMyCards by hand, and the agent skill that
# documented how to do so is gone.
#
# There is deliberately NO push direction. Writes to Moxfield need
# `Authorization: Bearer`, and the token endpoint POST /v2/account/token requires a
# Cloudflare Turnstile CAPTCHA that cannot be produced server-side — see
# moxfield/moxfield-public#143, an open report from a developer whose User-Agent was
# whitelisted by Moxfield support, concluding it "prevents any automated interaction
# with the private API, even for approved clients". So the user edits on Moxfield and
# this job propagates; there is no reverse path and nothing to reconcile.
#
# NOTE the pull itself is only *tolerated*, not sanctioned — Moxfield's ToS §4(c)(5)
# prohibits using "any robot … to access the Site for any purpose" without written
# approval, and their FAQ states "our API is not public". Their FAQ does say they
# will help personal, non-commercial projects via support@moxfield.com; getting
# written permission + a whitelisted User-Agent is the one route that makes this
# legitimate. Until then: serial fetches, a 3 s delay, exponential backoff, an honest
# User-Agent, and a hash check so an unchanged deck costs zero requests beyond the
# fetch. The collection mirror adds exactly two requests per day.
#
# Decks are discovered per user rather than pinned by id, so a new deck on Moxfield
# syncs on its own. The one non-obvious requirement is `showIllegal=true` on the
# search (see the script): without it Moxfield hides decks it deems illegal, which
# silently drops any deck still being built — exactly the ones worth syncing.
#
# Reconciliation is diff-based (add/update/delete per item), NOT delete-and-recreate:
# ShowMyCards' /api/data/import is additive-only with no replace mode, so a
# recreate-style sync would duplicate the collection on every run.
{ config, pkgs, lib, ... }:
let
  stateDir = "/var/lib/moxfield-sync";

  # Moxfield usernames whose DECKS to sync. The search matches AUTHORS, not just the
  # creator, so co-authored decks already arrive through either account — "Pixie
  # Dust" is owned by Hexaphrodite and reachable via nSimon alone. Listing
  # Hexaphrodite as well widens this to *all* of their decks, co-authored or not.
  # Results are deduped by publicId, so the overlap costs nothing but the search.
  users = [ "nSimon" "Hexaphrodite" ];

  # Whose COLLECTION mirrors into ShowMyCards. Deliberately one user, not `users`:
  # the inventory represents the cards physically in this house, and merging a second
  # account's collection into it would claim ownership of cards that are not here.
  collectionUser = "nSimon";

  # There is deliberately NO binder -> storage-location map here. Storage locations
  # are discovered from the collection and reconciled by sync_storage_locations():
  # a binder seen for the first time creates a location, and a binder renamed on
  # Moxfield renames it. Adding or renaming one costs no config edit and no rebuild.
  #
  # A hardcoded map was the first design and it did not survive contact: "Magic Big
  # Box" -> "Big Box", "Red Dragon Book" -> "BOOK - Red Dragon", "EDH 2013 - Alfie"
  # -> "EDH - Alfie" -> "EDH - Errant", plus a brand-new "EDH - Hei", all inside one
  # afternoon. Every one of those needed a file edit and a rebuild, and the last one
  # aborted the sync outright.
  #
  # The publicId -> location id link lives in ${stateDir}/binders.json, because
  # ShowMyCards storage rows have no field to hold a foreign id and names cannot be
  # the link when renaming is the thing being handled. Box-vs-Binder is the one bit
  # Moxfield genuinely cannot express, so it is inferred from the name on create —
  # cosmetic in ShowMyCards, so a wrong guess costs an icon rather than data.
in
{
  # No wantedBy: only the timer (or a manual `systemctl start`) should run this.
  # A run on every activation would hammer Moxfield on each rebuild.
  systemd.services.moxfield-sync = {
    description = "Mirror Moxfield collection + decks into ShowMyCards";
    after = [ "showmycards-proxy.socket" "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.python3 ];
    environment = {
      MOXFIELD_USERS = lib.concatStringsSep "," users;
      MOXFIELD_COLLECTION_USER = collectionUser;
      # Honest, identifiable UA with a contact route, rather than impersonating a
      # browser: if Moxfield want this traffic gone they should be able to see who
      # it is and tell us.
      MOXFIELD_USER_AGENT = "nic-os-moxfield-sync/1.0 (self-hosted personal ShowMyCards sync; +https://github.com/nSimonFR/nic-os)";
      # :8330 is the socket-activation proxy — the ONLY address that wakes the
      # sleeping backend. :13344 cold is connection-refused.
      SMC_API = "http://127.0.0.1:8330/api";
      SMC_DB = "/mnt/data/showmycards/database.db";
      STATE_DIR = stateDir;
      # Live. Validated by a dry run first (2026-07-28): inventory +0 ~0 -0 against a
      # 618-card collection with 182 printings remapped to their fr variant, which is
      # the signal that the language resolution in resolve_printings() is correct.
      # Set back to "1" before changing anything about the mirror — there is no
      # soft-delete anywhere in ShowMyCards.
      DRY_RUN = "0";
    };
    serviceConfig = {
      Type = "oneshot";
      # Runs as showmycards for read access to the 0750 sqlite DB (read-only, for
      # the printing lookups the API cannot express).
      User = "showmycards";
      Group = "showmycards";
      StateDirectory = "moxfield-sync";
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/moxfield-sync.py}";
    };
  };

  systemd.timers.moxfield-sync = {
    description = "Daily Moxfield → ShowMyCards mirror";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 05:20:00"; # after the backup window, before the morning
      Persistent = true;             # catch up a missed run if the Pi was off
      RandomizedDelaySec = "10m";    # don't hit Moxfield at a predictable instant
    };
  };
}
