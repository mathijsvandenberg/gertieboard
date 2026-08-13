# Gertieboard

An IBM PC/XT-class computer built around a **real, physical CPU**, with the entire
rest of the chipset implemented in an FPGA.

![The Gertieboard Mini XT, assembled](docs/images/gertieboard-rev100.jpg)

Two stacked boards. The **Gertieboard Mini XT** top board carries everything that
had to be physical; a stock **Terasic DE0-Nano** underneath carries the FPGA.

```
   +----------------------------------------------------------+
   |  GERTIEBOARD MINI XT  -  MVDB 2021 REV 100                |
   |                                                            |
   |    NEC V20 CPU  .  PSRAM  .  SPI FLASH (2 MB)             |
   |    VGA  .  PS/2 keyboard  .  2x USB  .  FTDI 3V3 serial   |
   |    7-segment POST display  .  buzzer  .  reset button     |
   +----------------------------------------------------------+
                  |  2x 40-pin GPIO
   +----------------------------------------------------------+
   |  Terasic DE0-Nano  (Cyclone IV EP4CE22F17C6)              |
   |                                                            |
   |    the chipset: bus decode, memory controller, CGA,        |
   |    8259 PIC, 8253 PIT, 8255 PPI, 8237 DMA, 8272 FDC,       |
   |    keyboard controller, USB host controller, boot ROM      |
   |                                                            |
   |    also on it, unused: 32 MB SDRAM, accelerometer, ADC     |
   +----------------------------------------------------------+
```

The CPU could have been a soft core in the FPGA, but putting a genuine processor
on the board was the point of the exercise: the FPGA plays the role the
surrounding chipset played in 1983, and nothing more.

Full inventory of both boards: **[docs/hardware.md](docs/hardware.md)**.

## What it does today

- **Runs standalone.** No host, no JTAG: the FPGA configures itself from its own
  flash, the BIOS is fetched from the on-board SPI flash, and DOS boots from a USB
  hard disk. A serial host is used for BIOS development, not to run the machine.
- Boots **MS-DOS 4.01** — the Dutch release that shipped with the Philips P2120,
  installed onto the USB disk from its original three floppies. **IBM PC-DOS 3.30**
  runs too, from a served floppy image
- **USB hard disk** as drive `C:` — a full-speed host controller in fabric with a
  Bulk-Only Transport and SCSI stack in the BIOS. `FDISK`, `FORMAT` and `CHKDSK`
  all pass; 504 MB addressable
- **CGA** 80×25 colour text plus graphics modes 4, 5 and 6, output as 640×480 VGA
- **EGA** mode 0Dh, 320×200×16 — four 64 KB bit planes in SDRAM, with the latch/ALU
  read-modify-write path, the 16-of-64 palette, and CRTC start-address page flipping.
  Commander Keen 4 runs on it
- **PS/2 keyboard** with extended keys, AltGr, and a hardware Ctrl+Alt+Del that no
  software can bypass
- **Two floppy drives**: `A:` served over serial from a host loader, `B:` a
  1.44 MB drive backed by the on-board SPI flash
- 640 KB RAM, PC speaker, 8253 timer, 8259 PIC, 8237 DMA, 8255 PPI
- Runs real software: Alley Cat, Digger, Sopwith, Pacman, the DOS utilities

### On the list

| | Planned |
|---|---|
| **USB throughput** | ~85 KB/s today, and the bottleneck is the CPU's byte-at-a-time copy, not the wire. Memory-mapping the packet buffer into M9K makes it a `rep movsb` |
| **USB keyboard** | The SIE exists now, so mostly a matter of low-speed support — most keyboards are 1.5 Mbps |
| **AdLib / Sound Blaster** | The DMA controller and PIC are already there and proven; an OPL2 at `0x388` is the self-contained first step |
| **EGA modes 0Eh and 10h** | Mode 0Dh works. The higher modes need 64 KB and 112 KB of planar memory and a 350-line CRTC; the planes are in SDRAM now, so the memory argument is settled and what remains is the mode plumbing |

Full detail, including why each item is hard and what it needs, is in
**[Status and roadmap](docs/status.md)**.

## Documentation

Start at **[docs/README.md](docs/README.md)**.

| Page | Contents |
|---|---|
| [Hardware](docs/hardware.md) | The two boards: what is on each, and what is deliberately unused |
| [Architecture](docs/architecture.md) | System overview, clock tree, reset, bus cycles, DMA, interrupts |
| [Memory map](docs/memory-map.md) | Memory regions and the complete I/O port map |
| [Modules](docs/modules/README.md) | Every FPGA module: entity ports, addresses, behaviour |
| [Pinout](docs/pinout.md) | FPGA pin assignments |
| [Boot flow](docs/boot.md) | Reset, boot ROM overlay, serial and flash BIOS paths |
| [BIOS](docs/bios.md) | Interrupt services, BIOS data area, build |
| [Storage](docs/storage.md) | The three drives: serial `A:`, flash `B:`, USB `C:` |
| [Fixed disk](docs/fixed-disk.md) | The SPI-flash drive in detail: block buffer, erase/program |
| [Building](docs/building.md) | Toolchain, scripts, programming the board |
| [Tools](docs/tools.md) | DOS diagnostics and host-side utilities |
| [Status and roadmap](docs/status.md) | What works, what does not, and what is planned |
| [Gotchas](docs/gotchas.md) | Hard-won lessons — **read before writing 8088 code** |

## The host loader

The board has no floppy drive, so a host program can serve a floppy image as `A:` —
and, during development, the BIOS as well — over a serial link. Neither is required to
run the machine any more: it boots its own BIOS from flash and DOS from the USB disk.

