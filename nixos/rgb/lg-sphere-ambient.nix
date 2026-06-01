# LG 38GN950 sphere lighting — video-sync ambient lighting driven by
# wlr-screencopy frames sampled at the screen edges and pushed over USB HID.
#
# Reverse-engineered control protocol: lib27gn950 (subraizada3, MIT).
# Capture: native wlr-screencopy-unstable-v1 via pywayland (no ffmpeg).
{
  config,
  lib,
  pkgs,
  ...
}:

let
  python = pkgs.python3;

  # ------------------------------------------------------------------
  # Wayland protocol bindings, generated at build time so we don't ship
  # pre-generated python in the repo.
  pywaylandProtocols = pkgs.runCommand "pywayland-lg-protocols" {
    nativeBuildInputs = [ python.pkgs.pywayland pkgs.pkg-config pkgs.wayland-scanner ];
  } ''
    mkdir -p $out
    pywayland-scanner \
      -i ${pkgs.wayland-scanner}/share/wayland/wayland.xml \
         ${pkgs.wlr-protocols}/share/wlr-protocols/unstable/wlr-screencopy-unstable-v1.xml \
      -o $out
    touch $out/__init__.py
  '';

  # ------------------------------------------------------------------
  # lib27gn950 — minimal vendored copy of the HID command codec.
  # Upstream: https://github.com/subraizada3/27gn950controller (MIT)
  lib27gn950 = pkgs.writeText "lib27gn950.py" ''
    import hid

    control_commands = {
        'turn_on':          'f02020100de',
        'turn_off':         'f02020200dd',
        'color1':           'a02020301d8',
        'color2':           'a02020302db',
        'color3':           'a02020303da',
        'color4':           'a02020304dd',
        'color_peaceful':   'a02020305dc',
        'color_dynamic':    'a02020306df',
        'color_video_sync': 'a02020308d1',
    }
    brightness_commands = {
         1: 'f02020101df',  2: 'f02020102dc',  3: 'f02020103dd',  4: 'f02020104da',
         5: 'f02020105db',  6: 'f02020106d8',  7: 'f02020107d9',  8: 'f02020108d6',
         9: 'f02020109d7', 10: 'f0202010ad4', 11: 'f0202010bd5', 12: 'f0202010cd2',
    }

    def is_valid_monitor(vid, pid, usage_page):
        if vid == 0x043e and pid == 0x9a8a and usage_page == 0xff01:
            return '27GN950 / 38GN950'
        if vid == 0x043e and pid == 0x9a57:
            return '38GL950G'
        return False

    def find_monitors():
        out = []
        for d in hid.enumerate():
            model = is_valid_monitor(d['vendor_id'], d['product_id'], d['usage_page'])
            if model:
                out.append({'path': d['path'], 'serial': d['serial_number'], 'model': model})
        return out

    def calc_crc(data):
        data = bytearray.fromhex(data); crc = 0
        for bit in data:
            crc ^= bit
            for _ in range(8):
                crc <<= 1
                if crc & 0x100: crc ^= 0x101
        crc = hex(crc)[2:]
        return ('0' + crc) if len(crc) == 1 else crc

    def _send(s, dev):
        dev.write(int(s, 16).to_bytes(64, byteorder='big'))

    def send_command(cmd, dev):
        header = '5343c'; end = '4544'
        if type(cmd) == str: cmd = (cmd,)
        if not hasattr(dev, '__iter__'): dev = (dev,)
        for d in dev:
            for c in cmd:
                _send(header + c + end + '0'*(119-len(c)), d)

    def send_video_sync_data(colors, dev):
        if len(colors) != 48:
            raise ValueError('must provide 48 colors')
        # each RGB component must be at least 1 or the monitor can crash
        nc = []
        for c in colors:
            x = ""
            x += "01" if c[0]==c[1]=="0" else c[0:2]
            x += "01" if c[2]==c[3]=="0" else c[2:4]
            x += "01" if c[4]==c[5]=="0" else c[4:6]
            nc.append(x)
        cmd = "5343c1029100" + "".join(nc)
        cmd += calc_crc(cmd) + '4544'
        cmd1 = cmd[:128]; cmd2 = cmd[128:256]; cmd3 = cmd[256:] + '0'*78
        if not hasattr(dev, '__iter__'): dev = (dev,)
        for d in dev:
            _send(cmd1, d); _send(cmd2, d); _send(cmd3, d)
  '';

  # ------------------------------------------------------------------
  # Wayland screencopy client.
  screencopy = pkgs.writeText "screencopy.py" ''
    import os, mmap
    from pywayland.client import Display
    from protocols.wayland import WlShm, WlOutput
    from protocols.wlr_screencopy_unstable_v1 import ZwlrScreencopyManagerV1

    class Screencopy:
        def __init__(self, output_name, overlay_cursor=0):
            self.output_name = output_name
            self.overlay_cursor = overlay_cursor
            self.display = None; self.shm = None; self.scm = None
            self.target_output = None; self.outputs = []
            self.fd = None; self.mm = None; self.size = 0
            self.w = self.h = self.stride = self.fmt = 0
            self.wlbuf = None

        def start(self):
            self.display = Display(); self.display.connect()
            reg = self.display.get_registry()
            def on_global(r, name, iface, version):
                if iface == 'wl_shm':
                    self.shm = r.bind(name, WlShm, version)
                elif iface == 'wl_output':
                    out = r.bind(name, WlOutput, 4)
                    info = {'wl_output': out, 'name': None}
                    self.outputs.append(info)
                    out.dispatcher['name'] = lambda o, n, _i=info: _i.__setitem__('name', n)
                elif iface == 'zwlr_screencopy_manager_v1':
                    self.scm = r.bind(name, ZwlrScreencopyManagerV1, version)
            reg.dispatcher['global'] = on_global
            self.display.roundtrip(); self.display.roundtrip()
            for info in self.outputs:
                if info['name'] == self.output_name:
                    self.target_output = info['wl_output']; break
            if self.target_output is None:
                names = [i['name'] for i in self.outputs]
                raise RuntimeError(f"output {self.output_name!r} not found in {names}")

        def _alloc(self, w, h, stride, fmt):
            self.size = stride * h
            self.fd = os.memfd_create('lg-rgb-shm', os.MFD_CLOEXEC)
            os.ftruncate(self.fd, self.size)
            self.mm = mmap.mmap(self.fd, self.size)
            pool = self.shm.create_pool(self.fd, self.size)
            self.wlbuf = pool.create_buffer(0, w, h, stride, fmt)
            pool.destroy()
            self.w, self.h, self.stride, self.fmt = w, h, stride, fmt

        def next_frame(self):
            frame = self.scm.capture_output(self.overlay_cursor, self.target_output)
            info = {}
            frame.dispatcher['buffer'] = lambda f, fmt, w, h, stride: info.update(buf=(fmt, w, h, stride))
            frame.dispatcher['ready']  = lambda f, *_: info.update(ready=True)
            frame.dispatcher['failed'] = lambda f: info.update(failed=True)
            while 'buf' not in info and 'failed' not in info:
                self.display.dispatch(block=True)
            if 'failed' in info:
                frame.destroy(); raise RuntimeError('screencopy buffer negotiation failed')
            fmt, w, h, stride = info['buf']
            if self.wlbuf is None:
                self._alloc(w, h, stride, fmt)
            frame.copy(self.wlbuf)
            while 'ready' not in info and 'failed' not in info:
                self.display.dispatch(block=True)
            frame.destroy()
            if 'failed' in info: raise RuntimeError('screencopy frame failed')
            return self.mm, self.w, self.h, self.stride

        def stop(self):
            try:
                if self.wlbuf: self.wlbuf.destroy()
                if self.mm: self.mm.close()
                if self.fd: os.close(self.fd)
            finally:
                if self.display: self.display.disconnect()
  '';

  # ------------------------------------------------------------------
  # The ambient daemon.
  daemon = pkgs.writeText "lg_sphere_ambient.py" ''
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

        def __init__(self, host, port, allowed_types, zone_sizes, gpu_logo_threshold):
            """zone_sizes: list of (device_type, zone_name, led_count) tuples.
            gpu_logo_threshold: luminance below this turns the GPU SINGLE COLOR zone off."""
            self.host = host; self.port = port
            self.allowed = set(t.lower() for t in allowed_types)
            self.zone_sizes = zone_sizes
            self.gpu_logo_threshold = gpu_logo_threshold
            self.client = None
            self.devices = []
            self.last_attempt = 0.0
            self.last_push = None     # last (r,g,b) actually sent to devices

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
                self.devices = [
                    d for d in self.client.devices
                    if d.type.name.lower() in self.allowed
                ]
                for d in self.devices:
                    self._force_direct_mode(d)
                log.info("openrgb connected — %d/%d devices in scope: %s",
                         len(self.devices), len(self.client.devices),
                         [d.name for d in self.devices])
                return True
            except Exception as e:
                log.warning("openrgb connect failed: %s", e)
                self.client = None; self.devices = []
                return False

        def push(self, rgb, min_delta=4):
            """Push a colour to every in-scope device.

            Skips entirely when the requested rgb is within ``min_delta``
            (max per-channel) of the last successfully pushed value. RGB
            hardware controllers don't need to be re-asserted to the same
            colour 10× per second; skipping de-duplicated pushes cuts the
            wire traffic dramatically and removes the subtle blink some
            devices show when they're rapidly re-flashed with near-equal
            commands. min_delta=4 ≈ imperceptible colour delta.
            """
            from openrgb.utils import RGBColor
            if self.client is None and not self._connect():
                return
            r, g, b = rgb
            if self.last_push is not None:
                lr, lg, lb = self.last_push
                if max(abs(r-lr), abs(g-lg), abs(b-lb)) < min_delta:
                    return
            col = RGBColor(r, g, b)
            # ITU-R BT.601 luma — gates the "binary on/off" zones (e.g. the
            # FE GeForce side logo, which can't actually do colour or PWM
            # despite OpenRGB exposing an SDK colour for it).
            lum = (299*r + 587*g + 114*b) // 1000
            on  = RGBColor(255, 255, 255)
            off = RGBColor(0, 0, 0)
            gate = on if lum >= self.gpu_logo_threshold else off
            dead = []
            for dev in self.devices:
                try:
                    if dev.type.name == 'GPU' and any('SINGLE' in z.name.upper() for z in dev.zones):
                        # Drive RGBW zones with the actual colour, gate the
                        # SINGLE COLOR zone (hardware is on/off only).
                        for z in dev.zones:
                            tgt = gate if 'SINGLE' in z.name.upper() else col
                            z.set_color(tgt, fast=True)
                    else:
                        dev.set_color(col, fast=True)
                except Exception as e:
                    log.warning("openrgb device %s failed: %s", dev.name, e)
                    dead.append(dev)
            if dead:
                # Drop dead devices and force a reconnect on the next tick
                self.devices = [d for d in self.devices if d not in dead]
                if not self.devices:
                    self.client = None
            self.last_push = (r, g, b)

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
                allowed = ['dram','motherboard','gamepad','keyboard','mouse','headset',
                           'cooler','ledstrip','gpu','storage','case','speaker','virtual','unknown']
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
            orgb = OpenRGBSink(args.openrgb_host, args.openrgb_port, allowed, zone_sizes,
                               args.gpu_logo_threshold)

        log.info("colour algorithm: %s  ema=%.2f  capture-recycle=%.1fs  openrgb-fps=%.1f",
                 args.algo, args.ema, args.capture_recycle, args.openrgb_fps)
        period = 1.0 / args.fps
        next_t = time.perf_counter()
        frame_idx = 0
        ema = args.ema
        prev_zones = None      # list of 48 (r,g,b) ints
        prev_global = None     # one (r,g,b)
        # OpenRGB rate limiting — independent of main fps so the LG ring keeps
        # its 30 fps per-zone sync while OpenRGB devices update at a saner
        # rate that doesn't race on the SDK server.
        orgb_period = 1.0 / args.openrgb_fps if args.openrgb_fps > 0 else 0
        next_orgb_t = 0.0
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
                    # Compute the smoothed value every frame so EMA stays fast-
                    # converging, but only push to OpenRGB at the configured rate.
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
                    now = time.perf_counter()
                    if now >= next_orgb_t:
                        orgb.push(push_color)
                        next_orgb_t = now + orgb_period
                    frame_idx += 1
                    if args.debug and frame_idx % 60 == 0:
                        log.debug("pushed rgb=%s (raw=%s) zone0=%s zone16=%s",
                                  push_color, raw_global, smoothed_zones[0], smoothed_zones[16])
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
  '';

  # ------------------------------------------------------------------
  # Bundle the python sources into one package directory.
  pythonEnv = python.withPackages (ps: with ps; [ pywayland hid numpy openrgb-python ]);

  lg-sphere-ambient = pkgs.stdenv.mkDerivation {
    pname = "lg-sphere-ambient";
    version = "0.1.0";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      mkdir -p $out/lib/lg-sphere-ambient
      cp ${lib27gn950}     $out/lib/lg-sphere-ambient/lib27gn950.py
      cp ${screencopy}     $out/lib/lg-sphere-ambient/screencopy.py
      cp ${daemon}         $out/lib/lg-sphere-ambient/lg_sphere_ambient.py
      cp -r ${pywaylandProtocols} $out/lib/lg-sphere-ambient/protocols

      mkdir -p $out/bin
      makeWrapper ${pythonEnv}/bin/python3 $out/bin/lg-sphere-ambient \
        --add-flags "$out/lib/lg-sphere-ambient/lg_sphere_ambient.py" \
        --prefix PYTHONPATH : "$out/lib/lg-sphere-ambient"
    '';
  };

