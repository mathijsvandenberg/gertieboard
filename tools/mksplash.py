#!/usr/bin/env python3
"""
mksplash.py -- build the CGA splash screen for SPLASH.COM.

Renders "Gertieboard" as graffiti on a brick wall and emits a run-length
encoded CGA mode 4 framebuffer (tools/splash.dat) plus a PNG preview.

Two things about CGA that shape the whole design:

  * Four colours, and one of them is the background. Mode 4 palette 0 with the
    intensity bit gives light green, light red and yellow over any background.
    Black background, yellow letters, red drop shadow and a black outline is
    almost exactly the reference artwork; green is left for the wall so it
    recedes behind the warm colours.

  * Pixels are not square. 320x200 stretched to a 4:3 screen makes each pixel
    5:6 -- taller than wide -- so anything drawn round comes out stretched.
    The artwork is therefore composed at 320x240 (square pixels, supersampled)
    and squashed to 320x200 on the way out, which is why script lettering that
    would otherwise look elongated reads correctly on the monitor.
"""

import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SS = 3                                  # supersample factor
DW, DH = 320 * SS, 240 * SS             # design canvas, square pixels
OW, OH = 320, 200                       # CGA mode 4 framebuffer

# palette indices as the hardware sees them (3D9 = 0x10: palette 0, intense)
BLACK, GREEN, RED, YELLOW = 0, 1, 2, 3
RGB = {BLACK: (0, 0, 0), GREEN: (85, 255, 85),
       RED: (255, 85, 85), YELLOW: (255, 255, 85)}

FONT = r'C:\Windows\Fonts\BRUSHSCI.TTF'
WORD = 'Gertieboard'


def mask(img):
    return np.array(img, dtype=bool)


def blank():
    return Image.new('L', (DW, DH), 0)


def dilate(m, r):
    """Grow a boolean mask by r pixels, round-ish."""
    im = Image.fromarray((m * 255).astype(np.uint8))
    # MaxFilter only takes odd sizes and gets slow when large; iterate.
    step = 9
    while r > 0:
        k = min(step, r * 2 + 1)
        if k % 2 == 0:
            k += 1
        im = im.filter(ImageFilter.MaxFilter(k))
        r -= k // 2
    return np.array(im) > 127


def shift(m, dx, dy):
    out = np.zeros_like(m)
    h, w = m.shape
    xs0, xs1 = max(0, -dx), min(w, w - dx)
    ys0, ys1 = max(0, -dy), min(h, h - dy)
    out[ys0 + dy:ys1 + dy, xs0 + dx:xs1 + dx] = m[ys0:ys1, xs0:xs1]
    return out


def down(m):
    """Design canvas -> 320x200, squashing the vertical axis."""
    im = Image.fromarray((m * 255).astype(np.uint8))
    im = im.resize((OW, OH), Image.BILINEAR)
    return np.array(im) > 110


