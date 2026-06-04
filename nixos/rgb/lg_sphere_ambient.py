#!/usr/bin/env python3
"""LG 38GN950 sphere-lighting ambient sync daemon."""
import argparse, os, signal, sys, time, logging
import numpy as np
import hid
import lib27gn950 as lg
from screencopy import Screencopy

log = logging.getLogger('lg-sphere-ambient')

# 48 LED zones around the sphere: top16 + right8 + bottom16 + left8
N_TOP, N_SIDE, BAND = 16, 8, 4

# ------------------------------------------------------------------
# Optional OpenRGB sink — picks up the same sampled frame and pushes a
# single averaged colour to whichever device classes are enabled.
class OpenRGBSink:
    # ~5s minimum between reconnect attempts so a dead server doesn't
    # spam the log or stall the main capture loop.
    RECONNECT_BACKOFF = 5.0

    def __init__(self, host, port, allowed_types, zone_sizes, perled_specs,
                 perled_reverse, gpu_logo_threshold):
        """zone_sizes:     [(device_type, zone_name, led_count)] resized on connect.
        perled_specs:  [(device_type, zone_name)] zones that take per-LED ambilight
                       colours (Hyperion-style strip mapping) instead of the single
                       global colour. Anything not listed gets the global colour.
        gpu_logo_threshold: luminance below this turns the GPU SINGLE COLOR zone off."""
        self.host = host; self.port = port
        self.allowed = set(t.lower() for t in allowed_types)
        self.zone_sizes = zone_sizes
        self.perled_specs = set((d.lower(), z) for d, z in perled_specs)
        self.perled_reverse = set((d.lower(), z) for d, z in perled_reverse)
        self.gpu_logo_threshold = gpu_logo_threshold
        self.client = None
        self.devices = []
        self.last_attempt = 0.0
        # Dedup state and zone plan are keyed by id(dev) because some
        # multi-stick setups (Corsair DRAM ×2 in this build) expose the
        # SAME .name AND empty .serial — keying by name would collide
        # and silently make one of the sticks stop updating.
        self.last_dev_colors = {}  # {id(dev): [(r,g,b), ...]}
        self._zone_plan = {}       # {id(dev): [(zone_name, led_count, is_perled), ...]}

    def _apply_zone_sizes(self):
        """Make sure ARGB headers (etc.) are sized to what's physically wired."""
        if not self.zone_sizes:
            return
        changed = False
        for d in self.client.devices:
            for dtype, zname, n in self.zone_sizes:
                if d.type.name.lower() != dtype.lower(): continue
                for z in d.zones:
                    if z.name != zname: continue
                    if len(z.leds) == n: continue
                    try:
                        z.resize(n)
                        log.info("resized %s / %s: -> %d LEDs", d.name, zname, n)
                        changed = True
                    except Exception as e:
                        log.warning("resize %s/%s -> %d failed: %s", d.name, zname, n, e)
        if changed:
            # refresh device snapshots so device.leds reflects new sizes
            self.client.update()

    def _build_state(self, initial=False):
        """(Re)populate self.devices / self._zone_plan from
        self.client.devices and force every in-scope device into Direct
        mode. Used by both _connect() (first time) and rescan() (after a
        hotplug). Drops dedup state so the next push re-asserts colours."""
        self.devices = [
            d for d in self.client.devices
            if d.type.name.lower() in self.allowed
        ]
        for d in self.devices:
            self._force_direct_mode(d)
        self._zone_plan = {}
        self.last_dev_colors = {}
        perled_count = 0
        for d in self.devices:
            plan = []
            for z in d.zones:
                key = (d.type.name.lower(), z.name)
                is_perled = key in self.perled_specs and len(z.leds) > 0
                plan.append((z.name, len(z.leds), is_perled))
                if is_perled: perled_count += 1
            self._zone_plan[id(d)] = plan
        verb = "connected" if initial else "rescan"
        log.info("openrgb %s — %d/%d devices in scope: %s", verb,
                 len(self.devices), len(self.client.devices),
                 [d.name for d in self.devices])
        if perled_count:
            log.info("openrgb per-LED zones (ambilight): %s",
                     self.get_perled_info())

    def rescan(self):
        """Re-enumerate devices from the OpenRGB server. Picks up hot-
        plugged hardware (e.g. a controller plugged into USB) and rebuilds
        scope + zone plan when the device set changed. Cheap on the
        steady-state path: when nothing changed it's a single
        REQUEST_CONTROLLER_COUNT round-trip plus colour syncs."""
        if self.client is None:
            return
        try:
            # Snapshot the current scope-device id set so we can tell if
            # the SDK rebuilt the device list under us. client.update()
            # is the only public API that fans out DEVICE_LIST_UPDATED.
            old_ids = tuple(id(d) for d in self.devices)
            old_names = tuple(d.name for d in self.devices)
            self.client.update()
            new_ids = tuple(
                id(d) for d in self.client.devices
                if d.type.name.lower() in self.allowed
            )
            new_names = tuple(
                d.name for d in self.client.devices
                if d.type.name.lower() in self.allowed
            )
            # When the underlying SDK rebuilds the device list, every
            # Device object's id() changes even for unchanged hardware,
            # so we also compare device names. If neither changed we
            # short-circuit and keep dedup state.
            if old_ids == new_ids and old_names == new_names:
                return
            self._build_state(initial=False)
        except Exception as e:
            log.warning("openrgb rescan failed: %s", e)
            # Force a clean reconnect on the next push.
            self.client = None
            self.devices = []
            self._zone_plan = {}
            self.last_dev_colors = {}

    def _force_direct_mode(self, dev):
        """Many devices (G502, ASUS mb) default to 'Off' / a pattern mode that
        silently overrides per-LED writes. Force 'Direct' if the device has it."""
        mode_names = [m.name for m in dev.modes]
        if 'Direct' not in mode_names:
            return
        cur = mode_names[dev.active_mode] if dev.modes else None
        if cur == 'Direct':
            return
        try:
            dev.set_mode('Direct')
            log.info("switched %s from %r to Direct mode", dev.name, cur)
        except Exception as e:
            log.warning("set_mode Direct on %s failed: %s", dev.name, e)

    def _connect(self):
        now = time.monotonic()
        if now - self.last_attempt < self.RECONNECT_BACKOFF:
            return False
        self.last_attempt = now
        try:
            from openrgb import OpenRGBClient
            self.client = OpenRGBClient(self.host, self.port, name="lg-sphere-ambient")
            self._apply_zone_sizes()
            self._build_state(initial=True)
            return True
        except Exception as e:
            log.warning("openrgb connect failed: %s", e)
            self.client = None; self.devices = []
            return False

    def get_perled_info(self):
        """Returns [(device_name, zone_name, led_count), ...] for every
        zone currently slated for per-LED (ambilight) sampling. The main
        loop walks this list each frame to build the per-LED colour
        vectors before calling push()."""
        out = []
        for d in self.devices:
            for (zname, n, is_perled) in self._zone_plan.get(id(d), []):
                if is_perled and n > 0:
                    out.append((d.name, zname, n))
        return out

    def get_perled_reverse_set(self):
        """Resolves --openrgb-perled-reverse from (device_type, zone_name)
        to {(device_name, zone_name), ...} using the current device list.
        Passed straight into sample_perled_zones() to flip LED order on
        zones whose cable enters from the opposite side."""
        out = set()
        for d in self.devices:
            for z in d.zones:
                if (d.type.name.lower(), z.name) in self.perled_reverse:
                    out.add((d.name, z.name))
        return out

    def push(self, rgb, perled=None, min_delta=4):
        """Push one frame of colour to every in-scope device.

        rgb:    global (r,g,b) tuple — fills any zone NOT in perled_specs.
        perled: {(device_name, zone_name): [(r,g,b), ...]} per-LED vectors
                for the zones marked as ambilight strips. The vector
                length must equal the zone's LED count or it's discarded.

        For every device we build ONE colour vector that covers every LED
        in device order — non-perled zones repeat the global colour,
        perled zones drop in their per-LED data — and push it with a
        single dev.set_colors() call. Same wire cost as the old
        set_color() (one packet per device) but per-LED zones now carry
        spatial information from the screen, which both looks like
        Ambilight and hides per-frame jitter (a small change in one LED
        no longer pulses the whole device).

        Dedup is per device on the full colour vector: if the new vector
        is within min_delta of the last one sent, we skip the packet
        entirely. min_delta=4 ≈ imperceptible.
        """
        from openrgb.utils import RGBColor
        if self.client is None and not self._connect():
            return
        perled = perled or {}
        r, g, b = rgb
        global_col = RGBColor(r, g, b)
        # ITU-R BT.601 luma — gates the GPU's SINGLE COLOR zone (the FE
        # GeForce side logo can only do on/off in hardware).
        lum = (299*r + 587*g + 114*b) // 1000
        on  = RGBColor(255, 255, 255)
        off = RGBColor(0, 0, 0)
        gate = on if lum >= self.gpu_logo_threshold else off
        dead = []
        for dev in self.devices:
            plan = self._zone_plan.get(id(dev))
            if not plan: continue
            # Assemble the per-LED tuple vector in device-LED order.
            colors = []
            gpu_single = (dev.type.name == 'GPU')
            for (zname, n, is_perled) in plan:
                if n == 0: continue
                key = (dev.name, zname)
                if is_perled and key in perled and len(perled[key]) == n:
                    colors.extend(perled[key])
                elif gpu_single and 'SINGLE' in zname.upper():
                    gv = (255,255,255) if gate is on else (0,0,0)
                    colors.extend([gv] * n)
                else:
                    colors.extend([(r, g, b)] * n)
            if not colors: continue
            # Vector dedup — channel-max-abs over every LED.
            prev = self.last_dev_colors.get(id(dev))
            if prev is not None and len(prev) == len(colors):
                md = 0
                for (nr,ng,nb),(pr,pg,pb) in zip(colors, prev):
                    d_ = max(abs(nr-pr), abs(ng-pg), abs(nb-pb))
                    if d_ > md: md = d_
                    if md >= min_delta: break
                if md < min_delta:
                    continue
            try:
                dev.set_colors([RGBColor(*c) for c in colors], fast=True)
                self.last_dev_colors[id(dev)] = colors
            except Exception as e:
                log.warning("openrgb device %s failed: %s", dev.name, e)
                dead.append(dev)
        if dead:
            self.devices = [d for d in self.devices if d not in dead]
            if not self.devices:
                self.client = None

    def stop(self):
        try:
            if self.client: self.client.disconnect()
        except Exception: pass

