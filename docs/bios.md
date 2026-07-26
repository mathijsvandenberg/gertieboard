# BIOS

Source: [`tools/xtbios_src.s`](../tools/xtbios_src.s) — GNU `as`, Intel syntax
Build: [`tools/mkbios.sh`](../tools/mkbios.sh) → `xtbios_claude.bin` (8 KB) and
`xtbios_claude.64k` (64 KB)

A minimal IBM PC/XT-class ROM BIOS. Visually it presents itself as
*"Gertieboard BIOS Pensioen Edition"*, styled after the Philips P3105 boot screen.

## Layout and build

The image is **8 KB**, linked at F-segment offset `0xE000` — physical
`0xFE000`–`0xFFFFF` — with the reset vector placed by a separate `.reset` section:

```bash
as --32 xtbios_src.s -o xtbios.o
ld -m elf_i386 -Ttext=0xE000 --section-start=.reset=0xFFF0 \
   --oformat=binary -e _post xtbios.o -o xtbios_claude.bin
python make64k.py xtbios_claude.bin -o xtbios_claude.64k
```

`make64k.py` places the 8 KB image at offset `0xE000` of a 64 KB file and fills the
rest with `0xFF`, so the whole F-segment has defined content and the reset vector
lands at `0xFFF0` of the image.

**Use `bash tools/mkbios.sh`** rather than running those by hand. It does all three
steps under `set -e` and then verifies the result: the `.bin` is exactly 8192 bytes,
the `.64k` is 65536, the image really sits at offset `0xE000`, the reset vector at
`0xFFF0` is a far jump into segment `F000`, and everything below is `0xFF` fill.

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
image. It was generated from the hardware 8×16 font in [`font.vhd`](../font.vhd) by
OR-ing row pairs — `font.vhd` is a genuine 8×16 font, not a doubled 8×8, so dropping
alternate rows loses crossbars. OR-ing keeps every feature, slightly bold.

> Only `AH=0E` is hooked. `AH=09`/`0A` still write raw character cells in graphics
> modes.

### INT 13h — disk

`DL < 0x80` goes to the floppy path; `DL >= 0x80` to the
[SPI-flash fixed disk](fixed-disk.md).

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
| `0x13` | word | Base memory in KB — **632**, not 640 (see below) |
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
| `0x75` | byte | **Number of fixed disks** — 1 |
| `0x80` / `0x82` | word | Keyboard buffer start / end |
| `0x90`–`0x9F` | — | Floppy scratch (count, drive, head, cyl, sector, buffer, page) |
| `0xB0`–`0xB2` | byte | Floppy geometry for `AH=08`, captured from the boot sector's BPB |

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

> **632 KB, not 640.** The top 8 KB of conventional memory (`0x9E000`+) is the fixed
> disk's 4 KB read-modify-write buffer — the classic way for a BIOS to keep private
> RAM. If that is ever raised back to 640, `HDBUF_SEG` must move first.

## SPI flash identification

`hd_detect` runs at the end of POST, issues `RDJDID` (`0x9F`) through the
[`flash`](modules/flash.md) engine, and prints row 9:

```
Fixed Disk: ID 9D 60 15  2048 KB SPI flash
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
| `HD_ENABLE` | `1` | Route `DL >= 0x80` to the SPI fixed disk. Set to `0` to bisect a boot failure without removing the code |
| `HD_DEBUG` | `0` | Report fixed-disk activity on the port-`0x80` 7-segment display |

With `HD_DEBUG = 1`: raw `AH` on entry, `B8` when `AH=08` returns, `B2` when a
transfer completes, `C1` when a call is refused because no disk is advertised, `C9`
for an unsupported function.

## Space

The 8 KB image has roughly 1 KB free. The full 64 KB F-segment is available if a
larger addition is ever needed, but staying at 8 KB avoids re-validating how much of
the segment the bootloader loads.

## Related

- [Boot flow](boot.md) — how this image gets into memory
- [Fixed disk](fixed-disk.md) — the `INT 13h` `DL >= 0x80` implementation
- [Tools](tools.md) — the DOS diagnostics
- [Gotchas](gotchas.md) — **read this before editing the BIOS**