# ---------------------------------------------------------------- the wall
def build_wall():
    """Brick courses drawn as mortar lines. Thin, so the wall stays a
    backdrop rather than competing with the lettering."""
    im = blank()
    d = ImageDraw.Draw(im)
    bw, bh = 46 * SS, 15 * SS               # brick size in design pixels
    t = max(1, SS // 2)                     # mortar thickness
    row = 0
    y = -bh
    while y < DH + bh:
        d.rectangle([0, y, DW, y + t], fill=255)
        off = (bw // 2) if (row % 2) else 0
        x = -bw + off
        while x < DW + bw:
            d.rectangle([x, y, x + t, y + bh], fill=255)
            x += bw
        y += bh
        row += 1
    wall = mask(im)

    # a few cracks so it does not look like graph paper
    im2 = blank()
    d2 = ImageDraw.Draw(im2)
    rng = np.random.default_rng(7)
    for _ in range(9):
        x, y = rng.integers(0, DW), rng.integers(0, DH)
        pts = [(x, y)]
        for _ in range(rng.integers(3, 7)):
            x += int(rng.integers(-30, 30)) * SS // 3
            y += int(rng.integers(8, 40)) * SS // 3
            pts.append((x, y))
        d2.line(pts, fill=255, width=t)
    return wall | mask(im2)


# ------------------------------------------------------------- the lettering
def build_word():
    """The word itself, plus paint drips, as one mask. Drips are added before
    the outline is grown so they get the same black keyline as the letters."""
    size = 400 * SS // 3
    while size > 20:
        f = ImageFont.truetype(FONT, size)
        l, t, r, b = f.getbbox(WORD)
        if r - l <= DW - 26 * SS and (b - t) <= DH * 0.62:
            break
        size -= 4
    im = Image.new('L', (DW, DH), 0)
    d = ImageDraw.Draw(im)
    # Biased up and left to leave room for the drop shadows, which extend ten
    # final pixels right and eight down and would otherwise clip the edge.
    x = (DW - (r - l)) // 2 - l - 6 * SS
    y = (DH - (b - t)) // 2 - t - 12 * SS
    d.text((x, y), WORD, font=f, fill=255)

    # rotate slightly: graffiti is never level
    im = im.rotate(-5, resample=Image.BICUBIC, center=(DW // 2, DH // 2))
    core = np.array(im) > 127

    # paint drips: find the lowest lit pixel in a few columns and run down
    im3 = Image.fromarray((core * 255).astype(np.uint8))
    d3 = ImageDraw.Draw(im3)
    cols = np.where(core.any(axis=0))[0]
    if len(cols):
        rng = np.random.default_rng(3)
        picks = rng.choice(cols[SS:-SS], size=7, replace=False)
        for cx in sorted(picks):
            cy = np.where(core[:, cx])[0].max()
            ln = int(rng.integers(10, 40)) * SS // 3
            w = int(rng.integers(3, 6)) * SS // 3
            d3.rectangle([cx - w, cy - w, cx + w, cy + ln], fill=255)
            d3.ellipse([cx - w, cy + ln - w, cx + w, cy + ln + w], fill=255)
    return np.array(im3) > 127


def build_tagline():
    """Drawn straight at 320x200. Eight-pixel text does not survive being
    supersampled and squashed -- it turns to mush -- so it skips that path
    entirely and is composited last, at the resolution it will be shown."""
    im = Image.new('L', (OW, OH), 0)
    d = ImageDraw.Draw(im)
    f = ImageFont.truetype(r'C:\Windows\Fonts\arialbd.ttf', 11)
    s = 'PHILIPS ROM BIOS    RETIREMENT EDITION'
    l, t, r, b = f.getbbox(s)
    d.text(((OW - (r - l)) // 2 - l, OH - 17), s, font=f, fill=255)
    return np.array(im) > 100


# ------------------------------------------------------------------ compose
def compose():
    wall = build_wall()
    core = build_word()

    # Offsets given in FINAL pixels and converted separately per axis: the
    # vertical scale is not the horizontal one (720->200 against 960->320), so
    # a shadow specified as an equal diagonal comes out lopsided if converted
    # with a single factor.
    def dx(n): return int(round(n * DW / OW))
    def dy(n): return int(round(n * DH / OH))

    ring = SS * 3                       # outline ~3 final pixels
    out = dilate(core, ring)
    sh_near = shift(out, dx(5), dy(4))
    sh_far = shift(out, dx(10), dy(8))

    idx = np.zeros((OH, OW), dtype=np.uint8)

    # A 50% checkerboard drops the wall to a dim texture. Solid light green
    # across the whole screen fights the lettering; dithered, it reads as a
    # grubby surface and lets the warm colours come forward. Costs nothing --
    # CGA has no dim green, so this is how you get one.
    yy, xx = np.mgrid[0:OH, 0:OW]
    dither = ((xx + yy) & 1).astype(bool)
    idx[down(wall) & dither] = GREEN

    idx[down(sh_far)] = GREEN           # far shadow, cool, sits back
    idx[down(sh_near)] = RED            # near shadow, the warm keyline
    idx[down(out)] = BLACK              # heavy black outline, as the reference
    idx[down(core)] = YELLOW

    tag = build_tagline()               # already at 320x200
    tim = Image.fromarray((tag * 255).astype(np.uint8))
    idx[np.array(tim.filter(ImageFilter.MaxFilter(3))) > 127] = BLACK
    idx[tag] = YELLOW
    return idx


# -------------------------------------------------------- CGA encode + RLE
def to_cga(idx):
    """Mode 4: 2 bits per pixel, MSB first, 80 bytes per row, even rows at
    0x0000 and odd rows at 0x2000. The 192-byte holes at the end of each bank
    are left zero; they cost nothing once compressed."""
    buf = bytearray(0x4000)
    for y in range(OH):
        base = (y >> 1) * 80 + (0x2000 if (y & 1) else 0)
        row = idx[y]
        for xb in range(80):
            p = row[xb * 4:xb * 4 + 4]
            buf[base + xb] = (p[0] << 6) | (p[1] << 4) | (p[2] << 2) | p[3]
    return bytes(buf)


def rle(data):
    """PackBits-style: 0x80|n means (n+1) copies of the next byte, otherwise
    (n+1) literal bytes follow. Terminated by 0x00 0x00, which cannot occur
    as a literal run because a literal of length 1 is encoded as 0x00 + byte
    and the terminator is checked before the payload is read."""
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        j = i
        while j + 1 < n and data[j + 1] == data[i] and j - i < 126:
            j += 1
        if j > i:                       # a run of >= 2
            out += bytes([0x80 | (j - i), data[i]])
            i = j + 1
        else:                           # gather literals
            j = i
            while j < n and j - i < 127:
                if j + 2 < n and data[j] == data[j + 1] == data[j + 2]:
                    break
                j += 1
            out += bytes([j - i - 1]) + data[i:j]
            i = j
    out += b'\x00\x00'                  # end marker
    return bytes(out)


def main():
    idx = compose()

    prev = Image.new('RGB', (OW, OH))
    prev.putdata([RGB[v] for v in idx.flatten()])
    prev.resize((OW * 3, OH * 3 * 6 // 5), Image.NEAREST).save(
        os.path.join(HERE, 'splash_preview.png'))

    raw = to_cga(idx)
    packed = rle(raw)
    with open(os.path.join(HERE, 'splash.dat'), 'wb') as f:
        f.write(packed)

    # verify the decoder the .COM will use agrees with the encoder
    dec, i = bytearray(), 0
    while True:
        n = packed[i]
        if n == 0 and packed[i + 1] == 0 and len(dec) >= len(raw):
            break
        if n & 0x80:
            dec += bytes([packed[i + 1]]) * ((n & 0x7F) + 1)
            i += 2
        else:
            dec += packed[i + 1:i + 2 + n]
            i += 2 + n
    assert bytes(dec[:len(raw)]) == raw, 'RLE round-trip failed'

    used = np.bincount(idx.flatten(), minlength=4)
    print('splash.dat : %d bytes (from %d, %.0f%%)'
          % (len(packed), len(raw), 100.0 * len(packed) / len(raw)))
    print('pixels     : black %d  green %d  red %d  yellow %d'
          % tuple(used))
    print('preview    : tools/splash_preview.png')


if __name__ == '__main__':
    main()
