# Pinout

FPGA: **Cyclone IV E `EP4CE22F17C6`** on a Terasic DE0-Nano.
Every I/O standard is **3.3 V LVTTL**. Source of truth:
[`gertieboard.qsf`](../gertieboard.qsf).

## CPU interface

The CPU — an NEC V20, see [hardware](hardware.md) — uses the 8088's multiplexed
bus: `CPU_AD[7:0]` carries the low address byte during `ALE` and the data byte
afterwards, so it is bidirectional.

| Signal | Dir | Pin | Purpose |
|---|---|---|---|
| `CPU_AD[0]` | INOUT | `PIN_L13` | multiplexed address/data bit 0 |
| `CPU_AD[1]` | INOUT | `PIN_N14` | |
| `CPU_AD[2]` | INOUT | `PIN_P14` | |
| `CPU_AD[3]` | INOUT | `PIN_P16` | |
| `CPU_AD[4]` | INOUT | `PIN_L15` | |
| `CPU_AD[5]` | INOUT | `PIN_K16` | |
| `CPU_AD[6]` | INOUT | `PIN_N11` | |
| `CPU_AD[7]` | INOUT | `PIN_P9` | |
| `CPU_A[8]` | IN | `PIN_P11` | address bit 8 (non-multiplexed) |
| `CPU_A[9]` | IN | `PIN_R10` | |
| `CPU_A[10]` | IN | `PIN_T10` | |
| `CPU_A[11]` | IN | `PIN_T11` | |
| `CPU_A[12]` | IN | `PIN_T12` | |
| `CPU_A[13]` | IN | `PIN_T13` | |
| `CPU_A[14]` | IN | `PIN_T9` | |
| `CPU_A[15]` | IN | `PIN_R9` | |
| `CPU_A[16]` | IN | `PIN_T14` | |
| `CPU_A[17]` | IN | `PIN_R13` | |
| `CPU_A[18]` | IN | `PIN_R12` | |
| `CPU_A[19]` | IN | `PIN_R11` | address bit 19 |
| `CPU_ALE` | IN | `PIN_N15` | address latch enable |
| `CPU_RD` | IN | `PIN_N12` | read strobe, active low |
| `CPU_WR` | IN | `PIN_R16` | write strobe, active low |
| `CPU_IOM` | IN | `PIN_P15` | 1 = I/O cycle, 0 = memory cycle |
| `CPU_DEN` | IN | `PIN_N16` | data enable |
| `CPU_DTR` | IN | `PIN_R14` | data transmit/receive direction |
| `CPU_INTA` | IN | `PIN_L14` | interrupt acknowledge |
| `CPU_HLDA` | IN | `PIN_L16` | hold acknowledge — CPU has released the bus |
| `CPU_CLK` | OUT | `PIN_J14` | 8.33 MHz clock **to** the CPU (PLL `c0`) |
| `CPU_RST` | OUT | `PIN_J13` | reset to the CPU |
| `CPU_RDY` | OUT | `PIN_J16` | READY / wait-state handshake |
| `CPU_INTR` | OUT | `PIN_K15` | maskable interrupt request (from 8259) |
| `CPU_NMI` | OUT | `PIN_M10` | non-maskable interrupt — tied `'0'` |
| `CPU_HLD` | OUT | `PIN_N9` | bus hold request (from 8237) |

## PSRAM — QPI

Driven by [`mem_hybrid`](modules/mem_hybrid.md) / `psram_ctrl` at 50 MHz.

| Signal | Dir | Pin |
|---|---|---|
| `RAM_SCK` | OUT | `PIN_D8` |
| `RAM_CS` | OUT | `PIN_E6` |
| `RAM_SIO[0]` | INOUT | `PIN_C8` |
| `RAM_SIO[1]` | INOUT | `PIN_A7` |
| `RAM_SIO[2]` | INOUT | `PIN_C6` |
| `RAM_SIO[3]` | INOUT | `PIN_E7` |

## Serial FLASH — SPI (IS25LP016D, 2 MB)

Driven by [`flash`](modules/flash.md). These are **ordinary user I/O pins**, not the
FPGA's dedicated active-serial configuration pins, so this is a separate chip from
the one holding the bitstream — writing it cannot damage the FPGA configuration.

| Signal | Dir | Pin |
|---|---|---|
| `FL_SCK` | OUT | `PIN_B7` |
| `FL_CS` | OUT | `PIN_B6` |
| `FL_MOSI` | OUT | `PIN_D6` |
| `FL_MISO` | IN | `PIN_A6` |

## Video — VGA

6-bit colour, `RRGGBB`. See [`vga`](modules/vga.md).