def find_wayland_socket():
    """If WAYLAND_DISPLAY isn't set, look in XDG_RUNTIME_DIR."""
    if os.environ.get('WAYLAND_DISPLAY'):
        return
    runtime = os.environ.get('XDG_RUNTIME_DIR')
    if not runtime:
        return
    for entry in sorted(os.listdir(runtime)):
        if entry.startswith('wayland-') and not entry.endswith('.lock'):
            path = os.path.join(runtime, entry)
            try:
                if os.path.exists(path):
                    os.environ['WAYLAND_DISPLAY'] = entry
                    log.info("auto-detected WAYLAND_DISPLAY=%s", entry)
                    return
            except OSError:
                continue

# ------------------------------------------------------------------
# Colour-extraction algorithms.
#
# MEAN: plain BGR→RGB mean of edge pixels. Washes out — a desktop with
# mostly dark wallpaper plus one small saturated accent averages to
# near-grey. What every naive ambient-light tutorial does.
#
# HUE-HISTOGRAM: importance-weighted 16-bin hue histogram, Cornell ECE
# 5760 (Velleleth 2016). Per pixel: importance = (1 − |L − 0.5|·2) · S,
# so dark/bright/grey pixels weigh ~0 and only mid-luma saturated
# pixels vote. Heaviest hue bin wins; output is a fully saturated
# version at the importance-weighted lightness. Vivid colour even when
# the screen is mostly dark wallpaper — the only thing voting is the
# small saturated accent. Falls back to mean grey when no pixel has
# any saturation at all.

