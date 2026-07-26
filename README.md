# Gertieboard

An IBM PC/XT-class computer built around a **real, physical CPU**, with the entire
rest of the chipset implemented in an FPGA.

The FPGA is an off-the-shelf **Terasic DE0-Nano** (Cyclone IV `EP4CE22F17C6`). A
custom top board adds the things that are deliberately *not* emulated: the CPU
itself, real physical connectors, PSRAM and a serial FLASH.

```
   +--------------------------------------------------+
   |  Gertieboard top board                           |
   |    real CPU  .  connectors  .  PSRAM  .  FLASH   |
   +--------------------------------------------------+
                  |  address / data / control
   +--------------------------------------------------+
   |  Terasic DE0-Nano  (Cyclone IV EP4CE22F17C6)     |
   |    chipset: bus, RAM ctrl, CGA, PIC, PIT, PPI,   |
   |             DMA, FDC, keyboard, boot ROM         |
   +--------------------------------------------------+
```

The CPU could have been a soft core in the FPGA, but putting a genuine processor
on the board was the point of the exercise: the FPGA plays the role the
surrounding chipset played in 1983, and nothing more.

## What it does today

- Boots **IBM PC-DOS 3.3**
- **CGA** 80×25 colour text plus graphics modes 4, 5 and 6, output as 640×480 VGA
- **PS/2 keyboard**, including a hardware Ctrl+Alt+Del that no software can bypass
- **Floppy** served over serial from a host loader
- **Fixed disk** (2 MB) backed by the on-board SPI flash — FDISK and FORMAT work
- PC speaker, 8253 timer, 8259 interrupt controller, 8237 DMA, 8255 PPI
- 640 KB RAM, and the FPGA configures itself from its own flash at power-on
- Runs real software: Alley Cat, Digger, Sopwith, PC-DOS utilities

### On the list

| | Planned |
|---|---|
| **USB keyboard** | Both USB ports go straight to FPGA pins, so this means a soft low-speed host — the scancode translation already exists |
| **AdLib / Sound Blaster** | The DMA controller and PIC are already there and proven; an OPL2 at `0x388` is the self-contained first step |
| **EGA** | Wants 256 KB of planar video memory, which is four times the on-chip RAM this device has — so it has to be PSRAM-backed |
| **USB mass storage** | The hardest of the four, and the one the SPI-flash disk already partly covers |

One thing is **known broken**: the BIOS copy in flash verifies byte-for-byte but does
not boot, so a host is still needed at power-on.

Full detail, including why each item is hard and what it needs, is in
**[Status and roadmap](docs/status.md)**.

## Documentation

Start at **[docs/README.md](docs/README.md)**.

| Page | Contents |
|---|---|
| [Architecture](docs/architecture.md) | System overview, clock tree, reset, bus cycles, DMA, interrupts |
| [Memory map](docs/memory-map.md) | Memory regions and the complete I/O port map |
| [Modules](docs/modules/README.md) | Every FPGA module: entity ports, addresses, behaviour |
| [Pinout](docs/pinout.md) | FPGA pin assignments |
| [Boot flow](docs/boot.md) | Reset, boot ROM overlay, serial and flash BIOS paths |
| [BIOS](docs/bios.md) | Interrupt services, BIOS data area, build |
| [Fixed disk](docs/fixed-disk.md) | The SPI-flash hard disk |
| [Building](docs/building.md) | Toolchain, scripts, programming the board |
| [Tools](docs/tools.md) | DOS diagnostics and host-side utilities |
| [Status and roadmap](docs/status.md) | What works, what does not, and what is planned |
| [Gotchas](docs/gotchas.md) | Hard-won lessons — **read before writing 8088 code** |

## The host loader

The board has no floppy drive, so a host program serves the floppy image — and, during
development, the BIOS as well — over a serial link.

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

## About the name

Gertieboard is named after my father, **Gertie** — like me, an enthusiast for
retro computing.

> _Personal note to be expanded by the author._

## Licence

Not yet chosen.
