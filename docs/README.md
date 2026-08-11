# Gertieboard documentation

## Start here

- **[Hardware](hardware.md)** — the two physical boards, with a photo: what the
  top board carries, what the DE0-Nano contributes, and what is deliberately
  unused on each.
- **[Architecture](architecture.md)** — how the pieces fit together: clock tree,
  reset, bus cycles, DMA and interrupt wiring.
- **[Memory map](memory-map.md)** — every memory region and every I/O port, in one
  place.
- **[Modules](modules/README.md)** — one page per FPGA module, with entity ports,
  decoded addresses and behaviour.

## Subsystems

- **[Boot flow](boot.md)** — power-on to DOS: the boot ROM overlay, the two places a
  BIOS image can come from (serial host, SPI flash), and the boot order.
- **[BIOS](bios.md)** — interrupt services, BIOS data area layout, and building it.
- **[Storage](storage.md)** — the three drives and how one `INT 13h` serves all of
  them: serial `A:`, flash `B:`, USB `C:`, plus the boot order and the USB
  mass-storage stack.
- **[Fixed disk](fixed-disk.md)** — the SPI-flash drive in detail: geometry, the block
  buffer, the erase/program path, and the reserved BIOS region.

## Practical

- **[Status and roadmap](status.md)** — what works today, and what is planned (USB
  throughput, USB keyboard, AdLib/Sound Blaster, EGA) with the real obstacle for
  each.
- **[Building](building.md)** — Quartus and assembler toolchains, the build
  scripts, and programming the FPGA and its configuration flash.
- **[Tools](tools.md)** — DOS diagnostics (`USBPERF`, `USBSOAK`, `USBSTAT`, `SPIDUMP`,
  `KBSCAN`, `186BOOST`, `HDTEST`, `MEMTEST`, `RAMSPEED`, `CGATEST*`, `BIOSFLSH`) and the
  host-side loader.
- **[Gotchas](gotchas.md)** — mistakes that cost days of debugging. The 8088
  opcode trap in particular will bite anyone writing assembly for this machine.

## Module index

| Module | Function | Addresses |
|---|---|---|
| [busdecode](modules/busdecode.md) | Bus decode, strobes, READY, DMA mux, boot ROM overlay | I/O `0x81` |
| [mem_hybrid](modules/mem_hybrid.md) | Memory controller: on-chip M9K + QPI PSRAM | memory |
| [vga](modules/vga.md) | CGA text and graphics | I/O `0x3D8`, `0x3D9`; mem `0xB8000` |
| [cga_status](modules/cga_status.md) | CGA status register (retrace/blanking) | I/O `0x3DA` |
| [ppi8255](modules/ppi8255.md) | 8255 PPI: keyboard port, speaker, DIP switches | I/O `0x60`–`0x63` |
| [timer8253](modules/timer8253.md) | 8253 PIT: system tick, speaker tone | I/O `0x40`–`0x43` |
| [int8259](modules/int8259.md) | 8259A interrupt controller | I/O `0x20`–`0x21` |
| [dma8237](modules/dma8237.md) | 8237A DMA controller and bus master | I/O `0x00`–`0x0F` |
| [fdc8272](modules/fdc8272.md) | Floppy controller over a serial link to the host | I/O `0x3F2`–`0x3F7` |
| [flash](modules/flash.md) | SPI engine for the on-board serial FLASH | I/O `0x98`–`0x9A` |
| [usb_host](modules/usb_host.md) | USB 1.1 full-speed host controller | I/O `0xE8`–`0xEF` |
| [ps2_kbd_ppi](modules/ps2_kbd_ppi.md) | PS/2 keyboard → XT scancodes, hardware Ctrl+Alt+Del | — |
| [bootrom](modules/bootrom.md) | 2 KB boot ROM overlay and its enable flag | I/O `0xE2` |
| [ctrl_reg](modules/ctrl_reg.md) | Runtime PSRAM timing control | I/O `0xE4` |
| [sevenseg](modules/sevenseg.md) | 7-segment POST/debug display | I/O `0x80` |
| [com1_stub](modules/com1_stub.md) | Answers COM1 probes as "absent" | I/O `0x3F8`–`0x3FF` |
| [opl2_lite](modules/opl2_lite.md) | AdLib front end, played as square waves on the buzzer | I/O `0x388`–`0x389` |
| [crtc6845](modules/crtc6845.md) | 6845 register file, so the video card can be detected | I/O `0x3D4`–`0x3D5` |
| [clkgen / pll](modules/clkgen-pll.md) | Clock generation and reset stretch | — |

## Conventions

| Notation | Meaning |
|---|---|
| `0x3F5` | I/O port address |
| `0xB8000` | 20-bit physical memory address |
| `F000:FFF0` | segment:offset |
| active **LOW** | asserted when `0` — most bus strobes here are active low |
| `c0`…`c3` | PLL output clocks, see [architecture](architecture.md#clocks) |
