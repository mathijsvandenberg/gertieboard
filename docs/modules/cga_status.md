# cga_status

Source: [`cga_status.vhd`](../../cga_status.vhd) · Instance `cgastatus1` · Clock `c3` (50 MHz)

The CGA status register at I/O `0x3DA`. Small, but load-bearing: without it, BIOSes
decide there is no CGA card and never write to `0xB8000`, and games that pace
themselves on vertical retrace hang.

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK` | IN | 1 | 50 MHz (`c3`) |
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
sel <= '1' WHEN (RD = '0' AND ADDR = x"03DA") ELSE '0';
DATAOUT <= status WHEN sel = '1' ELSE "ZZZZZZZZ";
```

Only `0x3DA` (CGA) is answered, **not** `0x3BA` (MDA). `0x3BA` still reads `0xFF`,
so a BIOS probing both picks CGA and uses `0xB8000`.

## How the timing is produced

Shadow scan counters mirror `vga`'s 800 × 525 geometry with a 640 × 400 active
area:

```vhdl
status(0) <= '1' WHEN (hcnt >= 1280 OR vcnt >= 400) ELSE '0';  -- in blanking
status(3) <= '1' WHEN (vcnt >= 400) ELSE '0';                   -- vertical retrace
```

> ⚠️ **This module runs on `c3` (50 MHz) while `vga` scans on `c1` (25 MHz).** The
> horizontal counts here are therefore in **doubled** ticks: one 800-pixel line is
> 1600 ticks and the 640-pixel active area is 1280. Sizing them for 25 MHz gives a
> 119 Hz retrace instead of 59.5 Hz, and every vsync-paced game runs at double
> speed. That was a real bug.

`50 MHz / (1600 × 525) = 59.52 Hz`, matching the display.

## Known limitation: phase

The frequency matches the real display exactly, but the **phase is arbitrary** —
these counters free-run independently of `vga`'s, starting from power-up. So
vsync-synced animation may tear at one fixed screen line.

If that ever matters, the fix is to feed `vga`'s real `VS` into this module instead
of counting locally. In practice games have been happy: `DIGGER` spins on bit 3 and
paces correctly.

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

- [vga](vga.md) — the display itself
- [Tools](../tools.md) — `CGATEST4` verifies this port with a timeout so a stuck bit
  reports instead of hanging
