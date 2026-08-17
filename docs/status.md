# Status and roadmap

Where the machine actually is, and where it is going. Nothing here is aspirational
marketing: if something is listed as working it has been run on hardware.

## Working

| Feature | Detail |
|---|---|
| **Real CPU** | NEC V20 (µPD70108C-8) on the [top board](hardware.md), FPGA as the surrounding chipset |
| **8.33 MHz bus** | `c0` = 50 MHz ÷ 6 drives the CPU and the whole I/O bus, 1.67× the 5 MHz this ran at for most of its life. 10 MHz does not boot on the current V20 — [clkgen/pll](modules/clkgen-pll.md) |
| **Measured CPU clock** | POST times a calibrated loop against PIT channel 2 and prints the result, so the displayed rate is what the machine is *doing* rather than what a constant says — [bios](bios.md) |
| **Runs standalone** | FPGA configures from its own flash, BIOS from the on-board SPI flash, DOS from the USB disk — nothing attached but power and a monitor — [boot](boot.md) |
| **Boots MS-DOS 4.01** | The Dutch release shipped with the Philips P2120, **installed onto `C:` from its original install floppies** — see [storage](storage.md#installing-an-operating-system-onto-it). PC-DOS 3.30 runs too, from a served floppy image |
| **USB hard disk, `C:`** | Bulk-Only Transport and SCSI in the BIOS over the fabric host controller. `FDISK`, `FORMAT`, `CHKDSK` pass; 504 MB addressable — [storage](storage.md) |
| **CGA text** | Modes 0–3, 80×25 and 40×25, 16 colours — [vga](modules/vga.md) |
| **CGA graphics** | Modes 4, 5, 6 — 320×200×4 and 640×200×2 |
| **EGA graphics** | Mode 0Dh, 320×200×16 — four 64 KB bit planes in SDRAM behind a scanline buffer, the latch/ALU read-modify-write path, the 16-of-64 palette, and CRTC start-address page flipping. Commander Keen 4 runs on it — [vga](modules/vga.md) |
| **VGA output** | 640×480 @ 60 Hz on a real monitor, CGA doubled into it |
| **PS/2 keyboard** | Translated to XT scancodes, with a hardware Ctrl+Alt+Del — [ps2_kbd_ppi](modules/ps2_kbd_ppi.md) |
| **Floppy `A:`** | Served from a host over a 1 Mbaud serial link. Absent or muted, it reports NOT READY and the boot moves on — [fdc8272](modules/fdc8272.md) |
| **Floppy `B:`, 1.44 MB** | On the SPI flash; `FORMAT B:` works and the contents survive a reboot — [fixed disk](fixed-disk.md) |
| **8253 PIT** | 18.2 Hz system tick and speaker tone — [timer8253](modules/timer8253.md) |
| **8259A PIC** | Timer, keyboard and floppy interrupts — [int8259](modules/int8259.md) |
| **8237A DMA** | Channel 2 for floppy transfers, channel 0 refresh — [dma8237](modules/dma8237.md) |
| **8255 PPI** | Keyboard port, speaker gate, DIP switches — [ppi8255](modules/ppi8255.md) |
| **PC speaker** | Timer channel 2 gated through the PPI |
| **640 KB RAM, one speed** | All 640 KB reported to DOS and all of it SDRAM, so a program's timing no longer depends on where DOS loaded it. On-chip M9K is spent on the BIOS image and the disk buffer instead — [memory map](memory-map.md) |
| **Reliable cold boot** | Five power-ons in five. READY was arriving 14 ns behind the CPU clock against an 8 ns allowance, unmeasured because the pin was false-pathed; the whole off-chip CPU interface is now bounded from the µPD70108 datasheet — [gotchas](gotchas.md#the-handshake-cannot-govern-the-handshake) |
| **Standalone FPGA config** | `.jic` in the DE0-Nano's EPCS16, no JTAG needed at power-on — [building](building.md) |
| **USB host, full speed** | NRZI, bit stuffing, CRC5/CRC16, SOF, enumeration and bulk transfers, with event counters for diagnosis — [usb_host](modules/usb_host.md) |
| **Keyboard, extended keys** | Arrows, Home/End/PgUp/PgDn, Insert/Delete, right Ctrl, AltGr, keypad Enter — [ps2_kbd_ppi](modules/ps2_kbd_ppi.md) |
| **6845 CRTC registers** | `0x3D4`/`0x3D5` answer, so software can *detect* the card. Prince of Persia and Commander Keen both refused to start without this — [crtc6845](modules/crtc6845.md) |
| **Blinking text cursor** | Position and shape from CRTC R10/R11/R14/R15, scanlines doubled for the 16-line cell — [vga](modules/vga.md#text-cursor) |
| **AdLib at `0x388`** | Detection handshake, and nine channels rendered as square waves on the buzzer. Not FM synthesis — [opl2_lite](modules/opl2_lite.md) |
| **Runs real software** | Alley Cat, Digger, Sopwith, Pacman, Arkanoid, Prince of Persia, Commander Keen 4, the DOS utilities |

Nothing is currently known-broken. The last open item — booting the BIOS from SPI
flash — closed when the boot ROM stopped reading the image as one 64 KB burst; see
[gotchas](gotchas.md#a-long-spi-read-does-not-come-back-intact).

One known *gap* rather than a fault: CRTC `START` (R12/R13, the display start address)
is latched but not wired into [`vga`](modules/vga.md), so anything that scrolls by
moving it will not scroll. Software that redraws instead is unaffected.

**It was wired in once, and taken out again.** Honouring it made Commander Keen 4
overlap itself and shifted Arkanoid's *text* screen — and text is where the unit is
unambiguous and the arithmetic is a single addition, so the fault was not the
word-versus-cell doubling that graphics mode makes the obvious suspect. What was never
established is what it actually was; a likely candidate is that R1, the row length, is
hardcoded to 80 bytes in `vga` while a scrolling program may be changing it. Rather than
keep guessing with the screen as the only instrument,
[`SCROLLTST`](tools.md#scrolltst--does-the-display-start-address-land-where-it-should)
drives R12/R13 by a known amount against a pattern whose position can be read off the
screen. Run that first if this is picked up again.

## Planned

Roughly in the order they are likely to happen. Two budgets to keep in mind: **38 % of
the logic elements** and **49 % of the 608 Kbit of M9K** are committed. Both were much
tighter — 68 % and 70 % — before conventional memory moved wholly into PSRAM.

For anything that wants on-chip memory, **blocks matter more than bits**: 40 of the
device's 66 M9K blocks are in use, leaving **26 free**, and a block gives 8192 usable bits
in byte-wide mode however few of them you need.

### USB throughput

**Reads are 1.66× faster than they were**, and the remaining work is known. Measured
with [`USBPERF`](tools.md#usbperf--read-benchmark-and-regression-check), which reads a
fixed 256 KB at each transfer size:

| per call | before | after |
|---|---|---|
| 512 B | 49 KB/s | **69 KB/s** |
| 1 KB | 56 | **83** |
| 4 KB | 63 | **101** |
| 32 KB | 65 | **108** |
| 63.5 KB | 65 | **107** |

The gain came from replacing the per-byte `IN`/`STOSB`/`LOOP` copy with a single
`REP INSB` — see [storage](storage.md#the-80186-fast-path). Nothing changed on the
wire: transactions went 22157 → 22164, and the seven extra are exactly the seven extra
NAKs, with the integrity checksum unchanged.

That the numbers converge at 107–108 KB/s says the bottleneck is still the CPU rather
than the bus. What is left, in rough order of return:

1. **Memory-map the packet buffer** into M9K, so the copy becomes `REP MOVSB` from
   memory instead of a port read per byte
2. **A 512-byte hardware buffer**, so one command moves a whole sector rather than
   eight 64-byte packets
3. **DMA**, last — [`dma8237`](modules/dma8237.md) exists, but it is the biggest change
   for the smallest remaining multiple

Writes still use the byte loop. `REP OUTSB` is the same one-line change, but wants a
[`USBSOAK`](tools.md#usbsoak--sustained-write--read--verify) pass on a scratch stick
first, not on the disk with DOS installed on it.

### USB input — the mouse works, in real software

**A USB mouse drives `INT 33h` on this machine**, verified in *The Secret of Monkey
Island* and *Arkanoid*. `USBMSDRV.COM` enumerates a Logitech Unifying receiver on the
hybrid port, puts its mouse interface into boot protocol, and services it from **IRQ2 at
125 Hz**. `USBMOUSE.COM` is the standalone demo that proved the path first.

That those two games work is the specific thing worth testing, because they are what a
timer-based driver would have broken. Polling from `INT 08h` is the obvious approach and
the wrong one: PIT channel 0 gets reprogrammed by anything wanting its own tick rate, so
a driver hanging off it changes rate underneath itself or stops — on exactly the
software someone wants a mouse for. The poll clock is the USB frame counter instead
(`usb_host` CTRL bit 3), which nothing in DOS can touch.

What the device reports, read off it with
[`USBENUM`](tools.md#usbenum--what-is-plugged-in-and-how-to-drive-it):

| | |
|---|---|
| Device | `046D:C52B`, full speed, EP0 max packet **8** |
| Interface 0 | HID boot **keyboard**, `ep 81` IN, every 8 ms |
| Interface 1 | HID boot **mouse**, `ep 82` IN, every 2 ms |
| Interface 2 | vendor HID++, `ep 83` IN, every 2 ms |

Still open: **uninstall is not implemented**. `USBMSDRV /u` says so rather than
pretending. Doing it properly means finding the resident copy through the vector,
restoring both vectors from its data, masking IRQ2, clearing IRQEN and freeing the
block — and refusing when something else has hooked `INT 33h` afterwards. Reboot to
remove it.

The software cursor also writes straight to `B800`, so it can fight with an application
that redraws the same cell. A real driver would hide the cursor around video BIOS calls.

### USB keyboard

The other half of the same dongle, and mostly the same work. A HID boot-protocol
keyboard is one interrupt
endpoint polled every 10 ms with fixed 8-byte reports, and
[`ps2_kbd_ppi`](modules/ps2_kbd_ppi.md) already does the hard part downstream — HID usage
codes to XT scancodes is the same class of translation it performs today, and the
PPI-side interface would not change.

The caveat used to be that most keyboards are **low speed** (1.5 Mbps) while `usb_host`
is full-speed only, so this needed either a low-speed mode in the SIE — a different bit
rate, and keep-alive instead of SOF — or a full-speed device.

A **Logitech Unifying receiver is a full-speed device**, which makes it the way in. One
dongle presents three interfaces: a boot keyboard, a boot mouse, and a vendor HID++
channel. Boot protocol on the first two means fixed 8-byte reports and no HID
report-descriptor parsing, so the whole thing is software on the SIE that already
exists. [`USBENUM`](tools.md#usbenum--what-is-plugged-in-and-how-to-drive-it) reads the
layout off the device.

Low speed is still wanted eventually — it is what a *generic* wired mouse or keyboard
needs — but it is no longer what stands between this board and a working pointer.

Two things to know before writing that code. Its `bMaxPacketSize0` is **8**, which used
to truncate every descriptor read from it — `u_ctl` now takes the size from the device
instead of assuming 64, but `u_rq_cfg` still asks for only `U_BUFSZ` = 64 bytes of
configuration descriptor and this one is 84, so HID awareness needs a larger buffer or a
two-stage read; see [gotchas](gotchas.md). And there is no interrupt from `usb_host` yet, so a poll driven
from `INT 08h` runs at 18.2 Hz — 55 ms per sample, which is visibly steppy for a
pointer. `IRQ2` is free ([`int8259`](modules/int8259.md) has the port and the top level
ties it low) and is the eventual answer.

### Sound: real FM, then the DSP

The AdLib **front end** has landed — [`opl2_lite`](modules/opl2_lite.md) answers the
detection handshake at `0x388`/`0x389` and plays each of the nine channels as a square
wave, PWM-mixed onto the buzzer beside the PC speaker. What it is not is a synthesiser:
no operators, no envelopes, no rhythm mode, so notes never decay, the timbre is a square
wave rather than the patch the game chose, and percussion is silent.

AdLib came first on purpose. A Sound Blaster is an AdLib plus a DAC, and announcing one
commits the board to servicing DMA channel 1 and an interrupt — a game sets up a
transfer and waits for a completion IRQ, and if it never comes the game hangs. The AdLib
half promises nothing and cannot wedge anything, and it is the half that carries the
music in this era.

Two steps left, in order:

- **A real OPL2 core** behind the existing register decode: nine channels of
  two-operator FM, phase accumulators, an exponential/log sine table in M9K, and ADSR
  envelopes. The register file and per-channel state already exist, so this replaces the
  square-wave renderer rather than starting over.
- **Sound Blaster DSP** at `0x220` — the command interface, 8-bit DMA playback on
  channel 1, and the IRQ acknowledge at `0x22E`. [`dma8237`](modules/dma8237.md) is
  proven with the floppy and [`int8259`](modules/int8259.md) can raise IRQ 5, so the
  surrounding parts are in place.

Output stays PWM into the existing buzzer rather than a real DAC.

### EGA

**Mode 0Dh works.** 320x200x16, four bit planes, with the latch/ALU read-modify-write
path, the 16-of-64 palette and CRTC start-address page flipping. Commander Keen 4 runs on
it, and `EGAVFY` verifies every one of the 65536 plane offsets.

This section used to argue that the planes had to be on-chip, and that mode 0Dh fitted in
M9K as four 8 KB planes. Both halves were overtaken. The planes live in **SDRAM**, behind
a scanline buffer that decouples the raster from the memory, and they are **64 KB each,
not 8** -- which is what mode 0Dh actually needs once page flipping is in play. Keen 4
uses three pages, and with 8 KB planes and a 14-bit plane offset all three landed on the
first one; widening the offset to 16 bits is what fixed it.

So the memory argument that made this "the awkward one, and the reason it is last" no
longer applies to anything. The SDRAM has 32 MB, the planes occupy words `0`-`0x1FFFF` of
it, and conventional memory sits above them at word `0x20000`. Bandwidth is not tight
either: a row fetch is about 17.6 us of every 63.5, and the arbiter gives the display
strict priority over the CPU while still letting the CPU in between columns.

What is left is mode plumbing rather than memory:

- **Modes 0Eh and 10h** -- 640x200x16 and 640x350x16. These need a 350-line CRTC mode and
  the higher plane counts, but no new argument about where the pixels go.
- **Write modes 2 and 3**, and the colour-compare read mode, which mode 0Dh software
  mostly does not use.

The load-bearing assumption in the old plan -- that CGA's 16 KB and EGA's planes had to be
the same inferred RAM viewed two ways -- is gone with it. They are separate now, because
the EGA planes are not on-chip at all.

### Publish the schematics

Planned. The board is meant to be built by hand — see
[hardware](hardware.md#built-to-be-soldered-by-hand) — which is only true in practice once the
schematics are in the repository. They will be licensed separately from the code, most
likely under CERN-OHL-P, since MIT does not really fit a PCB.

## Ideas, unscheduled

- **Serial port that actually works** — [`com1_stub`](modules/com1_stub.md) currently
  answers COM1 probes as "absent" on purpose. The board's UART is committed to the host
  link, so a real 8250 would need the second one.
- **Move the erase/program sequence into VHDL** — a ~300-line state machine would make
  block loads roughly tenfold faster, at the cost of every bug meaning a reflash instead
  of a rebuild. The buffer itself is already in M9K; this is the remaining half of that
  idea. Reasoning in [fixed disk](fixed-disk.md#where-the-buffer-lives).
- **Real floppy drive** on a physical connector, instead of serving images.
- **Make `c0` a single parameter.** It is now 8.33 MHz, but the rate still lives in six
  places rather than one, and they must be kept in step by hand:

  | Where | What it sets |
  |---|---|
  | `pll.vhd` `clk0_divide_by` | the rate itself — **and** `DIV_FACTOR0` in the Retrieval info, see [clkgen/pll](modules/clkgen-pll.md#the-megawizard-metadata-can-disagree-with-the-hardware) |
  | `fdc8272` `CLK_FREQ` generic | the host link's baud divider — wrong and drive `A:` dies quietly. `BAUD_DIV` is an integer divide, so 8.33 MHz gives **1,041,667 baud** against the host's 1,000,000: 4.2 % fast, inside 8N1 tolerance but not comfortably. Only 10, 5 and 2 MHz divide exactly |
  | `opl2_lite` `CLK_HZ` generic | AdLib sample rate and both detection timers |
  | `sevenseg` `T_NIBBLE`/`T_BLANK` | raw cycle counts |
  | `busdecode` READY backstop | counted in CPU clocks, so its *duration* scales |
  | BIOS FDC and USB NAK budgets | iteration counts, so their duration scales too |

  The last two are the dangerous ones, because nothing breaks visibly when they are
  missed — a backstop that fires early returns undriven bus data, and a NAK budget that
  expires early makes a merely-busy stick pad a sector from its stale buffer and report
  success. Neither looks like a clock problem.

  **Speed grade is still undetectable.** An 8088, 8088-2 and 8088-1 are electrically
  identical; the grade is a marking on the package and a promise from Intel, exposed
  through no register and no pin. POST can identify an
  [instruction-set class](storage.md#the-80186-fast-path) because that is a difference
  in *behaviour*, but there is no equivalent for speed. Anything automatic here would be
  a stability *trial* — raise the clock, self-test, back off on failure — which also
  means surviving the failure well enough to do the backing off.
- **Composite/RGBI output** alongside VGA, for a period-correct monitor.
- **CP/M-80 software**, using the V20's 8080 emulation mode (`BRKEM`). Needs a host
  program on the DOS side rather than anything in the FPGA — a curiosity the CPU
  happens to make possible. See [hardware](hardware.md#about-the-cpu).

## Related

- [Architecture](architecture.md) — what a new subsystem has to fit into
- [Memory map](memory-map.md) — the address space these would claim
- [Gotchas](gotchas.md) — read before writing any 8088 code
