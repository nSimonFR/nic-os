# rpi5/lib/heavy-services.nix
#
# The heaviest userspace app services, heaviest → lightest. Stopped before a
# memory-hungry `nixos-rebuild` so the 4 GiB (really ~3.9 GiB) Pi keeps the
# ~1 GiB of headroom it needs to avoid zram thrashing and a watchdog reset.
#
# Socket-activated ones (gramps-web, reactive-resume, beaverhabits, airtrail,
# papra, wakapi, forgejo, sure, vaultwarden) free their RSS here and re-activate
# on demand via their .socket; always-on ones are restarted by the activation
# phase of `nixos-rebuild switch`. Infra (tailscaled, nginx, postgresql, redis,
# blocky) is deliberately left running.
#
# Shared by `nixos-rebuild-safe` (configuration.nix) and the weekly auto-upgrade
# (auto-upgrade.nix) — edit the list here, both pick it up.
[
  "immich-server.service"
  "home-assistant.service"
  "reactive-resume.service"
  "dawarich-sidekiq-all.service"
  "dawarich-web.service"
  "affine.service"
  "affine-mcp.service"
  "sure-worker.service"
  "sure-web.service"
  "gramps-web.service"
  "gramps-web-celery.service"
  "ryot-backend.service"
  "ryot-frontend.service"
  "beaverhabits.service"
  "airtrail.service"
  "papra.service"
  "forgejo.service"
  "wakapi.service"
  "vaultwarden.service"
  "homepage-dashboard.service"
  "homepage-stats.service"
]
