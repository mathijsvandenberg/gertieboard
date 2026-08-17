# Memory and I/O map

## Memory map

| Range | Size | Backing | Notes |
|---|---|---|---|
| `0x00000`–`0x9FFFF` | 640 KB | **SDRAM** (`sdram_mem`) | *all* of conventional memory, at **one** speed |
| `0xA0000`–`0xAFFFF` | 64 KB | **SDRAM** (via `ega_mem`) | EGA planes, **only while `EGA_ON`**; otherwise unmapped |
| `0xB0000`–`0xB7FFF` | — | unmapped | reads float; not a `MEMADDR` region |
| `0xB8000`–`0xBBFFF` | 16 KB | **inside `vga`** | CGA video RAM (text + graphics) |
| `0xBC000`–`0xDFFFF` | — | unmapped | |
| `0xE0000`–`0xE0FFF` | 4 KB | on-chip **M9K** (`m9k_mem`) | fixed-disk block buffer; **invisible to DOS** |
| `0xE1000`–`0xEFFFF` | — | unmapped | |
| `0xF0000`–`0xFBFFF` | 48 KB | **SDRAM** | `0xFF` fill. Kept backed because `BIOSFLSH` reads the whole F-segment |
| `0xFC000`–`0xFFFFF` | 16 KB | on-chip **M9K** (`m9k_mem`) | the BIOS image — **zero wait states** |
| `0xFF800`–`0xFFFFF` | 2 KB | **boot ROM overlay** | *reads only*, while `ROM_EN = '1'` |

Total conventional memory reported to DOS: **640 KB** — all of it.

### Conventional memory is deliberately uniform

The low 32 KB used to be on-chip M9K and the rest PSRAM, which made the 640 KB **a
machine with two speeds**: a program's timing depended on where DOS happened to load it,
and moving a `.COM` a few kilobytes could change how fast its music played. Software of
this era calibrates delay loops against itself, so that is not a detail — it is the
difference between a game running right and running wrong for no reason anybody can see.

So conventional memory is one thing end to end, and the on-chip memory is spent where the
*speed* is what matters rather than the uniformity:

- **the BIOS image**, because interrupt handlers are entered constantly and were paying
  memory latency on every `INT`
- **the disk block buffer**, which is not visible to DOS at all

That trade is the right way round. A BIOS call being fast helps everything; conventional
memory being fast *in places* helps nothing and breaks timing.

### Why SDRAM and not the PSRAM

Conventional memory used to be the QPI PSRAM on the top board, and moving it was not a
performance decision — the PSRAM would not come up reliably from a cold power-on. The
probe found every one of its 256 test bytes wrong and reads returned nothing, which is the
part not having entered QPI mode. Four separate fixes (init clock rate, the clock edge
data is placed on, chip select at power-up, PLL lock gating) and a reflow moved the count
the wrong way: 208, 252, 254, 255 — tracking time on the bench rather than any change.

The SDRAM was the obvious alternative because it was already trusted: it carries the EGA
bit planes through Keen 4 at full frame rate, `EGAVFY` verifies all 65536 plane offsets of
it, it is factory-mounted rather than hand-soldered, and since the I/O constraints went in
it is the only external interface on the board whose timing is actually checked. It is
also simply better memory — 16 bits wide at 50 MHz against 4 bits at 12.5, 32 MB against
8, and about twice as fast on a cache miss.

[`sdram_mem`](../sdram_mem.vhd) keeps `psram_ctrl`'s cache geometry deliberately unchanged
— 4 lines of 16 bytes, fully associative, write-through with invalidate — because that was
*measured* on this machine and this software, including the discovery that eight lines cost
timing margin the design could not spare. Conventional memory sits at SDRAM word
`0x20000 + (address / 2)`, above the EGA planes which end at word `0x1FFFF`; an assert in
the module enforces the gap, because nothing else would.

`psram_ctrl` is still in the tree and still builds. `USE_SDRAM_RAM` in
[`memmap.vhd`](../memmap.vhd) selects between them, and because it is a constant only the
chosen one is elaborated — the other costs nothing and does not appear in timing. Reverting
is that one line and a rebuild.

