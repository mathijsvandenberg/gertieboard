# cga_status

Source: [`cga_status.vhd`](../../cga_status.vhd) · Instance `cgastatus1` · No clock of its own

The CGA status register at I/O `0x3DA`. Small, but load-bearing: without it, BIOSes
decide there is no CGA card and never write to `0xB8000`, and games that pace
themselves on vertical retrace hang.

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `DISPEN` | IN | 1 | From [`vga`](vga.md) — `'1'` while pixels are being drawn |
| `VRET` | IN | 1 | From [`vga`](vga.md) — `'1'` on every non-displayed line |
| `RD` | IN | 1 | I/O read strobe, active low |
| `ADDR` | IN | 16 | I/O address |
| `DATAOUT` | INOUT | 8 | Status byte, tri-state |

## Register — `0x3DA` (read only)

| Bit | Meaning |
|---|---|
| 0 | Display enable / blanking — `'1'` during horizontal or vertical blanking |
| 1–2 | `0` |
| 3 | **Vertical retrace** — `'1'` during the vertical blanking window |
| 4–7 | `0` |

Bits 4–7 are held at zero deliberately, so the byte is **never `0xFF`**. That is
how a BIOS distinguishes "CGA present" from an open bus.

```vhdl
status(0) <= NOT DISPEN;
status(3) <= VRET;

sel <= '1' WHEN (RD = '0' AND ADDR = x"03DA") ELSE '0';
DATAOUT <= status WHEN sel = '1' ELSE "ZZZZZZZZ";
```

Only `0x3DA` (CGA) is answered, **not** `0x3BA` (MDA). `0x3BA` still reads `0xFF`,
so a BIOS probing both picks CGA and uses `0xB8000`.

## Where the beam is, asked rather than guessed

There is no timing logic in this module. Both bits come straight out of the counters in
[`vga`](vga.md) that actually address the video memory.

That is a change. This module used to carry **its own** 800 × 525 scan counters, clocked
from `c3` at 50 MHz while `vga` counted the same geometry from `c1` at 25 MHz — one
fact, written twice, in two clock domains.

**The two copies did not agree.** `vga` draws the picture on lines 35–434. This module
called every line from 400 onwards the vertical retrace:

| | `vga` (draws the pixels) | `cga_status` (answered `0x3DA`) |
|---|---|---|
| active lines | Y = 35…434 | claimed blanking from vcnt ≥ 400 |
| active columns | X = 144…783 | claimed blanking from hcnt ≥ 1280, i.e. X ≥ 640 |

So a program that polled bit 3, saw retrace, and concluded it was safe to rewrite the
screen was handed **the last 35 visible lines — 1.1 ms of active display** — as if it
were blanking. Horizontally the same 35-line offset showed up as 288 ticks of error on
bit 0.

The retrace window is now every line that is *not* displayed — 435…524 plus 0…34, 125 of
the 525, the same 3.97 ms as before. What changed is that it is in the right place, and
that it cannot drift again because there is nothing left to drift from.

> The old header in this file had already predicted the fault: *"the PHASE is
> arbitrary … wire `vga`'s `VS` in here instead if that ever matters."* It was written as
> a caveat about tearing, and the real cost turned out to be larger and in a different
> place. A known limitation that stays written down for months is a bug with a
> disclaimer on it.

`DISPEN` and `VRET` are generated on `c1` and sampled by an asynchronous CPU read. That
is not synchronised and does not need to be: this is a status bit polled in a loop, a
read that catches the edge returns the value from one side of it, and the next read a
microsecond later is unambiguous. The real card behaves the same way.

## Why games care

Disassembling `DIGGER.EXE` shows the classic pattern:

```asm
mov dx, 0x3DA
w:  in  al, dx
    test al, 0x8       ; bit 3 = vertical retrace
    jnz  w             ; wait for retrace to end, then for it to begin
```

If bit 3 ever sticks, that spin never exits and the game hangs on a blank screen.

## Related

- [vga](vga.md) — the display itself, and the source of both bits
- [Tools](../tools.md) — `CGATEST4` verifies this port with a timeout so a stuck bit
  reports instead of hanging
