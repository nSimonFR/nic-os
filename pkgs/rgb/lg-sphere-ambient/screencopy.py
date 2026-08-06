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