> Worth recording: moving the memory did **not** fix cold boot, which failed four times in
> five afterwards just as before. That result is what localised the real fault — see
> [the handshake gotcha](gotchas.md#the-handshake-cannot-govern-the-handshake). Swapping a
> component wholesale and getting the identical failure rate is a measurement, not a
> wasted week.

The fixed disk's 4 KB read-modify-write buffer used to sit at `0x9E000`, costing 8 KB
and forcing the BIOS to report 632 KB. It now lives in on-chip M9K at `0xE0000`, above
conventional memory, so DOS gets the full 640 KB back. See
[fixed disk](fixed-disk.md#where-the-buffer-lives).

> `0xE0000` is not arbitrary. `busdecode`'s `MEMADDR` is true for `ADDR < 0xA0000` **or**
> `ADDR >= 0xE0000`, so a window there is treated as a real memory cycle and the CPU
> waits on `RAM_READY`. Anywhere in `0xA0000`–`0xDFFFF` the handshake is bypassed by the
> `T >= 3` clause, and the CPU could sample the bus before the RAM drives it.
>
> The EGA window is the exception, and it has to be: an SDRAM access plus two clock
> crossings is 500–600 ns, well past the 360 ns that `T >= 3` allows at 8.33 MHz, so a
> read there would return whatever the bus held. `vga` therefore raises `EGA_CLAIM` for
> `0xA0000`–`0xAFFFF` while `EGA_ON`, which is ORed into `MEMADDR` and claims the `READY`
> handshake for those cycles. It is deliberately gated on the mode: the same addresses are
> unclaimed in CGA modes, and claiming them there would send every stray access to the
> `T >= 128` backstop at 15 µs apiece.

### The boot ROM overlay

While `ROM_EN = '1'`, memory **reads** in `0xFF800`–`0xFFFFF` return the boot ROM
instead of the memory underneath. **Writes always pass through**, which is what lets the
bootloader fill the BIOS image underneath itself. Writing `1` to I/O `0xE2` bit 0
clears `ROM_EN` and reveals what was written. See [boot flow](boot.md).

That window now sits inside the **M9K** BIOS region rather than PSRAM, so the image the
loader writes lands on-chip. Nothing about the sequence changed; only what is underneath.

### Which module answers a memory cycle

**Not by asking four modules the same question.** `mem_hybrid`, `psram_ctrl`, `m9k_mem`
and `busdecode` all need to agree about who owns an address, and they used to decide
independently, in four hand-written expressions:

```vhdl
-- memmap.vhd -- the boundaries live here, once
sel_ps  <= owned_by_psram(ADDR);      -- mem_hybrid: route the access
is_ram  <= owned_by_psram(ADDR);      -- psram_ctrl: is this mine?
in_bios <= owned_by_bios(ADDR);       -- m9k_mem:    its two windows
in_buf  <= owned_by_diskbuf(ADDR);
MEMADDR <= (needs_ram_handshake(ADDR) = '1');   -- busdecode: wait on RAM_READY?
```

Teaching one of them that low memory was PSRAM and not the others is how the boot loader
came to hang at POST code `02`: the first stack push routed to a controller that did not
claim the address, nothing drove `READY`, and the CPU stopped on `0x7C00` — an address
that looks entirely ordinary. There was no error and there could not be one.

[`memmap.vhd`](../memmap.vhd) is the fix. A change to the map is now a change to one
file. Introducing it was verified behaviour-neutral: identical 8,586 LEs and 300,160
memory bits before and after.

> `needs_ram_handshake` is deliberately **broader** than the union of the three owners —
> it also covers `0xE1000`–`0xEFFFF`, which nothing backs. That is what `busdecode` has
> always done, and it is kept bit-for-bit so introducing the package changed no logic. An
> unbacked address there falls to the `T >= 128` backstop and returns rubbish, which is a
> fair answer for reading memory that is not there.

`vga` independently decodes `ADDR(19 downto 14) = "101110"` for its 16 KB of video RAM.

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
| `0xA8`–`0xAF` | [usb_host](modules/usb_host.md) `usb2` | R/W | **USB port 1**, the hybrid port. Same eight registers as `0xE8`–`0xEF` below |
| `0xE2` | [bootrom](modules/bootrom.md) | W | bit 0 = 1 disables the boot ROM overlay |
| `0xE4` | [ctrl_reg](modules/ctrl_reg.md) | W | PSRAM timing: `SCK_DIV` (2:0), `RD_LAT` (6:3) |
| `0xE8` | [usb_host](modules/usb_host.md) `usb1` | R/W | **USB port 0**, the fixed disk. Command / status |
| `0xE9` | [usb_host](modules/usb_host.md) | W | USB device address |
| `0xEA` | [usb_host](modules/usb_host.md) | R/W | W endpoint · R raw PID of the last packet received |
| `0xEB` | [usb_host](modules/usb_host.md) | R/W | W TX length · R RX length |
| `0xEC` | [usb_host](modules/usb_host.md) | R/W | Packet buffer, pointer auto-increments |
| `0xED` | [usb_host](modules/usb_host.md) | R/W | Buffer pointer |
| `0xEE` | [usb_host](modules/usb_host.md) | R/W | W bus reset / SOF enable / frame IRQ / low speed (bit 0, port select, is now reserved) · R line state |
| `0xEF` | [usb_host](modules/usb_host.md) | R/W | W diagnostic index · R frame counter or selected counter |
| `0x3C0` | [ega_regs](modules/vga.md#ega-mode-0dh) | W | EGA attribute controller — index and data alternate on one port, steered by a flip-flop |
| `0x3C1` | [ega_regs](modules/vga.md#ega-mode-0dh) | R | attribute controller data, indices 0–15 |
| `0x3C4` | [ega_regs](modules/vga.md#ega-mode-0dh) | R/W | sequencer index (3 bits) |
| `0x3C5` | [ega_regs](modules/vga.md#ega-mode-0dh) | R/W | sequencer data — map mask lives here |
| `0x3CE` | [ega_regs](modules/vga.md#ega-mode-0dh) | R/W | graphics controller index (4 bits) |
| `0x3CF` | [ega_regs](modules/vga.md#ega-mode-0dh) | R/W | graphics controller data — set/reset, function select, bit mask, read map |
| `0x3D4` | [crtc6845](modules/crtc6845.md) | W | 6845 register index |
| `0x3D5` | [crtc6845](modules/crtc6845.md) | R/W | 6845 register data — R14/R15 readable, R0–R13 read as 0 |
| `0x3D8` | [vga](modules/vga.md) | W | CGA mode control |
| `0x3D9` | [vga](modules/vga.md) | W | CGA colour select |
| `0x3DA` | [cga_status](modules/cga_status.md) | R | CGA status — bit 0 blanking, bit 3 vertical retrace |
| `0x3F2` | [fdc8272](modules/fdc8272.md) | W | Digital Output Register (motor, drive select, reset) |
| `0x3F4` | [fdc8272](modules/fdc8272.md) | R | Main Status Register (RQM, DIO, CB) |
| `0x3F5` | [fdc8272](modules/fdc8272.md) | R/W | Data / FIFO |
| `0x3F7` | [fdc8272](modules/fdc8272.md) | R/W | DIR (read) / CCR (write) |
| `0x388` | [opl2_lite](modules/opl2_lite.md) | R/W | AdLib: write = register index, read = status (timer flags) |
| `0x389` | [opl2_lite](modules/opl2_lite.md) | W | AdLib: data for the latched register |
| `0x3F8`–`0x3FF` | [com1_stub](modules/com1_stub.md) | R | Answers COM1 probes so software concludes "no serial port" |

### Deliberately absent

| Ports | Why |
|---|---|
| `0x3B0`–`0x3BF` | MDA. Left floating (`0xFF`) so BIOSes that probe both pick CGA. |
| `0x3C2`, `0x3C6`–`0x3C9`, `0x3CA`–`0x3CD` | VGA-only registers and the EGA bits `ega_regs` does not need — miscellaneous output, the DAC, and the feature-control group. The EGA ports that *are* implemented are in the table above. |
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
