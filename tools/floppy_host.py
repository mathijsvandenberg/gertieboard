#!/usr/bin/env python3
"""
floppy_host.py -- host side of the FPGA UART floppy controller, with BIOS-load.

Serves a floppy image to the FDC over serial, AND serves a 64 KB BIOS image when
the FPGA's ROM bootloader requests the reserved "magic" cylinder (C=0xFF). One
serial connection does both: boot-time BIOS fetch and normal disk I/O.

Wire protocol (matches fdc8272.vhd):
    READ :  FPGA -> host : 0x33 0x01 C H R
            host -> FPGA : <512 data bytes>
    WRITE:  FPGA -> host : 0x33 0x02 C H R <512 bytes>
            host -> FPGA : 0x06

Reserved cylinder 0xFF on a READ -> serve from the BIOS image at (R-1)*512.
Everything else -> serve from the floppy image (CHS via detected geometry).

Usage:
    python floppy_host.py --port COM5 --image floppy.img --bios bios32k.bin
    python floppy_host.py --port /dev/ttyUSB0 --image dos.img --bios glabios.bin -v
"""

import argparse
import sys

try:
    import serial
except ImportError:
    sys.exit("pyserial is required:  pip install pyserial")

PREAMBLE = 0x33
HCMD_RD  = 0x01
HCMD_WR  = 0x02
WRITE_OK = 0x06
SECTOR   = 512
BIOS_CYL = 0xFF          # reserved cylinder = "fetch BIOS image"

GEOMETRY = {
     163840: (40, 1,  8),   184320: (40, 1,  9),
     327680: (40, 2,  8),   368640: (40, 2,  9),
     737280: (80, 2,  9),  1228800: (80, 2, 15),
    1474560: (80, 2, 18),  2949120: (80, 2, 36),
}


def detect_geometry(size, override):
    if override:
        c, h, s = (int(x) for x in override.split(","))
        return c, h, s
    if size in GEOMETRY:
        return GEOMETRY[size]
    sys.exit(f"Unknown image size {size}; pass --geometry CYL,HEADS,SPT")


def read_exact(ser, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = ser.read(n - len(buf))
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--image", default="floppy.img")
    ap.add_argument("--bios", help="32 KB BIOS image served on cylinder 0xFF")
    ap.add_argument("--geometry", help="CYL,HEADS,SPT override")
    ap.add_argument("--readonly", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    img = open(args.image, "rb" if args.readonly else "r+b")
    img.seek(0, 2)
    size = img.tell()
    cyl, heads, spt = detect_geometry(size, args.geometry)
    print(f"floppy {args.image}: {size} bytes  ->  C/H/S = {cyl}/{heads}/{spt}")

    bios = b""
    if args.bios:
        bios = open(args.bios, "rb").read()
        if len(bios) < 65536:
            bios = bios + bytes(65536 - len(bios))
        bios = bios[:65536]
        print(f"BIOS  {args.bios}: {len(bios)} bytes served on cylinder 0x{BIOS_CYL:02X}")

    ser = serial.Serial(args.port, args.baud, timeout=1.0)
    print(f"serving on {args.port} @ {args.baud} baud. Ctrl-C to stop.")

    try:
        while True:
            b = ser.read(1)
            if not b or b[0] != PREAMBLE:
                continue
            hdr = read_exact(ser, 4)          # cmd, C, H, R
            if hdr is None:
                continue
            cmd, c, h, r = hdr

            # ---- reserved BIOS cylinder ----
            if cmd == HCMD_RD and c == BIOS_CYL:
                off = (r - 1) * SECTOR
                data = bios[off:off + SECTOR]
                if len(data) < SECTOR:
                    data = data + bytes(SECTOR - len(data))
                ser.write(data)
                if args.verbose:
                    print(f"  BIOS  R{r:<3} -> offset {off}")
                continue

            # ---- normal floppy access ----
            if not (0 <= c < cyl and 0 <= h < heads and 1 <= r <= spt):
                if cmd == HCMD_RD:
                    ser.write(bytes(SECTOR))
                elif cmd == HCMD_WR:
                    read_exact(ser, SECTOR)
                    ser.write(bytes([WRITE_OK]))
                if args.verbose:
                    print(f"  !! out-of-range C/H/R = {c}/{h}/{r}")
                continue

            off = ((c * heads + h) * spt + (r - 1)) * SECTOR
            if cmd == HCMD_RD:
                img.seek(off)
                data = img.read(SECTOR)
                if len(data) < SECTOR:
                    data = data + bytes(SECTOR - len(data))
                ser.write(data)
                if args.verbose:
                    print(f"  READ  C{c} H{h} R{r}")
            elif cmd == HCMD_WR:
                data = read_exact(ser, SECTOR)
                if data is None:
                    continue
                if not args.readonly:
                    img.seek(off); img.write(data); img.flush()
                ser.write(bytes([WRITE_OK]))
                if args.verbose:
                    print(f"  WRITE C{c} H{h} R{r}")

    except KeyboardInterrupt:
        print("\nstopping.")
    finally:
        ser.close()
        img.close()


if __name__ == "__main__":
    main()
