#!/usr/bin/env python3
"""
fatput.py -- put a file into a FAT12 floppy image.

There is no mtools in this environment, and for a long time getting a freshly
built .COM onto tools/dos33-xtpro.img meant pasting an ad-hoc snippet into the
shell each time. This is that snippet, written down once and made to check its
own work.

    python3 fatput.py dos33-xtpro.img usbhd.com
    python3 fatput.py dos33-xtpro.img usbhd.com --as USBHD.COM
    python3 fatput.py dos33-xtpro.img --list

Everything comes from the BPB in the boot sector -- nothing about the geometry
is hardcoded, so it works on a 360K, 720K or 1.44M image equally. An existing
file of the same name is replaced and its old cluster chain freed, so repeated
runs during a build-test loop do not leak space.

After writing, the file is read back through the same directory entry and
cluster chain that DOS will follow and compared with the input. A silent
mis-write here would look exactly like a bug in the program being tested.
"""

import argparse
import datetime
import struct
import sys


class Fat12:
    def __init__(self, path):
        self.path = path
        with open(path, 'rb') as f:
            self.img = bytearray(f.read())
        b = self.img
        self.bps = struct.unpack('<H', b[11:13])[0]
        self.spc = b[13]
        self.reserved = struct.unpack('<H', b[14:16])[0]
        self.nfats = b[16]
        self.rootents = struct.unpack('<H', b[17:19])[0]
        self.total = struct.unpack('<H', b[19:21])[0]
        self.spf = struct.unpack('<H', b[22:24])[0]
        if self.bps != 512 or self.spc == 0 or self.nfats == 0:
            sys.exit('does not look like a FAT12 floppy image')

        self.fat0 = self.reserved * self.bps
        self.rootoff = (self.reserved + self.nfats * self.spf) * self.bps
        self.rootbytes = self.rootents * 32
        self.dataoff = self.rootoff + self.rootbytes
        self.clusters = (self.total - (self.dataoff // self.bps)) // self.spc
        self.csize = self.spc * self.bps

    # ---- FAT12 is packed 12 bits per entry, alternating nibble alignment ----
    def get(self, n):
        o = self.fat0 + n + (n >> 1)
        v = self.img[o] | (self.img[o + 1] << 8)
        return v & 0xFFF if n % 2 == 0 else v >> 4

    def set(self, n, val):
        val &= 0xFFF
        for fat in range(self.nfats):
            base = self.fat0 + fat * self.spf * self.bps
            o = base + n + (n >> 1)
            cur = self.img[o] | (self.img[o + 1] << 8)
            if n % 2 == 0:
                cur = (cur & 0xF000) | val
            else:
                cur = (cur & 0x000F) | (val << 4)
            self.img[o] = cur & 0xFF
            self.img[o + 1] = (cur >> 8) & 0xFF

    def cluster_offset(self, n):
        return self.dataoff + (n - 2) * self.csize

    def chain(self, first):
        out, n, guard = [], first, 0
        while 2 <= n < 0xFF0 and guard < self.clusters + 4:
            out.append(n)
            n = self.get(n)
            guard += 1
        return out

    # ---- root directory ----
    def entries(self):
        for i in range(self.rootents):
            o = self.rootoff + i * 32
            e = self.img[o:o + 32]
            if e[0] == 0x00:
                break
            if e[0] == 0xE5 or (e[11] & 0x0F) == 0x0F:
                continue
            yield i, e

    def find(self, name83):
        for i, e in self.entries():
            if bytes(e[0:11]) == name83:
                return i
        return None

    def free_slot(self):
        for i in range(self.rootents):
            o = self.rootoff + i * 32
            if self.img[o] in (0x00, 0xE5):
                return i
        return None


def to83(name):
    name = name.upper().replace('/', '\\').split('\\')[-1]
    stem, _, ext = name.partition('.')
    if len(stem) > 8 or len(ext) > 3:
        sys.exit(f'"{name}" does not fit an 8.3 name')
    return (stem.ljust(8) + ext.ljust(3)).encode('ascii')


def main():
    ap = argparse.ArgumentParser(description='Put a file into a FAT12 floppy image')
    ap.add_argument('image')
    ap.add_argument('file', nargs='?')
    ap.add_argument('--as', dest='asname', help='8.3 name to use on the disk')
    ap.add_argument('--list', action='store_true', help='list the root directory and exit')
    args = ap.parse_args()

    fs = Fat12(args.image)

    if args.list or not args.file:
        used = 0
        print(f'{args.image}: {fs.total} sectors, {fs.clusters} clusters of '
              f'{fs.csize} bytes, {fs.rootents} root entries')
        for _, e in fs.entries():
            nm = e[0:8].decode('latin1').rstrip()
            ex = e[8:11].decode('latin1').rstrip()
            sz = struct.unpack('<I', e[28:32])[0]
            cl = struct.unpack('<H', e[26:28])[0]
            used += sz
            print(f'  {nm:<8}.{ex:<3} {sz:>8}  first cluster {cl}')
        free = sum(1 for n in range(2, fs.clusters + 2) if fs.get(n) == 0)
        print(f'  -- {used} bytes in files, {free} free clusters '
              f'({free * fs.csize} bytes)')
        return

    data = open(args.file, 'rb').read()
    name83 = to83(args.asname or args.file)
    need = (len(data) + fs.csize - 1) // fs.csize

    # replace: free the old chain first so a rebuild does not leak clusters
    slot = fs.find(name83)
    if slot is not None:
        o = fs.rootoff + slot * 32
        old = struct.unpack('<H', fs.img[o + 26:o + 28])[0]
        if old >= 2:
            for c in fs.chain(old):
                fs.set(c, 0)
        print(f'replacing existing {name83.decode()}')
    else:
        slot = fs.free_slot()
        if slot is None:
            sys.exit('root directory is full')

    free = [n for n in range(2, fs.clusters + 2) if fs.get(n) == 0]
    if len(free) < need:
        sys.exit(f'need {need} clusters, only {len(free)} free')
    use = free[:need]

    for i, c in enumerate(use):
        chunk = data[i * fs.csize:(i + 1) * fs.csize]
        o = fs.cluster_offset(c)
        fs.img[o:o + len(chunk)] = chunk
        if len(chunk) < fs.csize:                     # do not leave stale bytes
            fs.img[o + len(chunk):o + fs.csize] = b'\x00' * (fs.csize - len(chunk))
        fs.set(c, use[i + 1] if i + 1 < need else 0xFFF)

    now = datetime.datetime.now()
    ftime = (now.hour << 11) | (now.minute << 5) | (now.second // 2)
    fdate = ((now.year - 1980) << 9) | (now.month << 5) | now.day
    e = bytearray(32)
    e[0:11] = name83
    e[11] = 0x20                                       # archive
    struct.pack_into('<H', e, 22, ftime)
    struct.pack_into('<H', e, 24, fdate)
    struct.pack_into('<H', e, 26, use[0])
    struct.pack_into('<I', e, 28, len(data))
    o = fs.rootoff + slot * 32
    fs.img[o:o + 32] = e

    with open(args.image, 'wb') as f:
        f.write(fs.img)

    # ---- read it back the way DOS will, and compare ----
    chk = Fat12(args.image)
    i = chk.find(name83)
    if i is None:
        sys.exit('VERIFY FAILED: directory entry not found after writing')
    o = chk.rootoff + i * 32
    first = struct.unpack('<H', chk.img[o + 26:o + 28])[0]
    size = struct.unpack('<I', chk.img[o + 28:o + 32])[0]
    got = b''
    for c in chk.chain(first):
        off = chk.cluster_offset(c)
        got += bytes(chk.img[off:off + chk.csize])
    got = got[:size]
    if size != len(data) or got != data:
        sys.exit(f'VERIFY FAILED: read back {size} bytes, expected {len(data)}')

    print(f'{args.file} -> {args.image} as {name83[:8].decode().rstrip()}.'
          f'{name83[8:].decode().rstrip()}')
    print(f'   {len(data)} bytes in {need} cluster(s) starting at {use[0]}, '
          f'verified by re-reading the chain')


if __name__ == '__main__':
    main()