NBINS = 16

def rgb_to_hsl(rgb_u8):
    # rgb_u8: (..., 3) uint8 → H,S,L floats in [0,1]
    rgb = rgb_u8.astype(np.float32) / 255.0
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    cmax = np.maximum(np.maximum(r, g), b)
    cmin = np.minimum(np.minimum(r, g), b)
    d = cmax - cmin
    L = (cmax + cmin) * 0.5
    denom = np.where(L < 0.5, cmax + cmin, 2.0 - cmax - cmin)
    S = np.where(d == 0, 0.0, d / np.maximum(denom, 1e-9))
    H = np.zeros_like(L)
    mask = d > 0
    # use np.where so we don't divide by zero
    rc = (cmax - r) / np.where(d == 0, 1, d)
    gc = (cmax - g) / np.where(d == 0, 1, d)
    bc = (cmax - b) / np.where(d == 0, 1, d)
    H = np.where(cmax == r, bc - gc, H)
    H = np.where(cmax == g, 2.0 + rc - bc, H)
    H = np.where(cmax == b, 4.0 + gc - rc, H)
    H = (H / 6.0) % 1.0
    H = np.where(mask, H, 0.0)
    return H, S, L

def hsl_to_rgb(h, s, l):
    # scalars → (r, g, b) uint8
    def hue2rgb(p, q, t):
        t = t % 1.0
        if t < 1/6: return p + (q - p) * 6 * t
        if t < 1/2: return q
        if t < 2/3: return p + (q - p) * (2/3 - t) * 6
        return p
    if s == 0:
        v = int(round(l * 255))
        return v, v, v
    q = l * (1 + s) if l < 0.5 else l + s - l * s
    p = 2 * l - q
    r = hue2rgb(p, q, h + 1/3)
    g = hue2rgb(p, q, h)
    b = hue2rgb(p, q, h - 1/3)
    return int(round(r*255)), int(round(g*255)), int(round(b*255))

