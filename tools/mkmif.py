#!/usr/bin/env python3
"""
mkmif.py -- convert a raw binary into a Quartus MIF (8-bit words).

Usage:
    python mkmif.py bootldr.bin bootldr.mif 256

The bin (assembled with `nasm -f bin`, ORG 0xFF00) is 256 bytes spanning
0xFF00..0xFFFF; byte offset i maps directly to ROM address i, which the overlay
reads as physical 0xFFF00+i. Shorter bins are padded with 0x90 (NOP), longer
ones are truncated to <depth>.
"""

import sys

def main():
    if len(sys.argv) != 4:
        sys.exit("usage: mkmif.py <in.bin> <out.mif> <depth>")
    inp, outp, depth = sys.argv[1], sys.argv[2], int(sys.argv[3])

    data = bytearray(open(inp, "rb").read())
    if len(data) > depth:
        data = data[:depth]
    data += bytes([0x90] * (depth - len(data)))   # pad with NOP

    with open(outp, "w") as f:
        f.write(f"DEPTH = {depth};\n")
        f.write("WIDTH = 8;\n")
        f.write("ADDRESS_RADIX = HEX;\n")
        f.write("DATA_RADIX = HEX;\n")
        f.write("CONTENT BEGIN\n")
        for addr, byte in enumerate(data):
            f.write(f"    {addr:03X} : {byte:02X};\n")
        f.write("END;\n")

    print(f"wrote {outp}: {depth} bytes")

if __name__ == "__main__":
    main()
