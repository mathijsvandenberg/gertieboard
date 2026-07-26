# The hardware

Two stacked boards. The **Gertieboard Mini XT** top board carries everything that had
to be physical — the CPU, the memory, the connectors — and a stock **Terasic DE0-Nano**
underneath carries the FPGA that plays the part of the 1983 chipset.

![The Gertieboard Mini XT, assembled](images/gertieboard-rev100.jpg)

*`GERTIEBOARD MINI XT — MVDB 2021 REV 100`, with a POST code on the 7-segment display.*

## The top board

Designed and built in 2021. Everything on it is either a real period part, a physical
connector, or memory — nothing that a chipset would have done.

| | Part / detail |
|---|---|
| **CPU** | NEC **V20** (µPD70108C-8), 40-pin DIP — 8088 pin- and software-compatible |
| **PSRAM** | Quad-SPI (QPI) PSRAM, SOIC-8 — the machine's main memory |
| **SPI FLASH** | ISSI **IS25LP016D**, 2 MB, SOIC-8 — [fixed disk](fixed-disk.md) + [BIOS copy](boot.md) |
| **VGA** | DE-15 socket — [`vga`](modules/vga.md) drives it directly, no external DAC |
| **PS/2 keyboard** | Mini-DIN 6 — [`ps2_kbd_ppi`](modules/ps2_kbd_ppi.md) |
| **USB** | Two type-A ports, wired **straight to FPGA pins** as raw `D+`/`D-` |
| **Serial** | 6-pin header for an FTDI **TTL 3V3** cable, silkscreened `COM1` |
| **7-segment** | One digit — the POST/debug display at I/O `0x80`, [`sevenseg`](modules/sevenseg.md) |
| **Buzzer** | The PC speaker, gated by [`timer8253`](modules/timer8253.md) channel 2 and the PPI |
| **Reset** | Tactile button into [`clkgen`](modules/clkgen-pll.md)'s reset stretcher |
| **Interconnect** | Two 40-pin headers down to the DE0-Nano's GPIO |

Putting a genuine processor on the board was the point of the exercise. A soft core
would have been easier and faster, but then the FPGA would be *the computer* rather than
the chipset around one.

### Built to be soldered by hand

The board is meant to be assembled by the person using it, and that shaped the parts
list. Almost everything is **through-hole**: the CPU sits in a 40-pin socket, and the
connectors, the 7-segment display, the buzzer, the reset button and both GPIO headers
all mount the same way. Only two parts are surface-mount — the **PSRAM** and the **SPI
FLASH**, both SOIC-8, which is still a pitch that hand-soldering reaches.

Using a stock DE0-Nano rather than putting the FPGA on the board follows from the same
decision. A Cyclone IV in an F17 package is not something a hobbyist solders at the
kitchen table; a 40-pin header is.

### About the CPU

The V20 is an NEC-designed 8088-compatible: same pinout, same multiplexed 8-bit bus,
faster per instruction. It runs everything an 8088 runs, and adds the 80186 instruction
set additions (`PUSHA`, `POPA`, `ENTER`, `LEAVE`, `BOUND`, shifts by an immediate) plus
NEC's own extensions behind the `0F` prefix — including an 8080 emulation mode.

Two consequences worth knowing:

> Code that assembles fine here is **not automatically 8088-safe**. The BIOS pins
> `.arch i8086` deliberately, which is stricter than this CPU needs, so the sources stay
> honest to the machine they claim to be.

> `0F` is **not** `POP CS` on this part — it is NEC's extended-opcode prefix. That does
> not rescue the [opcode trap](gotchas.md#the-8088-opcode-trap): a 386-form conditional
> jump is not a branch on either CPU.

### The single digit

The POST display is **one** digit driven by seven segment pins — there is no digit
select. A two-digit code like `EF` or `A8` is therefore shown *in time*: high nibble for
500 ms, low nibble for 500 ms, a one-second blank, repeat.

It only restarts that cycle when the written value **changes**, which is why a steady
display cannot distinguish "halted here" from "looping here". See
[`sevenseg`](modules/sevenseg.md).

### USB, for later

Both ports are already routed to FPGA pins (`USB0_DP`/`USB0_DM`, `USB1_*`) but nothing
drives them yet — `USB0_*` is held high-impedance in the top level. There is no host
controller chip in between, so using them means a soft USB host in fabric. See
[status](status.md#usb-keyboard).

## The DE0-Nano

Stock Terasic development board, unmodified. Only a fraction of it is used:

| On the DE0-Nano | Used? |
|---|---|
| Cyclone IV E **EP4CE22F17C6** | the whole chipset |
| 50 MHz oscillator | yes — every clock derives from it via `pll1` |
| **EPCS16** configuration flash | yes — holds the `.jic` so the FPGA self-configures at power-on |
| Two 40-pin GPIO headers | yes — the entire top-board interface |
| 32 MB SDRAM | **no** — main memory is the top board's PSRAM |
| ADXL345 accelerometer, ADC, I²C EEPROM | no |
| 8 LEDs, 2 buttons, 4 DIP switches | no — reset is the top board's button |
| USB-Blaster (USB mini-B) | JTAG programming only |

> **Two different 2 MB flash chips, easily confused.** The DE0-Nano's **EPCS16** holds
> the *FPGA bitstream*. The top board's **IS25LP016D** holds the *hard disk and the BIOS
> copy*. They are programmed by completely different means — see
> [building](building.md#programming-the-board).

## What is emulated, and what is not

| Real silicon | In the FPGA |
|---|---|
| CPU (NEC V20) | Bus decode, wait states, READY |
| PSRAM, SPI flash | Memory controller and read cache |
| VGA, PS/2, USB, serial connectors | CGA adapter, keyboard controller, UART |
| Buzzer, 7-segment, reset button | 8253 PIT, 8259 PIC, 8237 DMA, 8255 PPI, 8272 FDC, boot ROM |

The floppy drive is the one thing that is neither: there is no drive and no connector,
so [`fdc8272`](modules/fdc8272.md) presents a normal controller to DOS and fetches the
sectors from a [host program](tools.md) over the serial header.

## Related

- [Pinout](pinout.md) — every FPGA pin, and which of these parts it goes to
- [Architecture](architecture.md) — how the FPGA side is organised
- [Status and roadmap](status.md) — what the unused hardware is earmarked for
- [A short history](../README.md#a-short-history) — why the board was built this way
