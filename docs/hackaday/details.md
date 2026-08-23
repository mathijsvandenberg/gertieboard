# Details

*(Paste everything below the line into the Details box. Hackaday.io renders Markdown.)*

---

The CPU is real. Everything else is not.

Gertieboard is an IBM PC/XT-class computer built around a **genuine NEC V20** in a
40-pin socket, with the entire rest of the 1983 chipset — bus decode, memory
controller, CGA and EGA video, 8259 PIC, 8253 PIT, 8255 PPI, 8237 DMA, 8272 FDC,
keyboard controller, USB host and boot ROM — implemented in an FPGA.

It boots **MS-DOS 4.01** from a USB hard disk, at **10 MHz**, with nothing plugged into
it but power and a VGA monitor. No host PC, no JTAG cable: the FPGA configures itself
from its own flash and the BIOS comes off an on-board SPI chip.

A soft core would have been easier. Putting a real processor in the socket was the
entire point — the FPGA plays the part the surrounding chips played in 1983, and
nothing more. Every bus cycle on this machine is a real V20 driving a real multiplexed
bus at real speed, and the fabric has to keep up with it or the machine does not boot.

## Two boards

The **Gertieboard Mini XT** top board carries everything that had to be physical. A
stock **Terasic DE0-Nano** (Cyclone IV EP4CE22F17C6) underneath carries the FPGA.

```
+--------------------------------------------------------------+
|  GERTIEBOARD MINI XT  -  MVDB 2021 REV 100                   |
|                                                              |
|    NEC V20 CPU  .  SPI FLASH (2 MB)  .  PSRAM (spare)        |
|    VGA  .  PS/2 keyboard  .  2x USB  .  FTDI 3V3 serial      |
|    7-segment POST display  .  buzzer  .  reset button        |
+--------------------------------------------------------------+
               |  2x 40-pin GPIO
+--------------------------------------------------------------+
|  Terasic DE0-Nano  (Cyclone IV EP4CE22F17C6)                 |
|                                                              |
|    the chipset: bus decode, memory controller,               |
|    CGA + EGA video, 8259 PIC, 8253 PIT, 8255 PPI,            |
|    8237 DMA, 8272 FDC, keyboard controller,                  |
|    USB host controller, boot ROM                             |
|                                                              |
|    32 MB SDRAM: all 640 KB of RAM and the EGA planes         |
+--------------------------------------------------------------+
```

**Forty-two placements, and it is meant to be soldered by hand.** Almost everything is
through-hole — the CPU in a socket, the connectors, the display, the buzzer, both GPIO
headers. Only two parts are surface-mount, and both are SOIC-8. Using an off-the-shelf
DE0-Nano rather than putting the Cyclone IV on the board follows from the same decision:
nobody should have to solder an F17 package at the kitchen table to own one of these.

My father soldered one. That is what this is.

## What it does today

Everything listed here has been run on hardware.

- **Boots MS-DOS 4.01** — the Dutch release that shipped with the Philips P2120,
  installed onto the USB disk from its original three floppies. IBM PC-DOS 3.30 runs
  too.
- **USB hard disk as `C:`** — a full-speed host controller in fabric with Bulk-Only
  Transport and a SCSI stack in the BIOS. `FDISK`, `FORMAT` and `CHKDSK` all pass;
  504 MB addressable, ~220 KB/s reads.
- **CGA** 80×25 colour text plus graphics modes 4, 5 and 6, scan-doubled out as
  640×480 VGA. There is no DAC chip: six resistors are the entire video DAC — a
  470 R/680 R pair per channel, two bits each, **64 colours**. Which is exactly the
  size of EGA's palette, from which 16 are chosen.
- **EGA mode 0Dh**, 320×200×16 — four 64 KB bit planes in SDRAM, with the latch/ALU
  read-modify-write path, the 16-of-64 palette and CRTC start-address page flipping.
  Commander Keen 4 runs on it.
- **PS/2 keyboard** with extended keys, AltGr, and a hardware Ctrl+Alt+Del that no
  software can bypass.
- **USB mouse and keyboard** on the second port — a HID mouse driving `INT 33h`
  (verified in *The Secret of Monkey Island* and *Arkanoid*, both of which reprogram
  the PIT and so break timer-based drivers) and a HID keyboard typing into the BIOS key
  buffer. Full speed and low speed, in the same serial interface engine.
- **Two floppy drives** — `A:` served over a serial link from a host program, `B:` a
  real USB floppy drive (a TEAC FD-05PUB, UFI over CBI, no DOS driver loaded) or the
  on-board SPI flash when no drive is attached.