def pick_color_mean(pixels_bgr):
    if pixels_bgr.size == 0: return (0, 0, 0)
    m = pixels_bgr.reshape(-1, 3).mean(axis=0)
    return (int(m[2]), int(m[1]), int(m[0]))   # BGR → RGB

def pick_color_hue_histogram(pixels_bgr):
    if pixels_bgr.size == 0: return (0, 0, 0)
    # BGR → RGB before HSL
    flat = pixels_bgr.reshape(-1, 3)[:, ::-1]
    H, S, L = rgb_to_hsl(flat)
    importance = (1.0 - np.abs(L - 0.5) * 2.0) * S
    total = importance.sum()
    if total < 1.0:
        # ~no saturation: fall back to plain mean (will be grey-ish)
        return pick_color_mean(pixels_bgr)
    bins = (H * NBINS).astype(np.int32) % NBINS
    weights = np.bincount(bins, weights=importance, minlength=NBINS)
    winner = int(weights.argmax())
    winner_hue = (winner + 0.5) / NBINS
    # importance-weighted lightness, clamped: never pure black (we lose
    # the colour), never pure white (washes out the hue).
    w = importance + 1e-6
    final_L = float(np.clip((L * w).sum() / w.sum(), 0.15, 0.55))
    return hsl_to_rgb(winner_hue, 1.0, final_L)

# 2 = every other pixel along both axes → 4× fewer pixels through the
# HSL conversion. Edge bands are tiny and have huge spatial redundancy;
# this is loss-free for the histogram (which counts hue bins, not pixels).
SS = 2

