# Memory and I/O map

## Memory map

| Range | Size | Backing | Notes |
|---|---|---|---|
| `0x00000`–`0x07FFF` | 32 KB | on-chip **M9K** (`m9k_mem`) | fast, ~60 ns; IVT, BIOS data area, low DOS |
| `0x08000`–`0x9FFFF` | 608 KB | **PSRAM** (`psram_ctrl`) | rest of conventional memory |
| `0xA0000`–`0xB7FFF` | — | unmapped | reads float; not a `MEMADDR` region |
| `0xB8000`–`0xBBFFF` | 16 KB | **inside `vga`** | CGA video RAM (text + graphics) |
| `0xBC000`–`0xDFFFF` | — | unmapped | |
| `0xE0000`–`0xE0FFF` | 4 KB | on-chip **M9K** (`m9k_mem`) | fixed-disk block buffer; **invisible to DOS** |
| `0xE1000`–`0xEFFFF` | — | unmapped | |
| `0xF0000`–`0xFFFFF` | 64 KB | **PSRAM** | BIOS F-segment, filled at boot |
| `0xFFC00`–`0xFFFFF` | 1 KB | **boot ROM overlay** | *reads only*, while `ROM_EN = '1'` |

Total conventional memory reported to DOS: **640 KB** — all of it.

