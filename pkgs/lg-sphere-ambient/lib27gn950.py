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
