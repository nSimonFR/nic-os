# nic-os domain glossary

The words this repo uses for its own concepts. `CLAUDE.md` says what to *do*;
this file says what things *are*. If a term here stops matching the code, fix
one of the two.

## Hosts

**host** — one machine with a NixOS/nix-darwin config: `rpi5` (the always-on
ARM server, 3.9 GB RAM), `BeAsT` (x86 workstation), `nBookPro` (Mac). Named
directories under `hosts/`.

**capability** — what a host *can do*, as opposed to what it is called:
`isGraphical`, `runsStarCitizen`, `has16KPages`. Declared once per host in
`flake.nix` and branched on by modules, so a fourth host is a new row rather
than a new string compare in every module. See
`docs/adr/0008-host-capabilities-over-hostnames.md`.

## Services

**service** — one registered unit of function on the rpi5, keyed by attr name
under `nic.services.<name>` (`hosts/rpi5/lib/service-registration.nix`). It
owns *every* fact about itself: how its state reaches Storj, which of its units
are heavy, and its public face. Central lists are derived from these
registrations, never maintained by hand.

**heavy unit** — a systemd unit that `nixos-rebuild-safe` stops to free RSS
before a build, because the Pi has 3.9 GB and a build that thrashes takes the
box down with a watchdog reset. Declared per service as `heavyUnits`, ordered by
`heavyPriority` (ascending, heaviest first). Infrastructure — tailscaled, nginx,
postgresql, redis, blocky — is deliberately never heavy: stopping it breaks the
rebuild doing the stopping.

**socket-activate** — putting a service behind `systemd-socket-proxyd
--exit-idle-time` so it runs only while traffic flows and returns to ~0 RAM at
rest (`hosts/rpi5/lib/socket-activate.nix`). A **ready probe** gates the first
request for stacks (Rails, gunicorn) that bind their port well after systemd
calls the unit active.

**pgRole** — a service's Postgres database, role, password and extensions, as
one declaration (`hosts/rpi5/lib/pg-role.nix`).

## The public face

**public face** — a service's reachable-from-outside surface: `port`, `backend`,
whether it is *served* or *funnelled*, whether it is *proxied*, and its
dashboard tile. `nic.services.<name>.public`, or null for a service that
registers for backup without being reachable.

**serve** vs **funnel** — `tailscale serve` publishes on the tailnet only;
`tailscale funnel` publishes to the public internet. Tailscale permits funnels
on ports 443, 8443 and 10000 only, and all three are allocated (the front proxy,
AFFiNE, Immich).

**front proxy** / **path-mux** — the single nginx vhost behind the one public 443
funnel, which routes by path prefix so several services can be public without a
fourth funnel port (`hosts/rpi5/front-proxy.nix`).

**proxied** — fronted by the path-mux rather than holding a port of its own. No
serve/funnel command is emitted for a proxied service; a second bind on 443
would conflict.

**muxPath** — the prefix under which the path-mux fronts a proxied service
(`/sure`, `/ryot`). Routing, and asserted to have a matching nginx location.
Distinct from **deepLink**, which is cosmetic — it only moves where a tile
points, and applies to services on their own port.

**publicUrl** — derived, read-only: the URL a service is reachable at. `:port`
omitted on 443, `muxPath` folded in. Read this from the owning module for its
own `origin` / `APP_URL` / `NEXTAUTH_URL` instead of rebuilding the string.

**tile** — a service's card on the homepage dashboard: name, icon, category,
description, and optionally a **widget**. Optional — omit it and the service is
routed but renders nothing.

**widget** — three numbers on a tile. Always a `customapi` pointed at the
homepage-stats **aggregator** on :8087, never at the service itself: the
aggregator fetches once a day and reads databases directly where it can, so
polling never wakes a socket-activated service and no credential sits in the
tile config.

## Agents

**skill** — a *directory*: `SKILL.md` plus whatever it needs at runtime
(`assets/`, `references/`, `scripts/`). The directory is the unit, never the
`SKILL.md` alone.

**lineage** — a directory whose immediate children are skills. Four exist:
`shared/skills`, `shared/mtg-skills`, `hosts/rpi5/hermes/skills`,
`home/claude-skills`.

**surface** — an agent installation with its own skills directory (Claude Code,
Codex, pi, Hermes, `claude-mtg`). One builder fans a lineage out to every
surface: `shared/skill-tree.nix`.

## Notification

Three seams, picked by lifecycle, not by convenience (`shared/notify.nix`):

**alert** — a condition that fires and later *clears*. One self-updating message
per incident: send once, edit in place, count occurrences, auto-resolve.

**send** — a one-shot event with no resolved state. Routing one of these through
`alert` leaves a message stuck at "⚠ ongoing" forever.

**agent** — agent chatter that should batch. POSTs to the :8088 aggregator, which
owns the token and the debouncing. Routing a pre-reboot ping through this
debounces it for up to 15 minutes.