- **AdLib at `0x388`** rendered as 48 kHz PCM straight into a USB Audio Class device —
  the CPU is not in the audio path at all, so sound survives into software that has
  taken over the machine.
- 640 KB RAM, PC speaker, 8253 timer, 8259 PIC, 8237 DMA, 8255 PPI, a run-time
  selectable bus clock from 5 to 16.667 MHz, and a POST display on one seven-segment
  digit.
- Runs real software: Alley Cat, Digger, Sopwith, Pacman, Arkanoid, Prince of Persia,
  Commander Keen 4, King's Quest I, the DOS utilities.

## Why it sat in a drawer for four years

The top board was designed and built in **2021** — the silkscreen still reads
`MVDB 2021 REV 100`. Then it stalled, on three problems that would not give way:
memory corruption, timing closure, and negative slack that came back however the design
was pushed around. A machine that boots differently every time is not a machine you can
debug your way forward on. Eventually the motivation ran out.

What got it out of the drawer was my father turning **67 and retiring**. That is the
deadline the project picked up in mid-2026, and the reason the BIOS banner reads
*"Gertieboard BIOS Retirement Edition"*: I wanted the board he had soldered to actually
work, and to hand it to him now that he finally has the time for it.

All three original blockers turned out to be one thing wearing three hats — **READY was
arriving 14 ns late** against the V20's 8 ns allowance, and nobody had ever measured it
because the pin was false-pathed in the constraints. Every timing report came back green
while the machine would not boot. There is a build log about that one.

## The boot screen is somebody's actual PC

The first computer in the house was a **Philips P2120** with a **7BM723** monochrome
monitor. Years later my father pulled its ROM chips and I dumped them, and the boot
screen here is a deliberate reproduction of that one — same layout, same wording, same
spacing, down to `Parity Checking Enabled` on a machine that has no parity to check.

The **characters are his machine's too**: the P2120's character generator ROM lives in
the FPGA, so every letter on screen is the exact bitmap that monitor used to draw.

One detail closed a circle nobody planned. The P2120 left the factory at 4.77 MHz, but
the chip inside it was an **8088-1**, rated for 10. One of the first things my father
and grandfather did was enable the turbo pin, so the family's real PC ran at 10 MHz from
early on. **This board runs at 10 MHz too** — from the opposite direction, since the V20
fitted is a `-8` and is therefore over its rating where theirs was inside it. Same
number, four decades apart, for the same reason: somebody wanted to know if it would go
faster.

## About the name

Gertieboard is named after my father, **Geert**, known to everyone as **Gertie** — like
me, an enthusiast for retro computing. It was made for him: not a product, not a project
looking for an audience, one board for one person as a gift he could solder himself.

Putting it on GitHub came later, because the board worked and the documentation had been
written anyway.

## Build one

Everything is **MIT licensed** and on GitHub: VHDL sources, the BIOS in assembly, the
build scripts, the DOS-side diagnostic tools, and a documentation set that includes a
*gotchas* page — the honest record of what cost days.

- **Source and releases:** <https://github.com/mathijsvandenberg/gertieboard>
- **Documentation index:** <https://github.com/mathijsvandenberg/gertieboard/blob/main/docs/README.md>
- **Host loader:** <https://github.com/mathijsvandenberg/gertieboardloader>

Each release ships the bitstream in four containers, so a DE0-Nano can be programmed
from Quartus *or* from macOS/Linux with openFPGALoader and no Altera toolchain at all:

```
openFPGALoader -c usb-blaster gertieboard.rbf                    # this session only
openFPGALoader -c usb-blaster -f --file-type rpd gertieboard.rpd # into the config flash
```

The bitstream is the chipset and the `.64k` is the BIOS that runs on it; both are needed,
and updating one does not update the other.

**Schematics for the top board are not published yet** — they are coming. Until then the
[hardware page](https://github.com/mathijsvandenberg/gertieboard/blob/main/docs/hardware.md)
and the [pinout](https://github.com/mathijsvandenberg/gertieboard/blob/main/docs/pinout.md)
describe what is connected to what, and the FPGA half runs on any stock DE0-Nano today.

## Still on the list

**USB throughput** (the CPU's byte-at-a-time copy is most of the ceiling, not the wire),
**USB hubs**, **NumLock and CapsLock on the USB keyboard**, real **OPL2 FM synthesis**
rather than the current square-wave approximation, and **EGA modes 0Eh and 10h**. Each
one, with the actual obstacle rather than a wish, is in
[docs/status.md](https://github.com/mathijsvandenberg/gertieboard/blob/main/docs/status.md).
