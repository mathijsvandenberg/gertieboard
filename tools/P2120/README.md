# Philips P2120 ROM images

The ROMs from the author's father's Philips **P2120** — the first PC in the house,
driven by a Philips **7BM723** monochrome monitor. Its chips were pulled and dumped
years later, and they are the reference this machine's look is copied from.

**The `.bin` files are gitignored and not in the repository.** They are dumps of
commercial Philips ROMs and are not ours to redistribute — the same policy as
[`tools/philips.asm`](../philips.asm). Put them back here if you want to regenerate
anything:

| File | Device | Size | Contents |
|---|---|---|---|
| `Philips_P2120_61683_bios_27C256_U9.bin` | 27C256 | 32 KB | System BIOS |
| `Philips_27C64_U44.bin` | 27C64 | 8 KB | Character generator ROM |

## The BIOS is the same one

`Philips_P2120_61683_bios_27C256_U9.bin` is **byte-identical** (MD5
`59bf05a0c207efcb2981f1c9c6eb21e1`) to the dump already used as a reference, and it
identifies itself internally as:

```
Philips ROM BIOS Version    3.23
P3105 BIOS
JANUARY 16 1989
```

So Philips shipped one BIOS across both models. The long-standing confusion over
whether the boot screen was copied from a P2120 or a P3105 has no answer, because
there is nothing to choose between: they are the same ROM. See
[docs/bios.md](../../docs/bios.md#the-boot-screen).

## The character ROM is used

[`tools/mkfont_p2120.py`](../mkfont_p2120.py) decodes `Philips_27C64_U44.bin` into
both fonts this machine displays:

- [`font.vhd`](../../font.vhd) — the FPGA's 8×16 text font
- [`tools/font8x8.bin`](../font8x8.bin) — the 8×8 font the BIOS draws in CGA
  graphics modes

The decode was worked out empirically; the reasoning, the layout, and the artifact
the ROM carries at the bottom of descender glyphs are all documented in the script's
header.

The derived bitmaps **are** committed, so a clone builds without these files. You
only need them to change the font.