The fixed disk's 4 KB read-modify-write buffer used to sit at `0x9E000`, costing 8 KB
and forcing the BIOS to report 632 KB. It now lives in on-chip M9K at `0xE0000`, above
conventional memory, so DOS gets the full 640 KB back. See
[fixed disk](fixed-disk.md#where-the-buffer-lives).

> `0xE0000` is not arbitrary. `busdecode`'s `MEMADDR` is true for `ADDR < 0xA0000` **or**
> `ADDR >= 0xE0000`, so a window there is treated as a real memory cycle and the CPU
> waits on `RAM_READY`. Anywhere in `0xA0000`–`0xDFFFF` the handshake is bypassed by the
> `T >= 3` clause, and the CPU could sample the bus before the RAM drives it.

### The boot ROM overlay

While `ROM_EN = '1'`, memory **reads** in `0xFFC00`–`0xFFFFF` return the boot ROM
instead of PSRAM. **Writes always pass through to PSRAM**, which is what lets the
bootloader fill the BIOS image underneath itself. Writing `1` to I/O `0xE2` bit 0
clears `ROM_EN` and reveals the PSRAM copy. See [boot flow](boot.md).

### Which module answers a memory cycle

`mem_hybrid` splits the address internally:

```vhdl
sel_ps <= '1' WHEN ((ADDR >= x"08000") AND (ADDR < x"A0000"))
               OR  (ADDR >= x"F0000") ELSE '0';
```

So PSRAM serves conventional RAM above 32 KB **and** the BIOS F-segment; M9K
serves everything below `0x08000`. `vga` independently decodes
`ADDR(19 downto 14) = "101110"` for its 16 KB of video RAM.

## I/O port map

| Ports | Module | Access | Function |
|---|---|---|---|
| `0x00`–`0x0F` | [dma8237](modules/dma8237.md) | R/W | 8237A DMA: address/count pairs, command, status, mask, mode, master clear |
| `0x20` | [int8259](modules/int8259.md) | R/W | ICW1, OCW2 (EOI), OCW3; reads IRR or ISR |
| `0x21` | [int8259](modules/int8259.md) | R/W | ICW2/ICW3/ICW4 during init, OCW1 (IMR) after |
| `0x40` | [timer8253](modules/timer8253.md) | R/W | counter 0 — system tick |
| `0x41` | [timer8253](modules/timer8253.md) | R/W | counter 1 — DRAM refresh (unused here) |
| `0x42` | [timer8253](modules/timer8253.md) | R/W | counter 2 — speaker tone |
| `0x43` | [timer8253](modules/timer8253.md) | W | control word / counter-latch command |
| `0x60` | [ppi8255](modules/ppi8255.md) | R | Port A — keyboard scancode |
| `0x61` | [ppi8255](modules/ppi8255.md) | R/W | Port B — speaker gate, keyboard clear/ack |
| `0x62` | [ppi8255](modules/ppi8255.md) | R | Port C — SW1 DIP switches, NMI status |
| `0x63` | [ppi8255](modules/ppi8255.md) | W | 8255 control word |
| `0x80` | [sevenseg](modules/sevenseg.md) | W | POST / debug code on the 7-segment display |
| `0x81` | [busdecode](modules/busdecode.md) | W | DMA channel-2 page register (address bits 19:16) |
| `0x98` | [flash](modules/flash.md) | R/W | SPI: write starts a byte exchange; read returns the received byte |
| `0x99` | [flash](modules/flash.md) | R | SPI status — bit 7 = BUSY |
| `0x9A` | [flash](modules/flash.md) | W | SPI control — bit 0 = `/CS` (0 = assert) |
| `0xE2` | [bootrom](modules/bootrom.md) | W | bit 0 = 1 disables the boot ROM overlay |
| `0xE4` | [ctrl_reg](modules/ctrl_reg.md) | W | PSRAM timing: `SCK_DIV` (2:0), `RD_LAT` (6:3) |
| `0x3D8` | [vga](modules/vga.md) | W | CGA mode control |
| `0x3D9` | [vga](modules/vga.md) | W | CGA colour select |
| `0x3DA` | [cga_status](modules/cga_status.md) | R | CGA status — bit 0 blanking, bit 3 vertical retrace |
| `0x3F2` | [fdc8272](modules/fdc8272.md) | W | Digital Output Register (motor, drive select, reset) |
| `0x3F4` | [fdc8272](modules/fdc8272.md) | R | Main Status Register (RQM, DIO, CB) |
| `0x3F5` | [fdc8272](modules/fdc8272.md) | R/W | Data / FIFO |
| `0x3F7` | [fdc8272](modules/fdc8272.md) | R/W | DIR (read) / CCR (write) |
| `0x3F8`–`0x3FF` | [com1_stub](modules/com1_stub.md) | R | Answers COM1 probes so software concludes "no serial port" |

### Deliberately absent

| Ports | Why |
|---|---|
| `0x3B0`–`0x3BF` | MDA. Left floating (`0xFF`) so BIOSes that probe both pick CGA. |
| `0x3C0`–`0x3CF` | EGA/VGA. Not implemented — this is a CGA machine. |
| `0x3F0`, `0x3F1`, `0x3F3`, `0x3F6` | Unused FDC registers. |

> Note the SPI ports `0x98`–`0x9A` are **not** an IBM assignment; they were free on
> this machine. Nothing else decodes `0x9x` (`dma8237` covers only `0x00`–`0x0F`).

## Interrupt vectors installed by the BIOS

| Vector | Handler | Purpose |
|---|---|---|
| `INT 08h` | `_int08` | timer tick (IRQ0): 18.2 Hz counter, floppy motor timeout, chains `INT 1Ch` |
| `INT 09h` | `_int09` | keyboard (IRQ1): scancode → buffer, shift state, Ctrl+Alt+Del |
| `INT 10h` | `_int10` | video services |
| `INT 11h` | `_int11` | equipment list |
| `INT 12h` | `_int12` | conventional memory size |
| `INT 13h` | `_int13` | disk: floppy for `DL < 0x80`, SPI-flash fixed disk for `DL >= 0x80` |
| `INT 16h` | `_int16` | keyboard services |
| `INT 19h` | `_int19` | bootstrap loader |
| `INT 1Ah` | `_int1a` | time of day and the fake RTC |
| `INT 1Eh` | `_floppy_dpt` | pointer to the floppy disk parameter table |

See [BIOS](bios.md) for the function-level detail and the BIOS data area layout.

## Related

- [Architecture](architecture.md) — clocks, bus cycles, DMA
- [Fixed disk](fixed-disk.md) — how the flash is carved up
- [Pinout](pinout.md) — the physical pins behind these signals
