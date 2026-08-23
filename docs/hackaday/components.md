# Components

**Source: the actual design files**, not inference — `hardware/kicad/GertieXT.kicad_sch`
(42 placements, 88 nets) for the parts and net names, `GertieXT.kicad_pcb` for the
netlist, and the recovered Altium libraries `hardware/libs-recovered/mathijs.SchLib` /
`.PcbLib` for the manufacturer part numbers, which are stored in the footprint
descriptions.

> **`hardware/` is not tracked in git.** It exists in the working tree only, so none of
> these files are on GitHub and the schematics are genuinely unpublished. The Hackaday
> Details page says so. If publishing them is the intent, that directory needs adding —
> see the note at the end of this file.

## The board, as built

`GERTIEBOARD MINI XT — MVDB 2021 REV 100`. 42 placements, 2-layer.

| Ref | Qty | Value | Package | Part / note |
|---|---|---|---|---|
| `U1` | 1 | 8088 | DIP-40 | **NEC V20 (µPD70108C-8)**. Library footprint is titled *Intel 8088 / NEC V20* — either part fits |
| `RAM` | 1 | RAM | SOIC-8 | **Quad-SPI PSRAM**. Wired `SIO0`–`SIO3`, so QPI, not plain SPI |
| `FDD` | 1 | FLOPPY | SOIC-8 | **SPI flash, 2 MB** (ISSI IS25LP016D). `/WP` and `/HOLD` tied to 3V3 |
| `J1` `J2` | 2 | 40PIN_HDR | 2×20, 0.1" | The whole interface down to the DE0-Nano |
| `VGA` | 1 | SUBD15-VGA | DE-15 | **TE Connectivity 1-1734530-1**, Amplimite HD-22, receptacle, solder, metal body |
| `R2` `R4` `R6` | 3 | **470R** | 0805 | VGA ladder, **MSB** of each channel — nets `R1` `G1` `B1` |
| `R1` `R3` `R5` | 3 | **680R** | 0805 | VGA ladder, **LSB** of each channel — nets `R0` `G0` `B0` |
| `PS/2` | 1 | MINIDIN6 | Mini-DIN 6 | Keyboard |
| `USB0` `USB1` | 2 | USBCON | USB type-A | D+/D− straight to FPGA pins |
| `R7`–`R10` | 4 | **15K** | 0805 | USB pulldowns: `USB0DP` `USB0DM` `USB1DP` `USB1DM` to GND |
| `R11` `R12` `R13` | 3 | **10K** | 0805 | Pull-ups to 3V3 on `PS2DAT`, `PS2CLK` and `SW1` (reset) |
| `D1` | 1 | 7seg | — | **Lite-On LTS-4301WC**, single digit |
| `R14`–`R21` | 8 | **1K** | 0805 | Seven on `SEG_A`–`SEG_G`, one from 3V3 to the common pin |
| `L1` | 1 | BUZ | — | **CUI CMT-0904-83T** magnetic transducer — the PC speaker |
| `RESET` | 1 | PUSHBUTTON | — | **Omron B3F-1000** tactile switch |
| `COM1` | 1 | TTL3V3 | 6-pin, 0.1" | FTDI **TTL-3V3** cable pinout, silkscreened `COM1` |
| `C1`–`C8` | 8 | **100n** | 0805 | Decoupling |
| — | 1 | — | — | **Custom 2-layer PCB** |

**Total: 42 placements.** All 0805 passives are on the **bottom** side; everything
else is through-hole and hand-solderable. The only two fine-pitch parts are the SOIC-8
flash and PSRAM.

### Not on the schematic but needed to build one

| Qty | Item | Why |
|---|---|---|
| 1 | **40-pin DIP socket** | `U1` is a DIP-40 footprint. Socket the CPU — do not solder a V20 down |
| 1 | **Terasic DE0-Nano** (Cyclone IV E EP4CE22F17C6) | Carries the entire chipset. Mates to `J1`/`J2` |

## The VGA output is a resistor DAC

Worth calling out, because "the FPGA drives the connector directly, no external DAC"
is only half true and the repository says it that way in a couple of places.

There is no DAC **chip**. There are **six resistors**:

```
VGA_RGB[5:4] --[470R]--+
                       +---> R   (nets R1/R0 summed)
VGA_RGB[  ..] --[680R]--+
```

Two bits per channel, a 470R/680R pair summing into each of R, G and B — which is
exactly the **6-bit `RRGGBB`** the pinout documents, and **64 colours**. That number is
not a coincidence: EGA's palette is 16 chosen out of 64, so the hardware palette and the
adapter being emulated are the same size.

## To actually use it

| Qty | Component | Note |
|---|---|---|
| 1 | **VGA monitor** | 640×480 @ 60 Hz |
| 1 | **PS/2 keyboard** | Or a USB HID keyboard on port 1 — both work, at the same time |
| 1 | **USB flash drive** | Becomes `C:`. 504 MB addressable |
| 1 | **USB mouse (HID boot protocol)** | Optional — drives `INT 33h` |
| 1 | **TEAC FD-05PUB USB floppy drive** | Optional — becomes `B:`, reads real 720K/1.44 MB diskettes with no DOS driver |
| 1 | **USB Audio Class speaker** | Optional — the AdLib output path |
| 1 | **FTDI TTL-232R-3V3 cable** | Optional — BIOS development, POST logging, serving `A:` |

## Toolchain

- **Intel Quartus Prime** (Lite is enough) — to build the bitstream
- **openFPGALoader** — the alternative for macOS and Linux, no Quartus required
- **NASM** — for the BIOS and the DOS-side tools
- **KiCad 10** — `hardware/kicad/` opens directly; the Altium original is beside it
  (both local-only — see the note at the top)
- **[GertieBoardLoader](https://github.com/mathijsvandenberg/gertieboardloader)** — serves
  a floppy image and the BIOS over serial

## Three things the netlist says that the prose did not

1. **The USB pulldowns fitted are 15K.** `docs/hardware.md` discusses a 15K–22K range and
   argues for 18K/20K as easier E12 values; the board as built is 15K, at the bottom of
   the range. Both statements are true, but only one of them is what is on the PCB.
2. **`SW1` (reset) has a 10K pull-up, `R13`** — and `SW1` is one of the three nets the
   original 2021 Altium DRC already logged as unrouted, along with `VCC3V3` and `VCC5V`.
   Worth resolving if the board is ever respun.
3. **The PSRAM is wired for QPI**, not single-lane SPI — all four `SIO` lines are routed.

## One more thing the files revealed

**`hardware/` is untracked.** `git ls-files hardware` returns nothing: the Altium project,
the KiCad 10 translation, the recovered libraries, the PCB renders and `sch.pdf` are all
in the working tree and none of them are committed. That is why
[docs/hardware.md:46](../hardware.md) still says the schematics are not published — it is
accurate, but the reason is that the directory was never added rather than that the files
do not exist.

Adding it is a decision, not an oversight to fix silently: `hardware/History/` alone holds
dozens of Altium `.Zip` autosaves, so the directory wants a `.gitignore` pass before it
goes anywhere near a commit.
