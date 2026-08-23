# Components

Hackaday's Components tab takes one row at a time: **quantity + name**, optionally with a
link. Add these in roughly this order — the first three are the ones that make the project
what it is.

## The board itself

| Qty | Component | Note for the "description" field |
|---|---|---|
| 1 | **NEC V20 CPU — µPD70108C-8, 40-pin DIP** | The real processor. 8088 pin- and software-compatible, faster per instruction, plus the 80186 instruction additions. Runs here at 10 MHz on a `-8` part |
| 1 | **Terasic DE0-Nano** (Cyclone IV E EP4CE22F17C6) | Carries the entire chipset. Stock and unmodified — its 50 MHz oscillator, EPCS16 config flash, 32 MB SDRAM and both GPIO headers are used; the accelerometer, ADC, LEDs and switches are not |
| 1 | **40-pin DIP socket** | The CPU is socketed, not soldered |
| 1 | **ISSI IS25LP016D SPI flash, 2 MB, SOIC-8** | The BIOS copy and a 1.44 MB `B:` volume. One of only two SMD parts on the board |
| 1 | **Quad-SPI (QPI) PSRAM, SOIC-8** | The other SMD part. Was main memory; conventional RAM now lives in the DE0-Nano's SDRAM, so this is spare capacity |
| 2 | **40-pin 0.1" pin headers** | The entire top-board-to-DE0-Nano interface |
| 1 | **DE-15 VGA socket** | Driven directly from FPGA pins — there is no external DAC |
| 1 | **Mini-DIN 6 socket (PS/2 keyboard)** | |
| 2 | **USB type-A socket** | Wired straight to FPGA pins as raw D+/D−. No PHY, no host controller chip |
| 4 | **USB pulldown resistor, 15 kΩ–22 kΩ** | Two per port, on D+ and D−. Match the pair on a given port; 18K and 20K are E12 values and 5 % is fine. See the USB build log for why 10K is out of spec |
| 1 | **Single-digit 7-segment display** | The POST/debug display at I/O `0x80`. One digit and no digit select, so a two-byte code is shown *in time*: high nibble, low nibble, blank, repeat |
| 1 | **Piezo buzzer** | The PC speaker, gated by 8253 channel 2 through the PPI |
| 1 | **Tactile switch** | Reset, into the FPGA's reset stretcher (debounced in fabric) |
| 1 | **6-pin 0.1" header, silkscreened COM1** | For an FTDI **3V3 TTL** cable |
| 1 | **Custom PCB — "Gertieboard Mini XT", MVDB 2021 REV 100** | Designed 2021. Almost entirely through-hole, by design: it is meant to be hand-soldered |

## To actually use it

| Qty | Component | Note |
|---|---|---|
| 1 | **VGA monitor** | 640×480 @ 60 Hz |
| 1 | **PS/2 keyboard** | Or a USB HID keyboard on port 1 — both work, and they work at the same time |
| 1 | **USB flash drive** | Becomes `C:`. 504 MB addressable |
| 1 | **USB mouse (HID boot protocol)** | Optional — drives `INT 33h` |
| 1 | **TEAC FD-05PUB USB floppy drive** | Optional — becomes `B:` and reads real 720K/1.44 MB diskettes with no DOS driver |
| 1 | **USB Audio Class speaker** | Optional — the AdLib output path |
| 1 | **FTDI TTL-232R-3V3 cable** | Optional. Only needed for BIOS development, POST logging, and serving a floppy image as `A:` |

## Software / toolchain (if the field allows non-parts)

- **Intel Quartus Prime** (Lite is enough) — to build the bitstream
- **openFPGALoader** — the alternative for macOS and Linux, no Quartus required
- **NASM** — for the BIOS and the DOS-side tools
- **[GertieBoardLoader](https://github.com/mathijsvandenberg/gertieboardloader)** — the
  host program that serves a floppy image and the BIOS over serial
