# FPGA modules

Every module instantiated by [`gertieboard.vhdl`](../../gertieboard.vhdl), with its
entity ports, decoded addresses and behaviour.

## Bus and memory

| Module | Instance | Clock | Function |
|---|---|---|---|
| [busdecode](busdecode.md) | `busdecode1` | `c0` 5 MHz | Address latch, bus strobes, READY, DMA mux, boot ROM overlay, DMA page register |
| [mem_hybrid](mem_hybrid.md) | `inst` | `c3` 50 MHz | Memory controller: on-chip M9K below 32 KB, QPI PSRAM above (with a read cache) |
| [bootrom](bootrom.md) | `bootrom1` | `c0` 5 MHz | 1 KB boot ROM overlaid at `0xFFC00`, plus the `ROM_EN` flag |
| [ctrl_reg](ctrl_reg.md) | `ctrl1` | `c0` 5 MHz | Runtime PSRAM timing register at I/O `0xE4` |

## Video

| Module | Instance | Clock | Function |
|---|---|---|---|
| [vga](vga.md) | `vga1` | `c1` 25 MHz + `c0` | CGA text and graphics, 16 KB VRAM, VGA output |
| [cga_status](cga_status.md) | `cgastatus1` | `c3` 50 MHz | CGA status port `0x3DA` — blanking and vertical retrace |

## Classic chipset

| Module | Instance | Clock | Function |
|---|---|---|---|
| [ppi8255](ppi8255.md) | `ppi1` | `c0` 5 MHz | 8255 PPI: keyboard port, speaker gate, DIP switches |
| [timer8253](timer8253.md) | `timer1` | `c2` 1.19 MHz | 8253 PIT: system tick and speaker tone |
| [int8259](int8259.md) | `int1` | `c0` 5 MHz | 8259A interrupt controller |
| [dma8237](dma8237.md) | `dma1` | `c0` 5 MHz | 8237A DMA controller and bus master |

## Storage and I/O

| Module | Instance | Clock | Function |
|---|---|---|---|
| [fdc8272](fdc8272.md) | `fdc1` | `c0` 5 MHz | Floppy controller, backed by a 1 Mbaud serial link to the host |
| [usb_host](usb_host.md) | USB 1.1 full-speed host controller | I/O `0xE8`–`0xEF` |
| [flash](flash.md) | `flash1` | `c0` 5 MHz | SPI byte engine for the on-board serial FLASH |
| [ps2_kbd_ppi](ps2_kbd_ppi.md) | `inst3` | `c3` 50 MHz | PS/2 receiver, Set 2 → Set 1 translation, hardware Ctrl+Alt+Del |
| [com1_stub](com1_stub.md) | `com1_stub1` | none | Answers COM1 probes as "absent" |

## Support

| Module | Instance | Clock | Function |
|---|---|---|---|
| [sevenseg](sevenseg.md) | `sevenseg1` | `c0` 5 MHz | 7-segment POST/debug display at I/O `0x80` |
| [clkgen / pll](clkgen-pll.md) | `clkgen1`, `pll1`, `pll2` | — | Clock generation and reset stretch |

## Shared conventions

All peripherals follow the same pattern:

- **Strobes are active low.** `RD`/`WR` (or `IO_RD`/`IO_WR`, `MEM_RD`/`MEM_WR`) are
  asserted at `0`. Some modules invert them internally to `rd_act`/`wr_act` for
  readability; `ppi8255` documents them as active-high in its header but is wired
  to the same active-low nets and inverts internally.
- **Read-back is tri-state.** `DATAOUT` must be `"ZZZZZZZZ"` unless the module is
  addressed *and* `RD = '0'`. Several modules declare `DATAOUT` as `INOUT` so the
  shared bus resolves correctly.
- **Writes are latched on an edge, not a level.** A level test re-triggers on every
  clock the strobe is low. Registers latch on the falling edge (start of the write,
  while data is valid); some state machines act on the rising edge instead.

See [architecture](../architecture.md) for the clock tree and bus timing, and
[memory map](../memory-map.md) for the full address list.