in
{
  # Give the logged-in user access to /dev/hidraw11 (the sphere-lighting
  # endpoint on the LG 38GN950) via group ownership. We previously used
  # systemd-logind's TAG+="uaccess", but the resulting ACL came up with
  # mask::--- on at least one reboot — the user entry was user:nsimon:rw-
  # but the mask collapsed effective rights to nothing, the daemon
  # crash-looped on "unable to open device", and a manual
  # `setfacl -m m::rw` was needed to recover. GROUP="input" MODE="0660"
  # skips the ACL/logind path entirely and is invariant across reboots.
  services.udev.extraRules = ''
    # LG 38GN950 (UltraGear) sphere lighting HID interface
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="043e", ATTRS{idProduct}=="9a8a", GROUP="input", MODE="0660"
  '';

  environment.systemPackages = [ lg-sphere-ambient ];

  # OpenRGB's LG plugin opens /dev/hidraw11 too — hidraw allows concurrent
  # writers, so its writes race ours and the sphere flashes on every
  # disagreement. Disable OpenRGB's LG-monitor detector before the server
  # starts so this daemon is the sole writer; the rest of the OpenRGB
  # device list (RAM, mobo, mouse, gamepad) is unaffected.
  systemd.services.openrgb.preStart = lib.mkAfter ''
    cfg=/var/lib/OpenRGB/OpenRGB.json
    if [ -s "$cfg" ]; then
      ${pkgs.jq}/bin/jq '.Detectors.detectors."LG 27GN950-B Monitor" = false' "$cfg" > "$cfg.tmp" \
        && mv "$cfg.tmp" "$cfg"
    else
      mkdir -p /var/lib/OpenRGB
      printf '{"Detectors":{"detectors":{"LG 27GN950-B Monitor":false}}}' > "$cfg"
    fi
  '';

  # OpenRGB's NVIDIA FE GPU detector dlopens libnvidia-api.so.1, but on
  # NixOS that lib sits in /run/opengl-driver/lib/ — not in the default
  # ld.so search path — so the dlopen silently fails and the GeForce
  # side-logo never gets enumerated. With this env var set,
  # NvAPI_Initialize() returns 0 and NvAPI_EnumPhysicalGPUs() reports 1
  # GPU on a 3080 Ti FE; the "Nvidia NvAPI Illumination" detector then
  # produces an "NVIDIA GeForce RTX 3080 Ti FE" device on the SDK.
  systemd.services.openrgb.environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";

  # User service — starts at login, restarts on failure, ends gracefully on logout.
  systemd.user.services.lg-sphere-ambient = {
    description = "LG 38GN950 sphere-lighting ambient sync";
    after = [ "graphical-session.target" ];
    wants = [ "graphical-session.target" ];
    wantedBy = [ "default.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = ''${lg-sphere-ambient}/bin/lg-sphere-ambient \
        --output DP-1 --fps 30 --brightness 12 \
        --openrgb --openrgb-devices all \
        --openrgb-zone-sizes "motherboard/Aura Addressable 1=24,motherboard/Aura Addressable 2=0,motherboard/Aura Addressable 3=8"'';
      Restart = "on-failure";
      RestartSec = "5s";
      # turn the lights off if the service is stopped or fails terminally
      TimeoutStopSec = "5s";
      KillSignal = "SIGTERM";
    };
  };
}
