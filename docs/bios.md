# BIOS

Source: [`tools/xtbios_src.s`](../tools/xtbios_src.s) — GNU `as`, Intel syntax
Build: [`tools/mkbios.sh`](../tools/mkbios.sh) → `xtbios_claude.bin` (8 KB) and
`xtbios_claude.64k` (64 KB)

A minimal IBM PC/XT-class ROM BIOS. Visually it presents itself as
*"Gertieboard BIOS Retirement Edition"* — the name is not decoration, see
[why the project restarted](../README.md#a-short-history).

## The boot screen

The layout is a deliberate imitation of the BIOS in the author's family **Philips
P2120**, dumped from its own ROM chips. Same rows, same wording, same column alignment,
and — since the [character ROM](../tools/P2120/README.md) went into the FPGA too — the
same letter shapes.

The ROM identifies itself as `P3105 BIOS`, version 3.23, `JANUARY 16 1989`, which caused
a good deal of confusion about which machine was being copied. There is nothing to
choose between them: Philips shipped one BIOS across both models, and the P2120 dump is
byte-identical to the P3105 one (MD5 `59bf05a0c207efcb2981f1c9c6eb21e1`).

| Row | Content |
|---|---|
| 0 | `Philips ROM BIOS Version 1.00` |
| 1 | `Gertieboard BIOS Retirement Edition` |
| 2 | `2026 Mathijs van den Berg (mathijsvandenberg3@gmail.com)` |
| 4 | `                     Total  Base Extra` |
| 5 | `System Memory Found:   640   640     0 Kbytes` |
| 6 | `Parity Checking Enabled` |
| 8 | `Using Diskette Drive A:` |
| 9 | `Internal Hard Disk : Ready  2048 KB  (9D 60 15)` |
| 10 | `Booting...` |

Rows 3 and 7 are left blank. Rows 0–2, 4–6, 8 and 10 are written by `putrow` during
POST; row 9 is filled in later by `hd_detect`.

Row 9 uses the original's own wording — `Internal Hard Disk : ` followed by `Ready` or
`NOT READY`, both lifted from the P3105 ROM's string table — and the same `0x07`
attribute as every other row. It was briefly yellow (`0x0E`), which made the disk easy
to spot but is not something the real machine ever did.

The **raw JEDEC ID** in brackets is the one deliberate departure. The original printed no
such thing, but it is the only item on screen that proves the chip answered and says
*which* chip: a wrong part reads as a different ID and a missing one as `FF FF FF`. Drop
`b_hd_idl`/`b_hd_idr` from `hd_detect` if you would rather have the line exact.

Two details are homage rather than fact. `Parity Checking Enabled` is printed by a
machine with no parity memory to check, and the `Extra` column is always zero because
there is nothing above 640 KB. Both are kept because the original said them.

Exactly **three** strings are byte-for-byte from the P3105 ROM — the column header with
its precise spacing, `Parity Checking Enabled`, and `Booting...`. The other twenty are
ours; the memory and drive lines only *look* like the original because they were
retyped to match, not copied. See the
[third-party note](../README.md#third-party-content).

The strings are drawn **directly to `0xB8000`** by `putrow` during POST, before the PIC,
the PIT or `STI` — so the screen appears even when the interrupt controller or the timer
is broken. That has repeatedly been the difference between a diagnosable failure and a
dark monitor.

> The memory line is a hardcoded string, not a formatted value. It once read `632 KB`
> while the BDA said 640, which made the POST screen useless as a build indicator and
> sent a debugging session down a false path. See [gotchas](gotchas.md).

## Layout and build

The image is **8 KB**, linked at F-segment offset `0xE000` — physical
`0xFE000`–`0xFFFFF` — with the reset vector placed by a separate `.reset` section:

```bash
as --32 xtbios_src.s -o xtbios.o
ld -m elf_i386 -Ttext=0xC000 --section-start=.reset=0xFFF0 \
   --oformat=binary -e _post xtbios.o -o xtbios_claude.bin
python make64k.py xtbios_claude.bin -o xtbios_claude.64k
```

`make64k.py` places the 16 KB image at offset `0xC000` of a 64 KB file and fills the
rest with `0xFF`, so the whole F-segment has defined content and the reset vector
lands at `0xFFF0` of the image.

**Use `bash tools/mkbios.sh`** rather than running those by hand. It does all three
steps under `set -e`, runs [`tools_equcheck.py`](../tools/tools_equcheck.py) over the
source first, and then verifies the result: the `.bin` is exactly 16384 bytes, the
`.64k` is 65536, the image really sits at offset `0xC000`, the reset vector at `0xFFF0`
is a far jump into segment `F000`, and everything below is `0xFF` fill.

> That script exists because a hand-built chain once failed silently — a `grep` in the
> middle returned non-zero, the `&&` short-circuited, `make64k.py` never ran, and a
> **two-day-old** `.64k` kept being served while the freshly built `.bin` looked
> perfect. Every apparent fix changed nothing. See [gotchas](gotchas.md).

### `.arch i8086` is mandatory

```asm
.code16
.arch i8086
.intel_syntax noprefix
```

Without it, `as --32` silently emits instructions the 8088 does not have. This is not
theoretical — it happened twice and cost days both times. See
[gotchas](gotchas.md#the-8088-opcode-trap).

## POST

1. `CLI`, `CLD`, `DS = 0xF000`, `SS = 0`, `SP = 0x7C00`
2. **Video first**, before any PIC/PIT/`STI`: `vid_init` programs the 6845 CRTC from
   `crtc_80x25`, sets `0x3D8 = 0x29` and `0x3D9 = 0x30`, and clears the text page.
   The banner is then written straight to `0xB8000` with `putrow`, so the screen
   appears even if the interrupt controller or timer is broken
3. 8259 PIC — ICW sequence, vector base `0x08`
4. 8253 PIT — counter 0 mode 3 divisor 0 (18.2 Hz), counter 1 mode 2
5. 8255 PPI — control word `0x99`, port B `0x0C`
6. BIOS data area (below)
7. Interrupt vector table — all 256 entries to `_dummy_int`, then the real handlers
8. `hd_detect` — SPI flash JEDEC ID, decoded size, printed on row 9
9. `INT 19h`

## Interrupt services

### INT 10h — video

| AH | Function |
|---|---|
| `00` | Set video mode — text 0–3, and CGA graphics 4, 5, 6 |
| `01` | Set cursor type |
| `02` | Set cursor position |
| `03` | Get cursor position |
| `06` | Scroll window up |
| `07` | Scroll window down |
| `08` | Read character and attribute at cursor |
| `09` | Write character and attribute |
| `0A` | Write character |
| `0B` | Set colour / palette (CGA `0x3D9`) |
| `0E` | Teletype output |
| `0F` | Get video mode — returns columns from the BDA |

**Graphics-mode text.** `INT 10h/0E` normally writes character+attribute pairs to
`0xB8000`, which means nothing in a graphics mode — it paints 8 pixels of noise per
character. When the current mode is 4, 5 or 6, the handler instead renders an **8×8
glyph** into the framebuffer (`g_render`), handling the even/odd interleave, cursor
advance, newline and scroll. Foreground is colour 3, background 0.

The 8×8 font is [`tools/font8x8.bin`](../tools/font8x8.bin), `.incbin`'d into the
image. It comes **straight from the Philips P2120 character ROM**, which holds a native
8×8 page alongside the 16-row font — so no squashing is involved and the graphics-mode
text is the same typeface as the text-mode display.

> It used to be derived from [`font.vhd`](../font.vhd) by OR-ing row pairs, because
> that was a genuine 8×16 font and dropping alternate rows loses crossbars. The real
> ROM having its own 8×8 page made that hack unnecessary. See
> [`tools/mkfont_p2120.py`](../tools/mkfont_p2120.py).

> Only `AH=0E` is hooked. `AH=09`/`0A` still write raw character cells in graphics
> modes.

### INT 13h — disk

Three drives, dispatched on `DL` alone — `0x00` to the serial floppy, `0x01` to the
[SPI flash](fixed-disk.md), anything with bit 7 set to the
[USB disk](storage.md#drive-c--usb-mass-storage). See [storage](storage.md) for how the
three fit together.

The flash drive is a **floppy** now, so it answers the floppy surface: `AH=05`, `16`,
`17` and `18` matter to `FORMAT`, and without `AH=18` it reports *"Invalid media or
Track 0 bad"*.

| AH | Floppy | Fixed disk |
|---|---|---|
| `00` | Reset | Reset (and the write **commit** point) |
| `01` | Last status | Last status |
| `02` | Read sectors | Read sectors |
| `03` | Write sectors | Write sectors |
| `04` | Verify | Verify |
| `08` | Get parameters | Get parameters |
| `09` | — | Initialise drive-pair characteristics (no-op) |
| `0C` | — | Seek (no-op) |
| `0D` | — | Alternate reset (commits) |
| `10` | — | Test drive ready (no-op) |
| `11` | — | Recalibrate (no-op) |
| `14` | — | Controller diagnostic (no-op) |
| `15` | Get disk type | Get disk type |

> `AH=09` and `AH=14` matter more than they look: answering "invalid function" to them
> can make FDISK decide there is no usable controller.

### INT 16h — keyboard

| AH | Function |
|---|---|
| `00` | Read keystroke (blocking) |
| `01` | Check for keystroke — ZF in the caller's stacked flags |
| `02` | Get shift status |
| `10` | Read **enhanced** keystroke → mapped to `00` |
| `11` | Check **enhanced** keystroke → mapped to `01` |
| `12` | Get **enhanced** shift status → mapped to `02` |

> The enhanced calls are not optional. DOS 3.x/4.x use `00`/`01`/`02`, but **DOS 5 and
> 6 prefer `10`/`11`/`12`**. Falling through to a bare `iret` returned the *caller's*
> flags, so `AH=11`'s "is a key ready?" answered with a garbage ZF and the keyboard
> appeared completely dead on DOS 5/6 while working fine on 3/4.

### INT 1Ah — time of day and RTC

| AH | Function |
|---|---|
| `00` | Get tick count |
| `01` | Set tick count |
| `02` | Read RTC time — returns a **fixed** BCD value |
| `03` | Set RTC time — accepted and ignored |
| `04` | Read RTC date — fixed BCD value |
| `05` | Set RTC date — accepted and ignored |

There is no CMOS RTC, so DOS would prompt for the date and time at every boot.
Answering `02`/`04` with a valid BCD value (default **30-07-2026, 19:00:00**, editable
via the `RTC_*` equates) makes DOS accept it and move on; it then keeps time from the
`INT 08h` tick. `CF` must be returned **clear** to mean "RTC present", which the
handlers do by clearing it in the stacked FLAGS image rather than with `CLC`.

Pair this with an `AUTOEXEC.BAT` on the boot disk — DOS only prompts when one is
absent.

### Other vectors

| Vector | Purpose |
|---|---|
| `INT 08h` | Timer tick: 32-bit counter at `0x6C`, midnight wrap, floppy motor timeout, chains `INT 1Ch` |
| `INT 09h` | Keyboard: scancode → ring buffer, shift/ctrl/alt state, Ctrl+Alt+Del → `_reboot` |
| `INT 11h` | Equipment list from BDA `0x10` |
| `INT 12h` | Memory size from BDA `0x13` |
| `INT 19h` | Bootstrap — see [boot flow](boot.md) |
| `INT 1Eh` | Points at `_floppy_dpt` |

`_reboot` far-jumps to `F000:FFF0`. That is a **warm** boot: the overlay is not
re-armed, so the BIOS already in PSRAM re-runs. The hardware Ctrl+Alt+Del in
[`ps2_kbd_ppi`](modules/ps2_kbd_ppi.md) is the one that produces a genuine cold boot,
and it cannot be bypassed by software that hooks `INT 09h`.

## BIOS data area (segment `0x40`)

Standard fields:

| Offset | Size | Contents |
|---|---|---|
| `0x10` | word | Equipment word — `0x0021`: 1 floppy, 80×25 colour |
| `0x13` | word | Base memory in KB — **640** |
| `0x17` | byte | Keyboard shift flags |
| `0x1A` / `0x1C` | word | Keyboard buffer head / tail |
| `0x1E`–`0x3D` | 32 B | Keyboard ring buffer |
| `0x40` | byte | Floppy motor-off countdown |
| `0x49` | byte | Current video mode |
| `0x4A` | word | Text columns |
| `0x4C` | word | Video page size |
| `0x50` | word | Cursor position |
| `0x63` | word | CRTC port — `0x03D4` |
| `0x65` / `0x66` | byte | `0x3D8` / `0x3D9` shadow copies |
| `0x6C`–`0x6F` | dword | Timer tick count |
| `0x70` | byte | Timer overflow (midnight) flag |
| `0x74` | byte | Last fixed-disk status |
| `0x75` | byte | **Number of fixed disks** — 1 when the USB disk enumerated, else 0 |
| `0x80` / `0x82` | word | Keyboard buffer start / end |
| `0x96` / `0x97` | byte | Keyboard status flags 3 and 4 — **not scratch space**, see below |
| `0xA8`–`0xAF`, `0xB4`–`0xB5` | — | Floppy scratch (count, drive, head, cyl, sector, buffer) |
| `0xB0`–`0xB2` | byte | Floppy geometry for `AH=08`, captured from the boot sector's BPB |
| `0xB6` | byte | FDC timeout flag |
| `0xB7` | byte | "Drive A: answered at POST" — read by `INT 19h` only |
| `0xB8`–`0xBA` | word | POST checksum of the code region, and its length |

> ⚠️ **The floppy scratch used to live at `0x90`–`0x99`.** That overlaps `0x96`/`0x97`,
> the keyboard status flags, so every disk access wrote a buffer offset through them and
> the keyboard grew phantom modifier keys — but only on DOS 4 and later, which are the
> versions that read those bytes. And `0xB0`–`0xB2` is not free either: it holds the
> floppy geometry, and the read path uses it. Full allocation table in
> [gotchas](gotchas.md#scratch-space-in-the-bios-data-area-is-not-free).

Custom fields, all in the reserved `0xE0`+ area:

| Offset | Size | Contents |
|---|---|---|
| `0xE0` | byte | SPI flash manufacturer ID |
| `0xE1` | byte | SPI flash memory type |
| `0xE2` | byte | SPI flash capacity code |
| `0xE4` | word | Flash size in KB (0 = unknown) |
| `0xE6` | word | Cached fixed-disk block (`0xFFFF` = none) |
| `0xE8` | byte | Cached block dirty flag |
| `0xEA` / `0xEB` | byte | CHS conversion scratch |
| `0xEC` | byte | Transfer direction (0 = read, 1 = write) |
| `0xED` / `0xEF` | word | Caller's buffer segment / offset |
| `0xF1` | word | Current LBA |
| `0xF3` | byte | Sectors remaining |
| `0xF5` | word | Byte offset within the cached block |

> **The full 640 KB.** The fixed disk's 4 KB read-modify-write buffer used to occupy
> the top 8 KB of conventional memory at `0x9E000`, which is the classic way for a BIOS
> to keep private RAM, and it cost 8 KB of DOS memory. It now lives in on-chip M9K at
> `0xE0000` (`HDBUF_SEG`), outside conventional memory, so the reported size went back
> to 640.
>
> This value and the `b_mem` banner string are **two separate literals**. Change one and
> you must change the other — a mismatch between them once made the POST screen useless
> as a build indicator. See [gotchas](gotchas.md).

## SPI flash identification

`hd_detect` runs at the end of POST, issues `RDJDID` (`0x9F`) through the
[`flash`](modules/flash.md) engine, and prints row 9:

```
Internal Hard Disk : Ready  2048 KB  (9D 60 15)
```

The **raw ID bytes are always shown** next to the decoded size, so a wrong or absent
chip is visible rather than silently mis-decoded — all `00` or all `FF` means MISO
never answered. Size in KB is `1 << (capacity - 10)`, guarded to capacity codes
`0x10`–`0x1F`.

> The display routines read their strings via `DS:SI`, but `hd_detect` runs with
> `DS = BDA`. It sets `DS = CS` for the display part; forgetting that prints garbage.

## Debug switches

Two assemble-time equates near the fixed-disk code:

| Switch | Default | Effect |
|---|---|---|
| `HD_ENABLE` | `1` | Route `DL = 0x01` to the SPI flash drive. Set to `0` to bisect a boot failure without removing the code |
| `HD_DEBUG` | `0` | Report flash-drive activity on the port-`0x80` 7-segment display |

With `HD_DEBUG = 1`: raw `AH` on entry, `B8` when `AH=08` returns, `B2` when a
transfer completes, `C1` when a call is refused because no disk is advertised, `C9`
for an unsupported function.

## Space

The image is **16 KB**, linked at `F000:C000`. It outgrew 8 KB during the USB work —
that build was using 8191 of 8192 bytes — and the reset vector needed no change because
it jumps to the `_post` *symbol*. The bootloader has always loaded the full 64 KB
F-segment, so there is room to grow again.

> A `.equ` used **above** its definition assembles as a memory operand rather than an
> immediate, silently. `cmp dl, HD_DRIVE` became `cmp dl,[0x1]` and cost a hardware
> debugging session; so did `cmp bx, U_BUFSZ`, which became a comparison against the
> BDA's floppy motor counter. `tools/tools_equcheck.py` now fails the build on it.

## Related

- [Boot flow](boot.md) — how this image gets into memory
- [Storage](storage.md) — the three drives behind `INT 13h`
- [Fixed disk](fixed-disk.md) — the SPI flash drive in detail
- [Tools](tools.md) — the DOS diagnostics
- [Gotchas](gotchas.md) — **read this before editing the BIOS**
