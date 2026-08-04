# sevenseg

Source: [`sevenseg.vhd`](../../sevenseg.vhd) · Instance `sevenseg1` · Clock `c0` (8.33 MHz)

One 7-segment digit that displays a **full byte** by time-multiplexing its two
nibbles. This is the machine's POST-code and debug display, and it has earned its
keep repeatedly.

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK` | IN | 1 | 8.33 MHz (`c0`) |
| `DATA` | IN | 8 | CPU write data |
| `ADDR` | IN | 16 | I/O address |
| `WR` | IN | 1 | I/O write strobe, active low |
| `SEG_A`…`SEG_G` | OUT | 1 each | Segment drives, **active high** → `SEG_*` pins |

## Address

| Port | Access | Function |
|---|---|---|
| `0x80` | W | Byte to display |

Reads are not decoded, so `IN AL, 0x80` returns the open bus — which is how the BIOS
uses it as a scratch I/O delay.

## Display cycle

```
high nibble   1 s
low nibble    1 s
blank         2 s
repeat
```

So `0x73` shows `7` … `3` … dark … `7` … Timing constants are raw cycle counts and
assume `CLK = 8.333 MHz`:

```vhdl
CONSTANT T_NIBBLE : integer := 8_333_333;    -- 1 s per nibble
CONSTANT T_BLANK  : integer := 16_666_666;   -- 2 s blank gap
```

> Both the source and this page said **500 ms and 1 s** until the figures were checked
> against the constants. They had said it since the file was written — 5 000 000 cycles
> on the original 5 MHz bus is one second, not half of one. Every rescale since correctly
> preserved the *behaviour* and carried the wrong label along with it. A comment that
> restates a number rather than deriving it cannot catch its own error.

## The value-change detail

```vhdl
IF (WR = '0' AND ADDR = x"0080" AND DATA /= display_byte) THEN
    display_byte <= DATA;
    phase_cnt    <= 0;      -- restart from the high nibble
END IF;
```

Writing a **new** value restarts the cycle, so a POST code the firmware halts on is
shown cleanly from the beginning and keeps repeating.

> ⚠️ **Writing the *same* value repeatedly does not restart the cycle.** That is
> usually what you want, but it has a diagnostic consequence: a program stuck in a
> loop that keeps writing one code produces a **rock-steady** display, visually
> identical to a machine hung with that code showing once. During one debugging
> session this made a retry loop look exactly like a hang. If a code is steady, it
> does not tell you whether the code was written once or a million times.

## Use as a debug channel

Because it is a single `OUT` with no setup, it works anywhere — including the
bootloader before RAM is trusted, and inside interrupt handlers. Both the loader and
the BIOS use it:

| Source | Codes |
|---|---|
| [bootloader](bootrom.md) | `1`–`7` boot progress, `A`/`B` flash fallback, `EF` no BIOS in flash |
| BIOS `hd_int13` (when `HD_DEBUG = 1`) | raw `AH` on entry, `B8`/`B2` on exit, `C1` refused, `C9` unsupported |
| DOS tools | `HDSTEP` writes `11`–`14` around a single `INT 13h` call |

When adding markers, print the **raw** value rather than a folded one. An early
version printed `(AH & 0x0F) | 0xA0`, so `A8` was equally consistent with `AH = 0x08`,
`0x18` or `0x88` — which sent the investigation down the wrong path entirely.

## Related

- [Gotchas](../gotchas.md) — how to instrument this machine effectively
- [Tools](../tools.md) — the DOS diagnostics that use port `0x80`
