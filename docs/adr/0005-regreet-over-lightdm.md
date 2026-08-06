# 0005 — ReGreet over LightDM on BeAsT

**Date:** 2026-08-06 (decision itself predates this record) · **Status:** Accepted

## Context

`nixos/configuration.nix` carried a `useLightdm` toggle, hard-set to `false`, and
kept both display-manager configurations behind it — ReGreet at `enable =
!useLightdm`, LightDM at `enable = useLightdm`. The LightDM branch was 42 lines of
GTK greeter theming, fonts, indicator layout and an onboard keyboard setting, all
dead.

LightDM was originally kept because it "supports both X11 and Wayland sessions".
In practice BeAsT runs Hyprland on Wayland only, and the greeter is launched
through `dbus-run-session Hyprland` specifically so `hypridle` can blank the
monitors after 5 minutes — that DPMS-off-after-idle behaviour is the point (it is
what makes wake-on-LAN power saving work) and it is not reachable via LightDM.

## Decision

Deleted the LightDM branch and the `useLightdm` toggle. ReGreet is enabled
unconditionally.

## Consequences

- `services.xserver.enable = true` is **retained**, with its comment corrected.
  It is required by the NVIDIA driver setup (`services.xserver.videoDrivers`), not
  by LightDM. Removing it alongside the greeter would have been the easy mistake
  here.
- Reverting means re-adding a `services.xserver.displayManager.lightdm` block from
  scratch. The deleted theming is recoverable from git history at `157a25e~`.
- One fewer branch that looks configurable but has exactly one reachable value.

The toggle is worth calling out as an anti-pattern: a `let`-bound boolean with a
single hard-coded value reads as a supported configuration axis. It was not one —
the greeter command at `services.greetd.settings.default_session.command` is
`lib.mkForce`d to Hyprland regardless, so flipping `useLightdm` to `true` would
have produced a broken login screen, not a LightDM one.
