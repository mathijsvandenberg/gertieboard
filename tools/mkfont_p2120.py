#!/usr/bin/env python3
"""
mkfont_p2120.py -- build the FPGA text font and the BIOS 8x8 font from the real
Philips P2120 character generator ROM.

Input:  tools/P2120/Philips_27C64_U44.bin   (27C64, 8192 bytes)
Output: font.vhd            ROM array rewritten in place, 256 chars x 16 rows
        tools/font8x8.bin   256 chars x 8 rows, .incbin'd into the BIOS

ROM LAYOUT (determined empirically -- there is no datasheet here)
----------------------------------------------------------------
The 8 KB splits into four 2 KB pages:

    0x0000  256 x 8   thin 8x8 font            (--thin)
    0x0800  256 x 8   bold 8x8 variant       -> used for font8x8.bin
    0x1000  256 x 8   16-row font, rows 0-7   -> used for font.vhd
    0x1800  256 x 8   16-row font, rows 8-15

So a 16-row glyph is  pageA[c*8 + 0..7]  then  pageB[c*8 + 0..7].

Three alternative layouts were tested by counting "interior blank rows" (a blank
row sandwiched between two non-blank rows, which a real glyph almost never has)
across all letters and digits:

    halves sequential    7 interior blanks   <-- correct
    interleaved A/B    347
    interleaved B/A    471

Shifting the second half by -4..+4 bytes only ever made it worse, and the 7
remaining blanks are all legitimate: ! , : ; = ? _ and the dotted i j.

Both fonts are CP437-compatible -- verified at 0xC4 (horizontal), 0xB3
(vertical), 0xDA (top-left corner), 0xC5 (cross), 0xB0 (dither) and 0xDB (solid
block) -- so they drop straight in with no remapping.

DETACHED BOTTOM ROWS
--------------------
Text glyphs in this ROM occupy rows 0-12 and box/block glyphs fill all 16. But
two groups of characters carry an extra stroke near the bottom, detached from the
glyph body by a blank row:

    descenders          g j p q y , ; _    duplicate the last descender row at
                        row 14, row 13 blank:
                            'p'  row 12 = 78  row 13 = 00  row 14 = 78
                            'g'  row 12 = 3C  row 13 = 00  row 14 = 7C

    box glyphs with     C4 C8 CA CD CF      a stub at row 15, row 14 blank:
    no downward         D0 D3 D4 D9             0xC4  row 7 = FF, row 15 = 18
    stroke              (- = # ) - + etc)

The ROM evidently served two cell heights, repeating the lowest stroke further
down for the taller one. Rendered in a single 16-row cell both show as a detached
smudge below the glyph.

Genuine box glyphs must NOT be touched: a vertical bar has to reach both cell
edges to join up with the rows above and below, so 0xB3 and friends are set on
every row from the body straight through to row 15. The distinguishing feature is
therefore attachment, not position:

    scanning rows 13..15, the first row that is set while the row above it is
    blank begins a detached group -- clear from there to the bottom

That leaves anything continuous with the body intact, and removes both artifacts
with one rule. 36 characters fill rows 13-15 continuously and keep every pixel.
"""

import sys, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC  = os.path.join(HERE, 'P2120', 'Philips_27C64_U44.bin')
VHD  = os.path.join(ROOT, 'font.vhd')
F8   = os.path.join(HERE, 'font8x8.bin')

PAGE_THIN, PAGE_BOLD, PAGE_HI, PAGE_LO = 0x0000, 0x0800, 0x1000, 0x1800


def load():
    with open(SRC, 'rb') as f:
        d = f.read()
    if len(d) != 8192:
        sys.exit(f'FAIL: expected 8192 bytes, got {len(d)}')
    return d


def raw16(d, c):
    """The 16 rows of character c exactly as the ROM holds them."""
    return [d[PAGE_HI + c * 8 + r] for r in range(8)] + \
           [d[PAGE_LO + c * 8 + r] for r in range(8)]


def glyph16(d, c):
    """The 16 rows of character c, with any detached bottom group removed."""
    g = raw16(d, c)
    for r in range(13, 16):
        if g[r] and not g[r - 1]:
            for k in range(r, 16):
                g[k] = 0
            break
    return g


