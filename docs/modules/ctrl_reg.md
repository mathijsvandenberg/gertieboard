# ctrl_reg

Source: [`ctrl_reg.vhd`](../../ctrl_reg.vhd) · Instance `ctrl1` · Clock `c0` (8.33 MHz)

A single writable register at I/O `0xE4` that tunes the PSRAM controller's timing at
runtime, so signal-integrity experiments need no rebuild.

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK` | IN | 1 | 8.33 MHz (`c0`) |
| `RESET` | IN | 1 | Synchronous, active high |
| `DATA` | IN | 8 | CPU write data |
| `ADDR` | IN | 16 | I/O address |
| `WR` | IN | 1 | I/O write strobe, active low |
| `CTRL` | OUT | 8 | → `mem_hybrid.CTRL` → `psram_ctrl` |

## Register — I/O `0xE4` (write only)

| Bits | Field | Meaning |
|---|---|---|
| 2:0 | `SCK_DIV` | PSRAM `SCK` half-period in 50 MHz cycles. `0` or `1` → 25 MHz, `2` → 12.5 MHz |
| 6:3 | `RD_LAT` | Read-capture latency |
| 7 | — | reserved |

```vhdl
CONSTANT DEFAULT_CTRL : std_logic_vector(7 DOWNTO 0) := x"02";   -- SCK_DIV=2, RD_LAT=0
```

## Two warnings

> **`RD_LAT` is an alignment parameter, not a margin knob.** Any non-zero value shifts
> the read window by whole nibbles, so every byte comes back scrambled and the machine
> wedges instantly — all code is fetched from PSRAM. `0` is the only correct value on
> this board. Setting `CTRL = 0x09` (`RD_LAT = 1`) will hang it.

> **Keep `SCK_DIV <= 2`.** The PSRAM read cache's 46-cycle burst holds `CS` low for
> 3.7 µs at `SCK_DIV = 2`, within the chip's ~8 µs refresh limit. Slower settings would
> exceed it.

## Reset behaviour

```vhdl
IF RESET = '1' THEN
    ctrl_q <= DEFAULT_CTRL;
ELSIF (WR = '0' AND ADDR = x"00E4") THEN
    ctrl_q <= DATA;
```

> The reset case matters. Without it the register kept its value across a CPU reset, so
> experimenting with a bad `CTRL` left the board unusable until the bitstream was
> reloaded — the reset button could not help, because the very code that would rewrite
> `CTRL` was unfetchable. Now the reset button always recovers it.

## Measured effect

With the PSRAM read cache in place, `SCK_DIV = 1` is only about 7 % faster than
`SCK_DIV = 2` (27 vs 29 ticks in `RAMSPEED`), because SPI time is no longer the
bottleneck. Before the cache it was worth 21 %. The default stays at the wider-eye
`SCK_DIV = 2` — not worth a signal-integrity risk for 7 %.

## Related

- [mem_hybrid](mem_hybrid.md) — the consumer, and what the fields mean in detail
- [Tools](../tools.md) — `RAMSPEED` sweeps `CTRL` values with an integrity check
