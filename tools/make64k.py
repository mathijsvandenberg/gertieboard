#!/usr/bin/env python3
"""
make64k.py -- expand a small BIOS/diagnostic ROM image into a full 64 KB
F-segment image, so the whole 0xF0000..0xFFFFF region has defined content (no
mirroring artifacts) and a ROM-checksum POST sees faithful data.

The input is placed TOP-ALIGNED by default, so its internal reset vector ends up
at 0xFFFF0 (image offset 0x1FF0 within an 8 KB ROM -> 0xFFF0 within the 64 KB
image). The rest is filled with 0xFF, which most diagnostics read as "no ROM
installed" and skip, instead of failing a bad checksum on mirrored garbage.

    8 KB  input -> placed at F-seg offset 0xE000  (0xFE000..0xFFFFF)
    16 KB input -> placed at F-seg offset 0xC000  (0xFC000..0xFFFFF)
    32 KB input -> placed at F-seg offset 0x8000  (0xF8000..0xFFFFF)

Usage:
    python make64k.py ruud.bin                 ->  ruud.64k
    python make64k.py supersoft.bin -o ss.64k
    python make64k.py basic.bin --offset 0x6000 --fill 0x00   (manual placement)

Place several ROMs into one image by running repeatedly with --in-place on the
output and explicit --offset values (e.g. BASIC at 0x6000, system BIOS at 0xE000).
"""

import argparse
import os
import sys

FSEG = 0x10000          # 64 KB
FBASE = 0xF0000         # linear base of the F-segment


def main():
    ap = argparse.ArgumentParser(description="Expand a small ROM to a 64 KB F-segment image (.64k)")
    ap.add_argument("input", help="input ROM (.bin), 1..65536 bytes")
    ap.add_argument("-o", "--output", help="output file (default: <input>.64k)")
    ap.add_argument("--fill", default="0xFF",
                    help="pad byte for empty space (default 0xFF = absent ROM)")
    ap.add_argument("--offset",
                    help="explicit F-seg placement offset in hex (default: top-aligned)")
    ap.add_argument("--in-place", action="store_true",
                    help="load existing output and overlay input onto it (for multi-ROM images)")
    args = ap.parse_args()

    data = open(args.input, "rb").read()
    n = len(data)
    if n == 0 or n > FSEG:
        sys.exit(f"input is {n} bytes; must be 1..{FSEG}")

    fill = int(args.fill, 0) & 0xFF
    off = int(args.offset, 0) if args.offset is not None else (FSEG - n)
    if off < 0 or off + n > FSEG:
        sys.exit(f"input ({n} bytes) at offset 0x{off:X} does not fit in 64 KB")

    out = args.output or (os.path.splitext(args.input)[0] + ".64k")

    if args.in_place and os.path.exists(out):
        img = bytearray(open(out, "rb").read())
        if len(img) != FSEG:
            sys.exit(f"--in-place target {out} is {len(img)} bytes, expected {FSEG}")
    else:
        img = bytearray([fill]) * FSEG

    img[off:off + n] = data
    open(out, "wb").write(img)

    print(f"{args.input}: {n} bytes  ->  {out}: {FSEG} bytes")
    print(f"  placed at F-seg offset 0x{off:04X}  "
          f"(0x{FBASE + off:05X}..0x{FBASE + off + n - 1:05X}), fill 0x{fill:02X}")
    if off <= 0xFFF0 < off + n:
        rv = bytes(img[0xFFF0:0xFFF5])
        print(f"  reset vector @0xFFFF0: {' '.join(f'{b:02X}' for b in rv)}  (expect EA .. .. .. F0)")
    else:
        print("  NOTE: 0xFFFF0 is in fill -- this ROM doesn't reach the top; "
              "add the system BIOS with --in-place --offset 0xE000")


if __name__ == "__main__":
    main()