def verify(d, font16, font8):
    """Sanity-check the decode before overwriting anything."""
    errs = []

    if len(font16) != 4096:
        errs.append(f'font16 has {len(font16)} rows, expected 4096')
    if len(font8) != 2048:
        errs.append(f'font8 has {len(font8)} bytes, expected 2048')

    # CP437 landmarks in the 16-row font
    vert = [font16[0xB3 * 16 + r] for r in range(16)]
    if not all(vert):
        errs.append('0xB3 (vertical bar) does not span all 16 rows')
    block = [font16[0xDB * 16 + r] for r in range(16)]
    if not all(b == 0xFF for b in block):
        errs.append('0xDB (solid block) is not 0xFF on every row')
    horiz = [r for r in range(16) if font16[0xC4 * 16 + r]]
    if horiz != [7]:
        errs.append(f'0xC4 (horizontal) should occupy row 7 only, got {horiz}')

    # space must be empty, and letters must not be
    if any(font16[0x20 * 16 + r] for r in range(16)):
        errs.append('0x20 (space) is not blank')
    for c in (0x41, 0x5A, 0x61, 0x7A, 0x30, 0x39):
        if not any(font16[c * 16 + r] for r in range(16)):
            errs.append(f'0x{c:02X} ({chr(c)!r}) is blank in the 16-row font')
        if not any(font8[c * 8 + r] for r in range(8)):
            errs.append(f'0x{c:02X} ({chr(c)!r}) is blank in the 8x8 font')

    # no detached bottom group may survive anywhere
    for c in range(256):
        g = [font16[c * 16 + r] for r in range(16)]
        for r in range(13, 16):
            if g[r] and not g[r - 1]:
                errs.append(f'0x{c:02X}: detached row {r} survived')
                break

    # continuous box glyphs must have kept every row
    for c in (0xB3, 0xC5, 0xDA, 0xDB, 0xBA):
        g = [font16[c * 16 + r] for r in range(16)]
        if not (g[13] and g[14] and g[15]):
            errs.append(f'0x{c:02X}: box glyph lost its bottom rows')

    if errs:
        for e in errs:
            print('  FAIL:', e)
        sys.exit(1)


def write_vhd(font16):
    with open(VHD, encoding='utf-8', newline='') as f:
        lines = f.read().split('\n')

    start = end = None
    for i, l in enumerate(lines):
        if start is None and re.match(r'\s*constant\s+ROM\s*:\s*rom_type', l):
            start = i
        elif start is not None and l.strip() == ');':
            end = i
            break
    if start is None or end is None:
        sys.exit('FAIL: could not find the ROM array in font.vhd')

    body = []
    for c in range(256):
        ch = chr(c) if 32 <= c < 127 else ''
        note = f"  '{ch}'" if ch and ch != "'" else ''
        body.append(f'   -- code x{c:02X}{note}')
        for r in range(16):
            b = font16[c * 16 + r]
            comma = '' if (c == 255 and r == 15) else ','
            pad = ' ' if comma == '' else ''
            body.append(f'   "{b:08b}"{comma}{pad} -- {r:x}')

    out = lines[:start + 1] + body + lines[end:]
    with open(VHD, 'w', encoding='utf-8', newline='') as f:
        f.write('\n'.join(out))
    return len(body), start + 1, end


def main():
    thin = '--thin' in sys.argv
    d = load()
    font16 = bytearray()
    for c in range(256):
        font16 += bytes(glyph16(d, c))

    # Which 8x8 page feeds the BIOS graphics-mode glyphs is a judgment call: the
    # ROM holds a thin and a bold version and nothing in it says which the
    # original used. Thin was the default merely because it is the first page.
    # BOLD now, chosen 2026-08-07 by looking at the real thing: it matches the
    # weight of the 16-row text font, and until King's Quest ran in EGA there
    # had been nothing on screen to judge it by. --thin restores the other.
    #
    # Not as cosmetic as it once was. These glyphs are now what mode 0Dh draws
    # as well as modes 4/5/6, AND they are the bytes published at F000:FA6E,
    # so software that builds its own glyphs from the ROM font inherits this
    # weight too -- see the .font_rom section in xtbios_src.s.
    page = PAGE_THIN if thin else PAGE_BOLD
    font8 = bytearray(d[page:page + 2048])

    print('== verifying the decode ==')
    verify(d, font16, font8)
    fixed = [c for c in range(256) if raw16(d, c) != glyph16(d, c)]
    kept = sum(1 for c in range(256) if all(font16[c * 16 + r] for r in (13, 14, 15)))
    print(f'   CP437 landmarks OK')
    print(f'   detached bottom rows cleared on {len(fixed)} characters: '
          + ' '.join(f'{c:02X}' for c in fixed))
    print(f'   {kept} characters fill rows 13-15 continuously and were left intact')

    n, a, b = write_vhd(font16)
    print(f'== font.vhd ==\n   ROM array replaced: {n} lines in place of {b - a}')

    with open(F8, 'wb') as f:
        f.write(font8)
    print(f'== tools/font8x8.bin ==\n   {len(font8)} bytes from the '
          f'{"thin" if thin else "bold"} 8x8 page (0x{page:04X})')
    print('\nFONT OK -- rebuild the FPGA (font.vhd) and the BIOS (font8x8.bin)')


if __name__ == '__main__':
    main()
