# vga

Source: [`vga.vhd`](../../vga.vhd) · Instance `vga1` · Clocks `c1` (25 MHz pixel) and
`c0` (5 MHz CPU port) · Font: [`font.vhd`](../../font.vhd), decoded from a real
Philips P2120 character ROM by [`tools/mkfont_p2120.py`](../../tools/mkfont_p2120.py)

A CGA-compatible display adapter with its own 16 KB of video RAM, outputting VGA
timing so a modern monitor can display it.

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK_VGA` | IN | 1 | 25 MHz pixel clock (`c1`) |
| `CLK_CPU` | IN | 1 | 5 MHz bus clock (`c0`) — the CPU-side port |
| `RESET` | IN | 1 | Synchronous, active high |
| `ADDR` | IN | 20 | Memory address |
| `DATAIN` | IN | 8 | Memory write data |
| `WR` | IN | 1 | `/MEMW`, active low |
| `RD` | IN | 1 | `/MEMR`, active low |
| `IOADDR` | IN | 16 | I/O address — for the mode/colour registers |
| `IOWR` | IN | 1 | I/O write strobe, active low |
| `HS` | OUT | 1 | Horizontal sync → `VGA_HS` |
| `VS` | OUT | 1 | Vertical sync → `VGA_VS` |
| `RGB` | OUT | 6 | Colour, `RRGGBB` → `VGA_RGB` |
| `DATAOUT` | INOUT | 8 | CPU read-back of video RAM, tri-state |
| `DEBUG` | OUT | 1 | Left `OPEN` in the top level |

## Addresses

| Address | Access | Function |
|---|---|---|
| `0xB8000`–`0xBBFFF` | R/W | 16 KB video RAM (decoded as `ADDR(19:14) = "101110"`) |
| I/O `0x3D8` | W | Mode control |
| I/O `0x3D9` | W | Colour select |

The companion status port `0x3DA` lives in [`cga_status`](cga_status.md).

### Mode control — `0x3D8`

| Bit | Meaning |
|---|---|
| 0 | 80-column text |
| 1 | **graphics mode** |
| 2 | black-and-white (mode 5 palette) |
| 3 | **video enable** |
| 4 | 640×200 one-bit-per-pixel (mode 6) |
| 5 | blink |

Power-on default `0x29` = 80×25 text, video on, blink.

### Colour select — `0x3D9`

| Bits | Meaning |
|---|---|
| 3:0 | background/border colour (foreground in mode 6) |
| 4 | intensity |
| 5 | palette select: 0 = green/red/brown, 1 = cyan/magenta/white |

Power-on default `0x20`.

## Video timing

VGA 640×480-style timing at 25 MHz: 800 × 525 total, with the active area
restricted to **640 × 400**. That is exactly 2× CGA's 320×200 in both axes, so
graphics modes are produced by pixel doubling with no timing change.

```
HS   low while X < 96
VS   low while Y < 2
active  X in (144, 784)  and  Y in (34, 435)
```

## Supported modes

| Mode | Resolution | Colours | Notes |
|---|---|---|---|
| 0–3 | 80×25 text | 16 fg / 16 bg | Attribute bit 7 is treated as background intensity, giving a full 16/16 palette rather than blink |
| 4 | 320×200 | 4 | 2 bits per pixel, each CGA pixel doubled 2×2 |
| 5 | 320×200 | 4 | as mode 4 with the black-and-white palette (cyan/red/white) |
| 6 | 640×200 | 2 | 1 bit per pixel, doubled vertically only |

40-column text modes render as 80-column. There is no EGA/VGA support — no planar
memory at `0xA0000` and no `0x3C0` register file.

## Video RAM organisation

The 16 KB is split into two 8 KB halves so the scan-out side can read a character
and its attribute (or two adjacent graphics bytes) in the same cycle:

- `MEMC` — even byte offsets (`ADDR(0) = '0'`); in text mode, characters
- `MEMA` — odd byte offsets (`ADDR(0) = '1'`); in text mode, attributes

The CPU sees a flat 16 KB page, exactly the layout DOS and the BIOS expect.

Graphics modes use the classic CGA **interleave**: even scanlines at offset
`0x0000`, odd scanlines at `0x2000`, 80 bytes per scanline.

```
graphics byte address = (cga_y & 1) * 0x2000 + 80 * (cga_y / 2) + cga_x / 4
```

## Colour decode

`cga_to_rgb()` maps the 4-bit CGA IRGB value to 6-bit `RRGGBB`, following the IBM
palette — including colour 6 being **brown**, not yellow-green.

In graphics modes, pixel value `00` takes the background colour from `0x3D9`, and
`01`/`10`/`11` come from the selected palette. Mode 6 uses the `0x3D9` low nibble
as the foreground.

## Text cursor

Fed from [`crtc6845`](crtc6845.md): `CURSOR` is the cell (R14/R15), `CUR_TOP`/`CUR_BOT`
the first and last scanline (R10/R11), `CUR_MOD` the blink select (R10 bits 6:5). The
BIOS had been writing all four since day one; until `crtc6845` existed there was nothing
on the other end of those writes, so there was no cursor at all.

**Scanlines double.** The BIOS programs a genuine CGA -- `R9 = 7`, so eight lines to a
cell, cursor on lines 6 and 7. This display is 400 active lines with **sixteen** to a
cell, every CGA scanline drawn twice, so the cursor's lines double with everything else:

```vhdl
cur_first <= CUR_TOP(3 DOWNTO 0) & '0';   -- first * 2
cur_last  <= CUR_BOT(3 DOWNTO 0) & '1';   -- last * 2 + 1
```

Taken literally, lines 6-7 of sixteen would sit across the middle of the character
instead of under it. Doubling also turns a two-line CGA cursor into four lines here,
which is the same fraction of the cell and matches how the glyph itself is stretched.

**The cell match rides the pipeline.** The pixel path is two registers deep
(`vga_idx` -> `MEMCHR` -> `CHAR`), so the comparison is made beside `vga_idx` and then
registered twice, alongside `MEMCHR` and then alongside `CHAR`. A single compare would
draw the cursor two pixels away from its own cell. The *row* match needs no delay --
it depends only on `YY`, which is constant for a whole scanline, which is why `GetChar`
already uses `YY` directly.

**Blink** comes from a field counter: `frame_cnt(3)` is 8 fields on and 8 off, about
3.7 Hz at 59.5 Hz. `CUR_MOD = "01"` means cursor-off and is honoured; `"11"` selects the
slower rate. Everything else blinks, *including* the `00` this BIOS writes -- a datasheet
reading of those bits calls `00` non-blinking, but a machine of this era blinks with
exactly that value, and reproducing the machine is the point.

Two behaviours fall out for free: a first line set *above* the last hides the cursor
(how software does it without touching the blink bits), and the cursor is drawn in the
cell's own foreground colour, so it inherits whatever the text under it is using rather
than being hardcoded white.

Costs 17 registers and no measurable logic. `clk[1]` keeps 24 ns of slack.

## CPU read-back

```vhdl
DATAOUT <= MEM_DOUT_CPU WHEN (RD = '0' AND ADDR(19 DOWNTO 14) = "101110")
           ELSE "ZZZZZZZZ";
```

Read-back works in graphics mode as well as text, which matters because masked
sprite blitting does read-modify-write on the framebuffer.

## Verified on hardware

The whole CGA path has been tested with the `CGATEST*` utilities (see
[tools](../tools.md)): the `0x3D8`/`0x3D9` latches, video enable, the even/odd
interleave, the 2-bpp palette, BIOS mode-set, `rep movsw` writes, read-back in
graphics mode, and masked read-modify-write sprites.

## Related

- [cga_status](cga_status.md) — the `0x3DA` status port games poll for retrace
- [BIOS](../bios.md) — `INT 10h`, including the 8×8 glyph renderer used when text
  is printed while in a graphics mode
