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

        def __init__(self, host, port, allowed_types, zone_sizes):
            """zone_sizes: list of (device_type, zone_name, led_count) tuples."""
            self.host = host; self.port = port
            self.allowed = set(t.lower() for t in allowed_types)
            self.zone_sizes = zone_sizes
            self.client = None
            self.devices = []
            self.last_attempt = 0.0

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

        def push(self, rgb):
            from openrgb.utils import RGBColor
            if self.client is None and not self._connect():
                return
            r, g, b = rgb
            col = RGBColor(r, g, b)
            dead = []
            for dev in self.devices:
                try:
                    dev.set_color(col, fast=True)
                except Exception as e:
                    log.warning("openrgb device %s failed: %s", dev.name, e)
                    dead.append(dev)
            if dead:
                # Drop dead devices and force a reconnect on the next tick
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

    def sample_zones(mm, w, h, stride):
        a = np.frombuffer(mm, dtype=np.uint8, count=stride*h).reshape(h, stride//4, 4)
        a = a[:, :w]
        out = []
        band = a[:BAND, :, :3]
        for k in range(N_TOP):
            x0 = k*w//N_TOP; x1 = (k+1)*w//N_TOP
            m = band[:, x0:x1].mean(axis=(0,1)); out.append((int(m[2]), int(m[1]), int(m[0])))
        band = a[:, w-BAND:, :3]
        for k in range(N_SIDE):
            y0 = k*h//N_SIDE; y1 = (k+1)*h//N_SIDE
            m = band[y0:y1].mean(axis=(0,1)); out.append((int(m[2]), int(m[1]), int(m[0])))
        band = a[h-BAND:, :, :3]
        for k in range(N_TOP):
            x0 = k*w//N_TOP; x1 = (k+1)*w//N_TOP
            m = band[:, x0:x1].mean(axis=(0,1)); out.append((int(m[2]), int(m[1]), int(m[0])))
        band = a[:, :BAND, :3]
        for k in range(N_SIDE):
            y0 = k*h//N_SIDE; y1 = (k+1)*h//N_SIDE
            m = band[y0:y1].mean(axis=(0,1)); out.append((int(m[2]), int(m[1]), int(m[0])))
        return [f"{r:02x}{g:02x}{b:02x}" for r,g,b in out]

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
            orgb = OpenRGBSink(args.openrgb_host, args.openrgb_port, allowed, zone_sizes)

        period = 1.0 / args.fps
        next_t = time.perf_counter()
        try:
            while not stop[0]:
                mm, w, h, stride = cap.next_frame()
                colors = sample_zones(mm, w, h, stride)
                lg.send_video_sync_data(colors, dev)
                if orgb is not None:
                    # average the 48 hex zones to one RGB
                    avg = np.array(
                        [(int(c[0:2],16), int(c[2:4],16), int(c[4:6],16)) for c in colors],
                        dtype=np.uint16,
                    ).mean(axis=0).astype(np.uint8)
                    orgb.push((int(avg[0]), int(avg[1]), int(avg[2])))
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
  # Give the logged-in user access to hidraw11 (the sphere lighting endpoint)
  # via systemd-logind's `uaccess` tag. No chmod, no group membership.
  services.udev.extraRules = ''
    # LG 38GN950 (UltraGear) sphere lighting HID interface
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="043e", ATTRS{idProduct}=="9a8a", TAG+="uaccess"
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
