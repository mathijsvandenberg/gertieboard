# timer8253

Source: [`timer8253.vhd`](../../timer8253.vhd) · Instance `timer1` · Clock `c2` (1.1905 MHz)

An Intel 8253 PIT, simplified for IBM 5160 use. This is the module that produces
the 18.2 Hz system tick and the speaker tone.

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK` | IN | 1 | **1.1905 MHz** (`c2`) — the counter clock, not the bus clock |
| `DATA` | IN | 8 | CPU write data |
| `DATA_OUT` | OUT | 8 | Read data, `'Z'` when not addressed |
| `ADDR` | IN | 16 | I/O address |
| `RD` | IN | 1 | I/O read strobe, active low |
| `WR` | IN | 1 | I/O write strobe, active low |
| `G0` | IN | 1 | Counter 0 gate — tied `'1'` |
| `G1` | IN | 1 | Counter 1 gate — tied `'1'` |
| `G2` | IN | 1 | Counter 2 gate — from `ppi8255.TIMER2_GATE` (port `0x61` bit 0) |
| `OUT0` | OUT | 1 | → `int8259.IRQ0` — system tick |
| `OUT1` | OUT | 1 | **`OPEN`** — DRAM refresh on a real XT, unused here |
| `OUT2` | OUT | 1 | → speaker AND gate and `ppi8255.TIMER2_OUT` |

## Addresses

| Port | Access | Function |
|---|---|---|
| `0x40` | R/W | Counter 0 — system tick (IRQ0) |
| `0x41` | R/W | Counter 1 — DRAM refresh on a real XT; harmless here |
| `0x42` | R/W | Counter 2 — speaker tone |
| `0x43` | W | Control word, or counter-latch command |

## Clock rate

`c2` is 50 MHz ÷ 42 = **1.19048 MHz**, against the XT's 1.193182 MHz — a 0.23 %
error. That is close enough that the DOS clock keeps good time and timer-paced
software runs at the right speed.

> The ÷42 divider is deliberate. An earlier investigation misread the PLL's
> `inclk0_input_frequency` (which is a **period in picoseconds**) and concluded the
> timer was running at 476 kHz. It is not. See [gotchas](../gotchas.md).

## Implemented features

- Modes **0** (interrupt on terminal count), **2** (rate generator) and **3**
  (square wave) — which covers everything the XT BIOS and DOS use
- RW modes `01` (LSB only), `10` (MSB only), `11` (LSB then MSB)
- Counter-latch command, so diagnostic ROMs can read a stable count
- `CR = 0` treated as 65536, per the real 8253

### Mode 3 and the 18.2 Hz tick

The XT BIOS programs counter 0 with divisor 0 (meaning 65536) in mode 3. That is
handled explicitly:

```vhdl
IF CR0 = x"0000" THEN
    O0 <= CE0(15);          -- half-period is 32768, i.e. the count MSB
ELSIF CE0 > ("0" & CR0(15 DOWNTO 1)) THEN
    O0 <= '1';
ELSE
    O0 <= '0';
END IF;
```

> That first branch has to be there. Excluding `CR = 0` means `OUT0` never toggles,
> no edge ever reaches IR0, and interrupt level 0 simply fails — no system tick,
> no `INT 08h`, no DOS clock.

`1.19048 MHz / 65536 = 18.16 Hz`, the familiar tick.

## Structure

Each counter has the full 8253 register set:

| Signal | Purpose |
|---|---|
| `CEn` | Count Element — the live counter |
| `CRn` | Count Register — the value most recently programmed |
| `OLn` | Output Latch — snapshot taken by a latch command |
| `Ln` | `'1'` = `OL` holds a frozen value |
| `MODEn` | mode, from control-word bits 3:1 |
| `RWn` | RW mode, from control-word bits 5:4 |
| `WTOGn` / `RTOGn` | byte-sequence toggles for two-byte access |
| `NEWn` | reload pending — `CR` copied into `CE` on the next clock |

Writes latch on the **rising** edge of the internal active-high write signal (the
end of the `/IOW` pulse); the read state advances after the read strobe falls, by
which time the CPU has already sampled the data.

## Reprogramming

Games commonly reprogram counter 0 to a faster rate to drive their own game loop.
That path works: a control-word write sets the mode, the two data bytes load `CR`,
`NEW0` triggers the reload, and `OUT0` resumes toggling to generate IRQ0 edges.
Verified on hardware with `CGATEST3`, which reprograms the PIT to ~1 kHz and
confirms `INT 08h` keeps firing.

## Related

- [int8259](int8259.md) — where `OUT0` goes
- [ppi8255](ppi8255.md) — the speaker gate and read-back