**[GertieBoardLoader](https://github.com/mathijsvandenberg/gertieboardloader)** is that
program. It watches both files and reloads them automatically, so rebuilding a BIOS is a
rebuild-and-reboot away with nothing to restart. The
[protocol](docs/tools.md#protocol) is four bytes and a payload if you would rather write
your own.

## Repository layout

```
*.vhd, *.vhdl        FPGA sources (gertieboard.vhdl is the top level)
gertieboard.qsf      Quartus project: pin assignments, source list
gertieboard.sdc      Timing constraints
tools/               BIOS source, DOS utilities, build and host scripts
docs/                This documentation
```

## A short history

The idea was a board you could **build yourself**. Nearly everything on it is
through-hole — the CPU in a socket, the connectors, the display, the buzzer, the
headers — so it is a kit an enthusiast can assemble with an ordinary iron. Only
the PSRAM and the SPI FLASH are surface-mount, two SOIC-8 parts. Using an
off-the-shelf DE0-Nano for the FPGA is part of the same decision: nobody has to
solder a fine-pitch device to own one of these.

My father soldered one.

The top board was designed and built in **2021** — the silkscreen still reads
`MVDB 2021 REV 100`. Then it stalled. Not for lack of interest, but because three
problems refused to give way: **memory corruption**, **timing closure**, and
**negative slack** that would not go away no matter how the design was pushed
around. A machine that boots differently every time is not a machine you can
debug your way forward on, and eventually the motivation ran out. The board went
in a drawer for the better part of four years.

What got it out again was my father turning **67 and retiring**. That is the
deadline this picked up in mid-2026, and the reason the BIOS banner reads
**"Gertieboard BIOS Retirement Edition"**: I wanted the board he had soldered to
actually work, and to hand it to him now that he finally has the time for it.

The boot screen is a deliberate callback to the same period. The first PC in the
house was a **Philips P2120** with a Philips **7BM723** monochrome monitor, and
years later my father pulled its ROM chips out for me and I dumped them. Same
layout, same wording, same spacing, down to `Parity Checking Enabled` on a
machine that has no parity to check.

For a long time I was not sure whether I was copying a P2120 or a P3105, because
the ROM calls itself `P3105 BIOS` while the machine it came out of was a P2120.
It turns out there is nothing to choose between them: the dump is byte-identical
either way, and Philips simply shipped one BIOS across both models.

The **characters are his machine's too**. The P2120's character generator ROM
sits in the FPGA now, so every letter on screen is the exact bitmap that monitor
used to draw.

This time Claude went at it with me. The three original blockers went first —
which turned out to be the whole problem, because everything after them had only
ever been waiting on a stable machine. From there it went quickly: CGA, then the
keyboard, then DMA and the floppy link, then DOS, then a hard disk on the SPI
flash, then a USB host controller and a real hard disk behind it. The board runs
real software now, and it runs it without anything plugged into it but power and a
monitor.

The [gotchas](docs/gotchas.md) page is the honest record of that second stretch.
Several of the entries cost days, and one of them — an assembler quietly emitting
a 386 instruction that is not a branch at all on this CPU — cost considerably
more than that.

## About the name

Gertieboard is named after my father, **Geert**, known to everyone as
**Gertie** — like me, an enthusiast for retro computing.

> _Personal note to be expanded by the author._

## Contributing

Contributions are welcome — see **[CONTRIBUTING.md](CONTRIBUTING.md)**. By opening a
pull request you agree that your contribution is licensed under the MIT Licence, the
same as everything else here. No CLA, no paperwork.

If you are looking for somewhere to start, [docs/status.md](docs/status.md) lists what
is planned and what the actual obstacle is for each item. Read
[docs/gotchas.md](docs/gotchas.md) first regardless — it is short and it will save you
days.

## Licence

[MIT](LICENSE) — do what you like with it, keep the copyright notice, and it comes with
**no warranty of any kind**. This is a hobby computer built from a real CPU, an FPGA and
a soldering iron; if you build one, you build it at your own risk, and nothing here is
fit for any purpose beyond having fun with it.

### Third-party content

The licence covers the work in this repository. A few things in or around the project
are **not** mine to license, and are handled as follows:

| | |
|---|---|
| **Disk images, DOS, games** | Not in the repository — `*.img` and `*.IMA` are gitignored. Bring your own. |
| **Philips ROM dumps** | `tools/philips.*` and `tools/P2120/*.bin` — dumps of the Philips BIOS and character generator ROMs, kept locally for reference. All gitignored, never committed, and **no BIOS code from them is in this BIOS**. |
| **The character font** | [`font.vhd`](font.vhd) and `tools/font8x8.bin` are decoded from a **Philips P2120 character generator ROM** — deliberately, so the machine looks like the real thing. Bitmap typefaces of this kind are generally held not to be copyrightable (they are excluded from registration as mere typographic ornamentation), which is why the derived bitmaps are committed while the ROM image itself is not. If that distinction matters to you, both fonts are replaceable: swap the arrays and rebuild. |
| **Tool executables** | `nasm.exe`, `ndisasm.exe` and similar are gitignored. Install your own. |
| **The boot screen** | A deliberate imitation of the P3105's, and it says so. The code is written from scratch, but **three short strings are reproduced verbatim** to preserve the look: the `Total  Base Extra` column header with its exact spacing, `Parity Checking Enabled`, and `Booting...`. Everything else on the screen is ours. |

**Schematics are coming.** They are not in the repository yet. MIT is a software
licence and does not map cleanly onto a PCB, so when they land the natural pairing is
[CERN-OHL-P](https://cern-ohl.web.cern.ch/) — the permissive hardware licence in the
same spirit as MIT, written for exactly this.
