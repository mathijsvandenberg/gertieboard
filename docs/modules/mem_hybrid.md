# mem_hybrid (+ m9k_mem, psram_ctrl)

Sources: [`mem_hybrid.vhd`](../../mem_hybrid.vhd),
[`m9k_mem.vhd`](../../m9k_mem.vhd), [`psram_ctrl.vhd`](../../psram_ctrl.vhd)
· Instance `inst` · Clock `c3` (50 MHz)

The memory controller. `mem_hybrid` is a thin wrapper that splits the address
space between fast on-chip M9K block RAM and the external QPI PSRAM, and muxes
their `READY` signals.

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK_RAM` | IN | 1 | 50 MHz (`c3`) |
| `RESET` | IN | 1 | Synchronous, active high |
| `ADDR` | IN | 20 | Memory address from `busdecode` |
| `DATAIN` | IN | 8 | Write data |
| `RD` | IN | 1 | `/MEMR`, active low |
| `WR` | IN | 1 | `/MEMW`, active low |
| `DATAOUT` | INOUT | 8 | Read data, tri-state onto the shared bus |
| `READY` | OUT | 1 | To `busdecode.RAM_READY` |
| `CTRL` | IN | 8 | PSRAM timing from [`ctrl_reg`](ctrl_reg.md) |
| `RAM_SCK` | OUT | 1 | PSRAM clock |
| `RAM_CS` | OUT | 1 | PSRAM chip select |
| `RAM_SIO` | INOUT | 4 | PSRAM quad data — straight to the pins |

## Address split

```vhdl
sel_ps <= owned_by_psram(ADDR);       -- from memmap.vhd, NOT restated here
READY  <= ready_ps WHEN sel_ps = '1' ELSE ready_m9k;
```

| Region | Served by | Latency |
|---|---|---|
| `0x00000`–`0x9FFFF` | `psram_ctrl` | see below — **all 640 KB, one speed** |
| `0xE0000`–`0xE0FFF` | `m9k_mem` (4 KB on-chip) | ~60 ns; fixed-disk block buffer |
| `0xF0000`–`0xFBFFF` | `psram_ctrl` | `0xFF` fill; `BIOSFLSH` reads the whole F-segment |
| `0xFC000`–`0xFFFFF` | `m9k_mem` (16 KB on-chip) | ~60 ns; **the BIOS image** |

Their ranges are disjoint, so there is never contention.

The split used to run the other way — the low 32 KB on-chip and the BIOS in PSRAM — and
both halves of that were wrong:

- **Conventional memory had two speeds.** A program's timing depended on where DOS
  happened to load it. Software of this era calibrates its delay loops against itself, so
  a game's music could run fast or slow for no visible reason. It is now uniform.
- **Every `INT` paid PSRAM latency**, on the code that is entered most often in the
  machine. The BIOS is 16 KB and now runs at zero wait states.

> All four modules that care about this boundary take it from
> [`memmap.vhd`](../../memmap.vhd) rather than restating it. Getting `sel_ps` and
> `psram_ctrl`'s `is_ram` out of step is exactly how the loader came to hang at POST code
> `02`, with the CPU stopped on an address that looks entirely ordinary. See
> [memory map](../memory-map.md#which-module-answers-a-memory-cycle).

## m9k_mem

A simple 20 KB synchronous RAM with a small state machine
(`M_IDLE → M_WAIT → M_DONE`) that drops `READY` for one cycle and then completes.

It backs **two disjoint windows** out of one inferred RAM: the 16 KB BIOS image maps 1:1
from `ADDR(13:0)`, and the 4 KB disk buffer at `0xE0000` is packed on top of it at index
`BIOS_DEPTH`.

```vhdl
in_bios <= owned_by_bios(ADDR);       -- both from memmap.vhd
in_buf  <= owned_by_diskbuf(ADDR);
in_win  <= in_bios OR in_buf;

midx    <= conv_integer(ADDR(13 DOWNTO 0)) WHEN in_bios = '1'
      ELSE BIOS_DEPTH + conv_integer(ADDR(11 DOWNTO 0));