| Signal | Dir | Pin |
|---|---|---|
| `VGA_HS` | OUT | `PIN_A3` |
| `VGA_VS` | OUT | `PIN_A2` |
| `VGA_RGB[0]` | OUT | `PIN_B3` |
| `VGA_RGB[1]` | OUT | `PIN_B4` |
| `VGA_RGB[2]` | OUT | `PIN_B5` |
| `VGA_RGB[3]` | OUT | `PIN_A4` |
| `VGA_RGB[4]` | OUT | `PIN_D5` |
| `VGA_RGB[5]` | OUT | `PIN_A5` |

## Keyboard — PS/2

| Signal | Dir | Pin |
|---|---|---|
| `PS2CLK` | IN | `PIN_C3` |
| `PS2DAT` | IN | `PIN_D3` |

Receive-only: the FPGA never drives clock or data, and translates Scan Code Set 2
to Set 1 internally. See [`ps2_kbd_ppi`](modules/ps2_kbd_ppi.md) for the level-shifting
requirement — a Cyclone IV input is **not** 5 V tolerant.

## Serial link to the host

Used by [`fdc8272`](modules/fdc8272.md) to fetch the BIOS image and floppy sectors at
1 Mbaud.

| Signal | Dir | Pin | Notes |
|---|---|---|---|
| `UART_RXD` | IN | `PIN_B11` | |
| `UART_TXD` | OUT | `PIN_D11` | |
| `UART_CTS` | — | `PIN_C11` | assigned a pin, not in the top-level entity |
| `UART_RTS` | — | `PIN_A12` | assigned a pin, not in the top-level entity |

## Miscellaneous

| Signal | Dir | Pin | Purpose |
|---|---|---|---|
| `CLOCK50` | IN | `PIN_R8` | 50 MHz oscillator — PLL reference |
| `RESET` | IN | `PIN_A8` | reset button, **active low** |
| `BUZ` | OUT | `PIN_F8` | PC speaker: `SPEAKER_DATA AND TIMER2_OUT` |
| `SEG_A` | OUT | `PIN_E8` | 7-segment display, segment A |
| `SEG_B` | OUT | `PIN_F9` | |
| `SEG_C` | OUT | `PIN_E9` | |
| `SEG_D` | OUT | `PIN_E11` | |
| `SEG_E` | OUT | `PIN_C9` | |
| `SEG_F` | OUT | `PIN_D9` | |
| `SEG_G` | OUT | `PIN_E10` | |

## Debug header

| Signal | Dir | Pin | Driven by |
|---|---|---|---|
| `DBG[0]` | OUT | `PIN_A14` | `PS2CLK` tap |
| `DBG[1]` | OUT | `PIN_B16` | `PS2DAT` tap |
| `DBG[2]` | OUT | `PIN_C14` | tied `'0'` |
| `DBG[3]` | OUT | `PIN_C16` | tied `'0'` |
| `DBG[4]` | OUT | `PIN_C15` | tied `'0'` |
| `DBG[5]` | OUT | `PIN_D16` | tied `'0'` |
| `DBG[6]` | OUT | `PIN_D15` | tied `'0'` |
| `DBG[7]` | OUT | `PIN_D14` | tied `'0'` |

## USB

Driven by [`usb_host`](modules/usb_host.md). Raw D+/D− with the host-side 15K pulldowns
on the board and **no series resistors** — see the caveat on that page. Only the selected
port is driven; the other is held high-impedance.

| Signal | Dir | Pin |
|---|---|---|
| `USB0_DP` | INOUT | `PIN_T15` |
| `USB0_DM` | INOUT | `PIN_F13` |
| `USB1_DP` | INOUT | `PIN_B12` |
| `USB1_DM` | INOUT | `PIN_D12` |

## Timing constraints

[`gertieboard.sdc`](../gertieboard.sdc) declares the 50 MHz input, derives the PLL
clocks, and creates a generated clock for the `CPU_CLK` output pin. The off-chip
CPU bus is false-pathed in both directions: correctness there is governed by the
READY handshake and a bus cycle of 200 ns or more, not by meeting setup on a
single 20 ns edge.

The VGA pixel clock (`c1`) is its own asynchronous group; the framebuffer BRAM
handles that crossing. Everything else is integer-related and timed together.

> SDC filters reference the PLL by **instance path** (`pll1|altpll_component|...`).
> Renaming top-level instances silently drops those constraints — see
> [gotchas](gotchas.md).

## Related

- [Hardware](hardware.md) — the parts these pins connect to
- [Architecture](architecture.md) — how the FPGA side is organised
- [Gotchas](gotchas.md)
