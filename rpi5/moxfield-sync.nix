# rpi5/moxfield-sync.nix
#
# Keeps ShowMyCards decks in step with Moxfield, and generates the files needed to
# push the other way by hand.
#
#   PULL (automated): Moxfield is where decks are actually edited, so each run
#   reconciles the matching ShowMyCards list to the Moxfield deck. ShowMyCards
#   remains authoritative for physical storage (binders/boxes) — a concept Moxfield
#   has no representation for — so the two never own the same field and there are no
#   real conflicts to resolve.
#
#   PUSH (manual, by necessity): writes to Moxfield need `Authorization: Bearer`,
#   and the token endpoint POST /v2/account/token requires a Cloudflare Turnstile
#   CAPTCHA token that cannot be produced server-side. That is not a guess —
#   moxfield/moxfield-public#143 is an open report from a developer whose
#   User-Agent was whitelisted by Moxfield support, concluding it "prevents any
#   automated interaction with the private API, even for approved clients".
#   Separately, Moxfield's ToS §4(c)(5) prohibits using "any robot … to access the
#   Site for any purpose" without written approval, and their FAQ states "our API is
#   not public". Every third-party project that tried this landed in the same place:
#   of the ones surveyed, none write server-side, and the closest analogue
#   (fecet/moxtrice, a Moxfield↔Cockatrice sync) shipped read-only because "we
#   cannot really 'login'". So the export direction writes files the user uploads.
#
#   NOTE the pull itself is only *tolerated*, not sanctioned — clause 4(c)(5) covers
#   it too. Moxfield's FAQ says they will help personal, non-commercial projects
#   via support@moxfield.com; getting written permission + a whitelisted User-Agent
#   is the one route that makes this legitimate. Until then: serial fetches, a
#   3 s delay, exponential backoff, an honest User-Agent, and a hash check so an
#   unchanged deck costs zero requests beyond the fetch.
#
# Why a pinned deck list rather than discovery: `authorUserNames=<user>` search
# works unauthenticated but returned only 3 of this user's 4 *public* decks — "Hei
# Bai" is absent from their index. Discovery would silently drop decks, so the set
# is declared here where a missing deck is visible in git.
#
# Reconciliation is diff-based (add/update/delete per item), NOT delete-and-recreate:
# ShowMyCards' /api/data/import is additive-only with no replace mode, so a
# recreate-style sync would duplicate the collection on every run.
{ config, pkgs, lib, ... }:
let
  exportDir = "/mnt/data/moxfield-export";
  stateDir = "/var/lib/moxfield-sync";

  # Moxfield publicIds. Add a line per deck; `journalctl -u moxfield-sync` names
  # any deck whose list is missing.
  deckIds = [
    "Ou4xWfrIaEuFpqYIUyJ81Q" # Délinquant et Giada
    "XdlAEgx_QU28JlLtV118hg" # Hei Bai, esprit de l'équilibre
    "2pOKPPUVz0KinKotVJ71tA" # Manœuvre D'Évasion
    "KS3hvEsuqUyeeZ8hn1GK7w" # Pixie Dust
  ];
in
{
  # Export dir lives on /mnt/data (root is ~96% full) and is group-readable by
  # filebrowser's user so the generated files can be fetched over the tailnet.
  systemd.tmpfiles.rules = [
    "d ${exportDir} 0755 showmycards showmycards - -"
  ];

  # No wantedBy: only the timer (or a manual `systemctl start`) should run this.
  # A run on every activation would hammer Moxfield on each rebuild.
  systemd.services.moxfield-sync = {
    description = "Sync Moxfield decks → ShowMyCards lists, and export Moxfield-importable files";
    after = [ "showmycards-proxy.socket" "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.python3 ];
    environment = {
      MOXFIELD_DECK_IDS = lib.concatStringsSep "," deckIds;
      # Honest, identifiable UA with a contact route, rather than impersonating a
      # browser: if Moxfield want this traffic gone they should be able to see who
      # it is and tell us.
      MOXFIELD_USER_AGENT = "nic-os-moxfield-sync/1.0 (self-hosted personal ShowMyCards sync; +https://github.com/nSimonFR/nic-os)";
      # :8330 is the socket-activation proxy — the ONLY address that wakes the
      # sleeping backend. :13344 cold is connection-refused.
      SMC_API = "http://127.0.0.1:8330/api";
      SMC_DB = "/mnt/data/showmycards/database.db";
      EXPORT_DIR = exportDir;
      STATE_DIR = stateDir;
      # Ships dry-run. Flip to "0" after one clean run has been eyeballed —
      # the first live run is what deletes list items, so it earns a look first.
      DRY_RUN = "1";
    };
    serviceConfig = {
      Type = "oneshot";
      # Runs as showmycards for read access to the 0750 sqlite DB (read-only, for
      # oracle_id lookups the API cannot do) and write access to the export dir.
      User = "showmycards";
      Group = "showmycards";
      StateDirectory = "moxfield-sync";
      ExecStart = "${pkgs.python3}/bin/python3 ${./scripts/moxfield-sync.py}";
    };
  };

  systemd.timers.moxfield-sync = {
    description = "Daily Moxfield → ShowMyCards deck sync";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 05:20:00"; # after the backup window, before the morning
      Persistent = true;             # catch up a missed run if the Pi was off
      RandomizedDelaySec = "10m";    # don't hit Moxfield at a predictable instant
    };
  };
}