def sample_zones(mm, w, h, stride, algo='hue-histogram'):
    pick = pick_color_hue_histogram if algo == 'hue-histogram' else pick_color_mean
    a = np.frombuffer(mm, dtype=np.uint8, count=stride*h).reshape(h, stride//4, 4)
    a = a[:, :w]
    out = []
    band = a[:BAND:1, ::SS, :3]
    for k in range(N_TOP):
        x0 = (k*w//N_TOP)//SS; x1 = ((k+1)*w//N_TOP)//SS
        out.append(pick(band[:, x0:x1]))
    band = a[::SS, w-BAND::1, :3]
    for k in range(N_SIDE):
        y0 = (k*h//N_SIDE)//SS; y1 = ((k+1)*h//N_SIDE)//SS
        out.append(pick(band[y0:y1]))
    band = a[h-BAND::1, ::SS, :3]
    for k in range(N_TOP):
        x0 = (k*w//N_TOP)//SS; x1 = ((k+1)*w//N_TOP)//SS
        out.append(pick(band[:, x0:x1]))
    band = a[::SS, :BAND:1, :3]
    for k in range(N_SIDE):
        y0 = (k*h//N_SIDE)//SS; y1 = ((k+1)*h//N_SIDE)//SS
        out.append(pick(band[y0:y1]))
    return [f"{r:02x}{g:02x}{b:02x}" for r,g,b in out]

# Whole-screen subsample stride for pick_global_color. 16× on each axis
# = 240×100 = 24k pixels on the 3840×1600 LG output, same ballpark as the
# edge sample so CPU is unchanged but the dominant-hue vote now comes
# from EVERY pixel on the screen, not just the bezel-adjacent ones.
SS_GLOBAL = 16

# Per-LED ambilight uses a wider band than the LG ring — a single LED
# on a 24-LED strip covers ~160 px of screen width, and a 4-px band is
# too thin to be representative. 64 px ≈ 4% of screen height, matches
# what Hyperion uses by default.
PERLED_BAND = 64

def sample_perled_zones(mm, w, h, stride, specs, reverse_set=None):
    """Hyperion-style per-LED ambilight sampling for OpenRGB strips.

    specs: [(device_name, zone_name, led_count), ...] from OpenRGBSink.
    reverse_set: set of (device_name, zone_name) tuples for which to flip
                 the LED order (use when the strip's cable enters on the
                 right side of the case, so OpenRGB's LED 0 is physically
                 on the right rather than the left).
    Returns {(device_name, zone_name): [(r,g,b), ...]} with len == led_count.

    Each LED samples a rectangle MEAN colour from its slice of the
    bottom PERLED_BAND pixels of the screen. We use the mean (not the
    hue-histogram) here because the per-LED rectangles are small enough
    (~80×32 px subsampled) that the histogram's winning-bin would jitter
    between neighbours. Mean is what Hyperion uses for ambilight strips
    and gives smooth left-to-right gradients.
    """
    if not specs: return {}
    reverse_set = reverse_set or set()
    a = np.frombuffer(mm, dtype=np.uint8, count=stride*h).reshape(h, stride//4, 4)
    a = a[:, :w]
    band = a[h-PERLED_BAND::SS, ::SS, :3]  # (band_h, bw, 3) BGR
    bw = band.shape[1]
    out = {}
    for (dev_name, zone_name, n) in specs:
        group = bw // n
        if group >= 1:
            # Vectorised mean: reshape the band into (band_h, n, group, 3)
            # then reduce over band_h and group in one numpy op. About
            # 30× faster than the per-LED Python loop, which dominated
            # CPU at 30 Hz sampling with 32 total per-LED zones.
            trim = group * n
            mean_bgr = band[:, :trim, :].reshape(-1, n, group, 3).mean(axis=(0, 2))
            colors = [(int(c[2]), int(c[1]), int(c[0])) for c in mean_bgr]
        else:
            # More LEDs than band columns — degenerate, fall back to
            # the slow path. Won't happen with current PERLED_BAND/SS.
            colors = []
            for k in range(n):
                x0 = (k * bw) // n
                x1 = max(x0 + 1, ((k+1) * bw) // n)
                m = band[:, x0:x1].reshape(-1, 3).mean(axis=0)
                colors.append((int(m[2]), int(m[1]), int(m[0])))
        if (dev_name, zone_name) in reverse_set:
            colors.reverse()
        out[(dev_name, zone_name)] = colors
    return out

def pick_global_color(mm, w, h, stride, algo='hue-histogram'):
    """One colour for the whole screen — used by the OpenRGB fan-out.

    Samples a heavily-subsampled grid of the entire framebuffer (not
    just the edges) so the dominant-hue vote reflects whatever is
    on-screen, not just the 4-px band touching the bezel. The
    hue-histogram's importance weighting (mid-luma · saturation) takes
    care of the rest — a mostly-grey desktop with a small saturated
    accent will still resolve to that accent's hue.
    """
    pick = pick_color_hue_histogram if algo == 'hue-histogram' else pick_color_mean
    a = np.frombuffer(mm, dtype=np.uint8, count=stride*h).reshape(h, stride//4, 4)
    a = a[:, :w]
    # whole-screen strided view → (h/SS_GLOBAL, w/SS_GLOBAL, 3) BGR pixels
    pixels = a[::SS_GLOBAL, ::SS_GLOBAL, :3].reshape(-1, 3)
    return pick(pixels)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--output', default='DP-1', help='wayland output name')
    ap.add_argument('--fps', type=int, default=30, help='sampler/push rate cap')
    ap.add_argument('--brightness', type=int, default=12, choices=range(1, 13))
    ap.add_argument('--cursor', action='store_true', help='include cursor in capture')
    ap.add_argument('--debug', action='store_true')
    ap.add_argument('--openrgb', action='store_true', help='also push averaged colour to OpenRGB SDK')
    ap.add_argument('--openrgb-host', default='127.0.0.1')
    ap.add_argument('--openrgb-port', type=int, default=6742)
    # DRAM and motherboard by default; gamepad is opt-in because pushing
    # ambient over the DualSense lightbar can fight with the game.
    ap.add_argument('--openrgb-devices', default='dram,motherboard',
                    help='comma-separated device types: dram,motherboard,gamepad,keyboard,mouse,headset,all')
    ap.add_argument('--openrgb-zone-sizes', default="",
                    help='comma-separated zone size specs: device_type/Zone Name=N,...  '
                         '(applied on every OpenRGB connect; idempotent)')
    ap.add_argument('--openrgb-perled-zones',
                    default='motherboard/Aura Addressable 1,motherboard/Aura Addressable 3',
                    help='comma-separated device_type/Zone Name list. These zones get '
                         'Hyperion-style per-LED ambilight colours sampled across the bottom '
                         'of the screen instead of the single global colour. All other zones '
                         'still get the global colour. Empty string disables per-LED entirely.')
    ap.add_argument('--openrgb-perled-reverse', default="",
                    help='comma-separated device_type/Zone Name list whose LED order should '
                         'be reversed (use when the cable enters on the right of the case so '
                         'OpenRGB LED 0 is physically the rightmost LED).')
    ap.add_argument('--gpu-logo-threshold', type=int, default=30,
                    help='luma (0-255) below which the GPU SINGLE COLOR zone (the FE GeForce '
                         'side logo) is turned off. Default 30 ~ typical dark desktop')
    ap.add_argument('--algo', default='hue-histogram', choices=['mean','hue-histogram'],
                    help='colour-extraction algorithm. mean = plain edge-band average; '
                         'hue-histogram = Cornell-style importance-weighted hue histogram '
                         '(more saturated output, less washout on dark scenes). default hue-histogram.')
    ap.add_argument('--ema', type=float, default=0.25,
                    help='temporal smoothing on the algorithm output (per-zone and global): '
                         'new = ema*current + (1-ema)*prev. 0 = no smoothing, 1 = no history. '
                         'Default 0.25 means each push is ~25%% new + ~75%% the previous frame, '
                         'which kills the hue-bin-flip flashing on close-tie scenes without '
                         'feeling laggy on real scene cuts.')
    ap.add_argument('--capture-recycle', type=float, default=1.0,
                    help='tear down + recreate the wlr-screencopy session every N seconds '
                         'to defeat Hyprland fullscreen-mode-2 stale-buffer lock. '
                         '0 = never recycle. default 1.0s (bounds staleness to <= 1s).')
    ap.add_argument('--openrgb-rescan-interval', type=float, default=10.0,
                    help='seconds between OpenRGB device-list rescans. Catches hot-plugged '
                         'controllers without restarting the daemon. 0 to disable.')
    ap.add_argument('--openrgb-fps', type=float, default=10.0,
                    help='OpenRGB push rate (Hz). The 6 device set_color calls per frame at '
                         'the full 30 fps can race on the OpenRGB server with fast=True; lower '
                         'rates also stop hardware controllers (Corsair RAM, ASUS Aura) from '
                         'visibly flickering when re-asserted to near-equal colours. '
                         'Default 10 Hz. Set higher for snappier sync to fast scene cuts.')
    args = ap.parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format='%(asctime)s %(levelname)s %(message)s',
    )
    find_wayland_socket()

    stop = [False]
    def on_signal(sig, frame):
        log.info("signal %d, shutting down", sig); stop[0] = True
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    # Wait for the monitor to be present (e.g. early in boot, USB not ready)
    dev = None
    while not stop[0]:
        mons = lg.find_monitors()
        if mons:
            try:
                dev = hid.Device(path=mons[0]['path'])
                log.info("opened %s serial=%s", mons[0]['model'], mons[0]['serial'])
                break
            except Exception as e:
                log.warning("hid open failed: %s", e)
        log.info("no LG monitor on USB, retrying...")
        time.sleep(5)
    if stop[0]: return 0

    cap = Screencopy(output_name=args.output, overlay_cursor=1 if args.cursor else 0)
    try:
        cap.start()
    except Exception as e:
        log.error("screencopy failed to start: %s", e)
        return 1

    lg.send_command(lg.control_commands['color_video_sync'], dev)
    lg.send_command(lg.brightness_commands[args.brightness], dev)
    log.info("ambient loop running at %d fps target on %s", args.fps, args.output)

    # Optional OpenRGB fan-out
    orgb = None
    if args.openrgb:
        allowed = [t.strip() for t in args.openrgb_devices.split(',') if t.strip()]
        if 'all' in allowed:
            # Every OpenRGB DeviceType. Keep in sync with openrgb.utils.DeviceType —
            # adding a new type means anything hot-plugged of that class joins the
            # ambient sync automatically without a flag change.
            allowed = ['motherboard','dram','gpu','cooler','ledstrip','keyboard',
                       'mouse','mousemat','headset','headset_stand','gamepad','light',
                       'speaker','virtual','storage','case','microphone','accessory',
                       'keypad','unknown']
        zone_sizes = []
        for spec in args.openrgb_zone_sizes.split(','):
            spec = spec.strip()
            if not spec: continue
            try:
                lhs, n = spec.rsplit('=', 1)
                dtype, zname = lhs.split('/', 1)
                zone_sizes.append((dtype.strip(), zname.strip(), int(n)))
            except Exception as e:
                log.error("bad --openrgb-zone-sizes entry %r: %s", spec, e)
        perled_specs = []
        for spec in args.openrgb_perled_zones.split(','):
            spec = spec.strip()
            if not spec: continue
            try:
                dtype, zname = spec.split('/', 1)
                perled_specs.append((dtype.strip(), zname.strip()))
            except Exception as e:
                log.error("bad --openrgb-perled-zones entry %r: %s", spec, e)
        perled_reverse = []
        for spec in args.openrgb_perled_reverse.split(','):
            spec = spec.strip()
            if not spec: continue
            try:
                dtype, zname = spec.split('/', 1)
                perled_reverse.append((dtype.strip(), zname.strip()))
            except Exception as e:
                log.error("bad --openrgb-perled-reverse entry %r: %s", spec, e)
        orgb = OpenRGBSink(args.openrgb_host, args.openrgb_port, allowed, zone_sizes,
                           perled_specs, perled_reverse, args.gpu_logo_threshold)

    log.info("colour algorithm: %s  ema=%.2f  capture-recycle=%.1fs  openrgb-fps=%.1f",
             args.algo, args.ema, args.capture_recycle, args.openrgb_fps)
    period = 1.0 / args.fps
    next_t = time.perf_counter()
    frame_idx = 0
    ema = args.ema
    prev_zones = None      # list of 48 (r,g,b) ints
    prev_global = None     # one (r,g,b)
    prev_perled = {}       # {(dev_name, zone_name): [(r,g,b), ...]}
    # OpenRGB rate limiting — independent of main fps so the LG ring keeps
    # its 30 fps per-zone sync while OpenRGB devices update at a saner
    # rate that doesn't race on the SDK server.
    orgb_period = 1.0 / args.openrgb_fps if args.openrgb_fps > 0 else 0
    next_orgb_t = 0.0
    # Hot-plug rescan timer — calls orgb.rescan() periodically so a
    # newly-plugged device shows up without restarting the daemon.
    rescan_period = args.openrgb_rescan_interval if args.openrgb_rescan_interval > 0 else 0
    next_rescan_t = time.perf_counter() + rescan_period if rescan_period else float('inf')
    # Periodic Screencopy recycle: Hyprland's wlr-screencopy implementation
    # locks long-lived clients to whatever frame was current when the
    # session started during fullscreen-mode-2 windows on the output. The
    # session is cheap to recreate (~ 1 ms), so we just tear it down and
    # rebuild every N seconds; fresh sessions always see live frames.
    last_recycle = time.perf_counter()
    try:
        while not stop[0]:
            if (args.capture_recycle > 0 and
                    time.perf_counter() - last_recycle > args.capture_recycle):
                try: cap.stop()
                except Exception as e: log.warning("cap.stop failed: %s", e)
                cap = Screencopy(output_name=args.output,
                                 overlay_cursor=1 if args.cursor else 0)
                cap.start()
                last_recycle = time.perf_counter()
            mm, w, h, stride = cap.next_frame()
            raw_zones = sample_zones(mm, w, h, stride, args.algo)
            # EMA in RGB space — kills the hue-bin flip-flopping that the
            # histogram does on close-tie scenes, at the cost of some
            # reactivity on fast cuts. New = ema * raw + (1-ema) * prev.
            if prev_zones is None or ema >= 1.0:
                smoothed_zones = raw_zones
            else:
                smoothed_zones = []
                for raw_hex, prev_rgb in zip(raw_zones, prev_zones):
                    r = int(raw_hex[0:2], 16); g = int(raw_hex[2:4], 16); b = int(raw_hex[4:6], 16)
                    nr = int(ema*r + (1-ema)*prev_rgb[0])
                    ng = int(ema*g + (1-ema)*prev_rgb[1])
                    nb = int(ema*b + (1-ema)*prev_rgb[2])
                    smoothed_zones.append(f"{nr:02x}{ng:02x}{nb:02x}")
            prev_zones = [(int(c[0:2],16), int(c[2:4],16), int(c[4:6],16)) for c in smoothed_zones]
            lg.send_video_sync_data(smoothed_zones, dev)

            if orgb is not None:
                if rescan_period and time.perf_counter() >= next_rescan_t:
                    orgb.rescan()
                    next_rescan_t = time.perf_counter() + rescan_period
                now = time.perf_counter()
                if now >= next_orgb_t:
                    # All OpenRGB-side work (global colour, per-LED
                    # ambilight, EMA, push) is gated by openrgb-fps. At
                    # the default 10 Hz this saves ~6% CPU vs sampling
                    # every frame and discarding most of it — the EMA
                    # now converges at the push rate (≈1.5s) instead of
                    # the capture rate (≈0.5s), which is fine for
                    # ambient. The LG ring still updates every frame.
                    raw_global = pick_global_color(mm, w, h, stride, args.algo)
                    if prev_global is None or ema >= 1.0:
                        push_color = raw_global
                    else:
                        push_color = (
                            int(ema*raw_global[0] + (1-ema)*prev_global[0]),
                            int(ema*raw_global[1] + (1-ema)*prev_global[1]),
                            int(ema*raw_global[2] + (1-ema)*prev_global[2]),
                        )
                    prev_global = push_color
                    perled_specs = orgb.get_perled_info()
                    perled_reverse_set = orgb.get_perled_reverse_set()
                    raw_perled = sample_perled_zones(mm, w, h, stride, perled_specs,
                                                     reverse_set=perled_reverse_set)
                    push_perled = {}
                    for key, raw_colors in raw_perled.items():
                        prev_colors = prev_perled.get(key)
                        if prev_colors is None or ema >= 1.0 or len(prev_colors) != len(raw_colors):
                            smoothed = raw_colors
                        else:
                            smoothed = [
                                (int(ema*r + (1-ema)*pr),
                                 int(ema*g + (1-ema)*pg),
                                 int(ema*b + (1-ema)*pb))
                                for (r,g,b),(pr,pg,pb) in zip(raw_colors, prev_colors)
                            ]
                        push_perled[key] = smoothed
                        prev_perled[key] = smoothed
                    orgb.push(push_color, push_perled)
                    next_orgb_t = now + orgb_period
                    frame_idx += 1
                    if args.debug and frame_idx % 20 == 0:
                        log.debug("pushed rgb=%s (raw=%s) zone0=%s zone16=%s perled_zones=%d",
                                  push_color, raw_global, smoothed_zones[0], smoothed_zones[16],
                                  len(push_perled))
            next_t += period
            sl = next_t - time.perf_counter()
            if sl > 0: time.sleep(sl)
            elif sl < -0.25:
                next_t = time.perf_counter()  # we fell behind; resync
    except Exception as e:
        log.error("loop crashed: %s", e); raise
    finally:
        try: lg.send_command(lg.control_commands['turn_off'], dev)
        except Exception: pass
        try: dev.close()
        except Exception: pass
        try: cap.stop()
        except Exception: pass
        if orgb is not None: orgb.stop()
        log.info("clean exit")
    return 0

if __name__ == '__main__':
    sys.exit(main())