```

Quartus infers this as a single altsyncram — 163,840 bits, 20 M9K blocks — with about 30
logic elements for the whole module. Check that in the fit report if you touch it: if the
address mux ever stops it inferring RAM, 20 KB of registers will not fit.

## psram_ctrl — QPI controller

Runs the standard QPI sequence: `0x66`/`0x99`/`0x35` init, `0xEB` fast-read with 6
dummy cycles, `0x38` quad write.

### Runtime tuning via `CTRL` (I/O `0xE4`)

| Bits | Field | Meaning |
|---|---|---|
| 2:0 | `SCK_DIV` | SCK half-period in `CLK_RAM` cycles. `0` or `1` → 25 MHz; `2` → 12.5 MHz |
| 6:3 | `RD_LAT` | Read-capture latency; data nibbles captured at cycles `14+RD_LAT` and `15+RD_LAT` |
| 7 | — | reserved |

Default: `0x02` (`SCK_DIV = 2`, `RD_LAT = 0`).

> `RD_LAT` is a capture **alignment** parameter, not a margin knob. Any non-zero
> value shifts the read window by whole nibbles, so every byte comes back
> scrambled and the machine wedges instantly — all code is fetched from PSRAM. `0`
> is the only correct value on this board.

### Read cache

A single-byte read costs 16 SCK cycles (1280 ns at `SCK_DIV = 2`), almost all of it
command, address and dummy overhead. Once the chip is streaming, each further
sequential byte costs only 2 more. So a read **miss burst-fills a whole 16-byte
line**:

| | Cost |
|---|---|
| No cache | 16 SCK per byte |
| 16-byte line | `16 + 2×15 = 46` SCK per line → 2.9 SCK per byte |

- **8 lines, 16 bytes each, fully associative, round-robin replacement.** Line
  *count* matters: the CPU interleaves code fetch with operand reads, so a single
  line would be evicted by every data access and end up *slower* than no cache.

  It was four lines until [`WAITSTAT`](../tools.md#waitstat--what-one-memory-read-costs)
  measured what a miss actually costs:

  | | clocks |
  |---|---|
  | one M9K read | 6.3 |
  | one PSRAM cache hit | 6.3 |
  | one PSRAM cache miss | **36.2** |

  The first two lines are the important ones. A cached PSRAM read costs exactly
  what an on-chip SRAM read costs, and both are *below* the 11 clocks an 8088
  spends on `mov al,[si]` before any waiting at all. **When this cache hits,
  memory is free** — there is no fixed per-access overhead and nothing wrong
  with the `RAM_READY` handshake. Everything the machine loses, it loses on the
  third row.

  So the lever is the miss *rate*, not the miss cost and not `SCK`. DOS, the
  BIOS and the program are all in PSRAM and all competing for these lines;
  doubling the count doubles the number of distinct regions held at once.

  Not free: the tag compare and byte mux both grow with `NLINES`, and that path
  was already the worst-case one — the registered lookup below exists because of
  it. **Check the timing report after changing it**, not just the fitter summary.

  `LINE_BYTES` is *not* a free parameter — `cur_tag` slices `ADDR(19 DOWNTO 4)`
  and the byte mux indexes `ADDR(3 DOWNTO 0)`, both assuming 16. `NLINES` is
  genuinely parametric and is the one safe thing to turn.
- **Lines are 16-byte aligned**, so a burst can never cross the PSRAM's 1024-byte
  page boundary.
- **Writes stay write-through** and invalidate any cached copy of the line. DMA
  writes arrive on the same port, so they are covered too.
- **The lookup is registered**, with an `lu_addr = ADDR` guard so a stale entry can
  never be served.

Measured on hardware: the extra cost of a PSRAM byte over an on-chip byte fell
from **1260 ns to 280 ns**, i.e. PSRAM went from 72 % slower than on-chip RAM to
16 % slower. Past that point the CPU's fixed 4-clock (800 ns) bus cycle dominates,
not the memory.

> **Why the lookup must stay registered:** driving `DATAOUT` combinationally from
> the tag compare put a 64:1 mux onto the shared peripheral data bus and cost ~3 ns
> of slack. Registering it recovered that *and* let Quartus infer the cache as a
> 512-bit `altsyncram` instead of 512 flip-flops — 210 logic elements instead of
> 1158.

> **tCEM limit:** the 46-SCK burst holds `CS` low for 3.7 µs at `SCK_DIV = 2`,
> inside the chip's ~8 µs refresh limit. Do **not** combine this line length with
> `SCK_DIV >= 4`.

### Interaction with READY

A 16-byte line fill takes roughly 18 CPU clocks, which is why
[`busdecode`](busdecode.md)'s READY backstop had to move from `T >= 10` to
`T >= 64`. At 10 it aborted every fill.

## Related

- [ctrl_reg](ctrl_reg.md) — the `CTRL` producer
- [busdecode](busdecode.md) — READY and the DMA mux
- [Memory map](../memory-map.md)
- [Tools](../tools.md) — `MEMTEST` and `RAMSPEED` exercise this module
