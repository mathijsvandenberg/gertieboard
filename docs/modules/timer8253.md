# timer8253

Source: [`timer8253.vhd`](../../timer8253.vhd) · Instance `timer1` · Clock `c0` (8.33 MHz bus), counting at `c2` (1.1905 MHz)

An Intel 8253 PIT, simplified for IBM 5160 use. This is the module that produces
the 18.2 Hz system tick and the speaker tone.

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK` | IN | 1 | **8.33 MHz** (`c0`) — the *bus* clock, so the register interface can see an I/O cycle |
| `CNT_TICK` | IN | 1 | **1.1905 MHz** (`c2`) — the counting rate, fed in as data and used as an enable |
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

## Two clocks, and why

The counters advance at 1.19 MHz. The **register interface does not run there** — it
runs on the bus clock, and `c2` arrives as an input sampled through a three-stage
synchroniser and used as a count enable:

```vhdl
ct_sync <= ct_sync(1 DOWNTO 0) & CNT_TICK;   -- in the CLK process
ct_en   <= ct_sync(1) AND NOT ct_sync(2);    -- one CLK-wide pulse per c2 edge
...
ELSIF (G0 = '1' AND ct_en = '1') THEN        -- each counter
```

**This module used to be clocked entirely from `c2`, and that was the machine's real
speed ceiling.** A PIT register interface running at 1.19 MHz has ~840 ns between edges.
At 5 MHz the CPU's I/O write strobe was wide enough to be caught anyway and everything
worked; every attempt to raise the bus clock made the window narrower relative to the
strobe until writes to the PIT started being missed — a game reprogramming counter 0
would get some of its bytes accepted and some dropped. The symptom was a game crashing
during play at 6.25 MHz and above, which reads as a CPU or memory limit and was chased
as one for a long time.

With the interface on `c0`, 8.333 MHz runs. Alley Cat plays where it crashed before.

> The rate is exact and only the *phase* of the tick is resynchronised, which no 8253
> user can observe. What the timing analyser sees is a clock net driving a register's D
> input, which it times against `c2`'s own edges — meaningless here, and it showed up as
> a −0.310 ns hold violation. Absorbing that is the synchroniser's entire job, so there
> is a `set_false_path` for it in [`gertieboard.sdc`](../../gertieboard.sdc).

## Clock rate

`c2` is 50 MHz ÷ 42 = **1.19048 MHz**, against the XT's 1.193182 MHz — a 0.23 %
error. That is close enough that the DOS clock keeps good time and timer-paced
software runs at the right speed.

It is divided from the 50 MHz reference and **not** from `c0`, so it does not move when
the bus clock does. That is what makes it an honest time reference — and it is what the
BIOS measures the CPU clock against at POST.

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
