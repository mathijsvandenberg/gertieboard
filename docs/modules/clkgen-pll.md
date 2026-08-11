# clkgen, cpuclk and pll

Sources: [`clkgen.vhd`](../../clkgen.vhd), [`cpuclk.vhd`](../../cpuclk.vhd),
[`pll.vhd`](../../pll.vhd) / [`pll.qip`](../../pll.qip)
· Instances `clkgen1`, `cpuclk1`, `pll1`, `pll48_1`

## pll — clock generation

An `altpll` megafunction wrapper. The DE0-Nano's 50 MHz oscillator comes in on
`inclk0`; four outputs are used.

### Ports

| Port | Dir | Purpose |
|---|---|---|
| `inclk0` | IN | 50 MHz reference (`CLOCK50`, `PIN_R8`) |
| `c0` | OUT | 100 MHz |
| `c1` | OUT | 25 MHz |
| `c2` | OUT | 1.1905 MHz |
| `c3` | OUT | 50 MHz |
| `c4` | OUT | unused (`OPEN`) |

### Dividers and consumers

| Output | Divider | Frequency | Drives |
|---|---|---|---|
| `c0` | ×2 | **100 MHz** | `cpuclk1`, and nothing else |
| `c1` | ÷2 | **25 MHz** | `vga.CLK_VGA` |
| `c2` | ÷42 | **1.1905 MHz** | `timer8253` |
| `c3` | ÷1 | **50 MHz** | `mem_hybrid`, `sdram_ctrl`, `ps2_kbd_ppi` |

> **Reading `pll.vhd`:** `inclk0_input_frequency => 20000` is a **period in
> picoseconds** — 20 ns, i.e. 50 MHz. It is *not* kHz. Misreading it produced a
> confident but entirely wrong conclusion that the 8253 ran at 476 kHz, and sent an
> investigation off after a non-existent bug. `c1` landing on exactly 25 MHz (the
> standard VGA pixel clock) independently confirms the 50 MHz input.

## cpuclk — the programmable bus clock

The machine's speed used to be `clk0_divide_by` in `pll.vhd`. Every step of a sweep
cost a Quartus build, a reprogram, and a chance to get confused about which of three
separately-loaded artefacts was on the bench — an hour was once spent testing
8.333 MHz in the belief it was 6.25. With the D70108HCZ-16 parts there is a whole
ladder to walk, so the ladder is in hardware and the step is a register.

### The register — I/O 0xE5

| | Write | Read |
|---|---|---|
| bit 7 | — | `0` = speed control present (an older bitstream leaves 0xE5 on the open bus, which reads `0xFF`) |
| bits 6:4 | — | `MAX_IDX`, the fastest step this bitstream allows |
| bits 2:0 | step, clamped to `MAX_IDX` | the step in force |

`RESET` restores the default, for [`ctrl_reg`](ctrl_reg.md)'s reason: a step the board
cannot run is otherwise unrecoverable, because the code that would write a slower one
can no longer be fetched. The reset button and Ctrl+Alt+Del both get you back.

### The ladder

`f = 100 MHz / (hi + lo)`, counted in 100 MHz cycles. See the next section for why
`hi` and `lo` are not always equal.

| idx | hi + lo | f_cpu | period | note |
|---|---|---|---|---|
| 0 | 10 + 10 | 5.000 MHz | 200 ns | what the board ran at for most of its life |
| 1 | 8 + 8 | 6.250 | 160 ns | |
| 2 | 6 + 8 | 7.143 | 140 ns | |
| 3 | 6 + 6 | 8.333 | 120 ns | **default** — the speed before the ladder existed |
| 4 | 4 + 6 | 10.000 | 100 ns | the P2120's turbo speed |
| 5 | 4 + 4 | 12.500 | 80 ns | |
| 6 | 2 + 4 | 16.667 | 60 ns | the −16 parts' rated ceiling; `MAX_IDX` |
| 7 | 2 + 2 | 25.000 | 40 ns | past the rating; reachable only if `MAX_IDX` is raised |

There is no baud column any more, and that is the improvement. The host link used to be
an integer divide of *this* clock, so it had to be re-derived per step and was +4.2 % at
the boot step. [`fdc8272`](fdc8272.md) now clocks its UART from `c3`, so the link is
1,000,000 baud exactly at every step and is no longer a function of the speed at all.

**5.556 MHz (50 ÷ 9) is missing but no longer excluded.** It sits on the grid perfectly
well (80/100 ns); it was left off because its best baud divisor was 7.4 % out. That
reason has expired. It is absent now only because renumbering the ladder would cost more
than the step is worth.

### Both edges land on c3's 20 ns grid — and that is not free

The high and low counts are set independently, and they are **not equal at every step**:

| idx | hi / lo (ns) | f_cpu | duty | falling edge |
|---|---|---|---|---|
| 0 | 100 / 100 | 5.000 | 50 % | 100 ns |
| 1 | 80 / 80 | 6.250 | 50 % | 80 ns |
| 2 | 60 / 80 | 7.143 | 43 % | 60 ns |
| 3 | 60 / 60 | 8.333 | 50 % | 60 ns |
| 4 | 40 / 60 | 10.000 | 40 % | 40 ns |
| 5 | 40 / 40 | 12.500 | 50 % | 40 ns |
| 6 | 20 / 40 | 16.667 | 33 % | 20 ns |
| 7 | 20 / 20 | 25.000 | 50 % | 20 ns |

The first version of this file insisted on 50 % duty everywhere. That forces the falling
edge to `half × 10 ns`, which is **off** the 20 ns grid whenever `half` is odd — and on
hardware every odd step died. 7.143 MHz could not execute a two-byte `loop` with
interrupts disabled, at a *lower* clock and lower current draw than the 8.333 MHz the
same machine runs all day. No speed limit and no supply problem can produce that; edge
alignment can.

50 % was self-imposed and wrong. An 8088/V20 is designed around an 8284, which delivers
a **33 % duty cycle**. Splitting the odd steps to put both edges on the grid gives
16.667 MHz a 20 ns clock-high — which is exactly what an 8284 gives a 16 MHz part. The
objection that once ruled out dividing 50 MHz directly ("a 20 ns clock-high is below what
a −16 part is specified for") turns out to have been an objection to the *correct*
waveform.

Two properties still have to hold at every step:

- **Integer-related to `c3`.** Every edge, rising and falling, is a multiple of 20 ns
  from the origin. This is the constraint that killed the earlier 8 MHz attempt
  (50 × 4 ÷ 25): a non-integer ratio puts a `c3` edge 5 ns before a bus-clock edge, it
  failed timing at −3.28 ns, and nothing in the design can absorb that.
- **No runt.** The shortest half-period the design can emit is 20 ns, at any step and
  whenever the step is written.

There is a payoff in the timing report that is worth understanding, because it is what
makes the whole ladder cheap: since bus-clock edges coincide with `c3` edges, the
**crossings between the two are analysed at a 20 ns requirement at every step**. Only
bus-clock-to-bus-clock paths tighten as the step rises, and those have room to spare.
Measured, at 85 °C:

| `MAX_IDX` | SDC divide | declared bus clock | worst setup on that clock |
|---|---|---|---|
| 6 | ÷6 | 16.667 MHz | +3.617 ns |
| 7 | ÷4 | 25.000 MHz | +3.736 ns |

Nearly identical — the worst path is the fixed 20 ns crossing, not a same-clock path.
**The ladder is not limited by the FPGA.** The whole design closes timing at 25 MHz;
what stops there is the CPU. The binding constraint in this design remains `c3` at
50 MHz (+0.468 ns), where it was before any of this.

### Changing step without producing a runt

This clock feeds the entire bus *and* the CPU pin, so a short pulse during a change is
not a glitch, it is a crash. A new divisor is adopted only at the instant the clock is
about to go high — a period boundary — and both halves of a period use the same value.
The shortest half-period the design can emit is 20 ns, whatever is written and whenever
it is written.

The step register runs on the generated clock (it has to see an I/O cycle); the divider
runs on 100 MHz. The three-stage synchroniser between them adopts a value only after
seeing it twice, so the one-sample skew while three bits change cannot be mistaken for
a step of its own — which matters, because an intermediate combination could be a
*faster* step than either the old or the new one.

`RESET` does **not** stop this clock; it forces the step back to the default within one
period. Both halves of that are load-bearing: a V20 needs a running clock throughout
reset to finish its internal reset sequence, and the step register is clocked by this
net — stop it and the register never sees the reset that is meant to clear it. It also
takes the **raw** reset rather than `clkgen`'s `RST_OUT`, because `clkgen` is clocked by
what `cpuclk` produces.

### Raising the ceiling

`MAX_IDX` in `gertieboard.vhdl` and `-divide_by` in `gertieboard.sdc` are **one
setting written in two places**, and nothing checks that they agree. Raise both or
neither: raise the generic alone and the design runs at a step the timing report never
analysed; raise the SDC alone and the report describes a step the hardware refuses.

### Two things that do not follow the step

- **The BIOS tick stays 18.2 Hz.** It comes from `c2`, divided from the 50 MHz
  reference, so it is an honest time reference across speed changes — which is what
  makes [`tools/speed.asm`](../tools.md) able to *measure* the change rather than
  assume it.
- **`busdecode`'s READY backstop counts CPU clocks**, so it shortens in real time as
  the step rises. It is sized for the fastest step: 256 clocks is 15.4 µs at
  16.667 MHz, against a worst legitimate access of about 4.9 µs.

### Why the old ÷6 was chosen, for the record

10 MHz was the target — the Philips P2120 this machine imitates ran its V20 at 10 in
turbo mode — and 10 MHz did not boot on the `-8` part: the serial loader was never even
asked for a block. Whether that was the CPU, the 3.3 V logic levels driving a 5 V part,
or something on the bus was never established, which is precisely what the ladder and
the `-16` parts exist to settle.

### The second PLL

The top level once carried a second `pll` instance with **every output
unconnected**, which Quartus simply optimised away. That slot is now
[`pll48`](#pll48--48-mhz-for-usb), the 48 MHz source for the USB host.

## clkgen — reset stretch

Deliberately trivial: it turns the reset input into a clean, minimum-width
synchronous reset for everything else.

### Ports

| Port | Dir | Purpose |
|---|---|---|
| `CLK` | IN | the bus clock from `cpuclk` (8.333 MHz after reset) |
| `RESET` | IN | **Active LOW** reset request |
| `RST_OUT` | OUT | **Active HIGH** system reset |

### Behaviour

```vhdl
IF (RESET = '0') THEN
    CNT <= 0;  RST_OUT <= '1';        -- held while asserted
ELSIF (CNT < 10) THEN
    RST_OUT <= '1';  CNT <= CNT + 1;  -- plus 10 more clocks
ELSE
    RST_OUT <= '0';
```

So `RST_OUT` stays high while the request is asserted and for 10 CPU clocks after it
releases -- 2 µs at 8.333 MHz, and 600 ns at the top of the ladder, because it counts
clocks and not time. The stretch is not what the CPU actually waits for: `clkgen` also
holds it until `MEM_READY`, which is ~200 µs of PSRAM init and does not move.

### What feeds it

```vhdl
n_reset <= RESET AND NOT n_cad_rst;
```

Either the reset button (`PIN_A8`, active low) or a hardware Ctrl+Alt+Del from
[`ps2_kbd_ppi`](ps2_kbd_ppi.md). Both therefore produce a **genuine** reset, which
matters because [`bootrom`](bootrom.md) re-arms its overlay on reset and the BIOS is
fetched again from scratch.

## Timing constraints

[`gertieboard.sdc`](../../gertieboard.sdc) declares the 50 MHz input, calls
`derive_pll_clocks`, and then creates two generated clocks: `CPU_CLK_INT` for
`cpuclk1`'s toggle flop, declared at the fastest step the hardware will accept, and
`CPU_CLK_OUT` for the `CPU_CLK` pin off that. The VGA pixel clock is its own
asynchronous group; the rest are integer-related and timed together.

Declaring `CPU_CLK_INT` at `MAX_IDX` rather than at the default step is the point: it
makes the timing report a statement about the worst case the machine can be *commanded*
into, not about the step it happens to boot at.

> ⚠️ The SDC references the PLL by **instance path**
> (`pll1|altpll_component|auto_generated|pll1|clk[0]`). Renaming top-level instances
> silently drops the generated clock and the clock groups from analysis — timing then
> "passes" while being under-constrained. See [gotchas](../gotchas.md).

## pll48 — 48 MHz for USB

Source: [`pll48.vhd`](../../pll48.vhd) · Instance `pll48_1`

```vhdl
clk0_multiply_by => 24,
clk0_divide_by   => 25,       -- 50 * 24 / 25 = 48 MHz exactly
```

USB full speed is 12 Mbps and a soft SIE has to oversample it. 4× is the usual choice —
fast enough to resynchronise on every transition, slow enough to close timing easily —
and 4 × 12 = 48. The ratio is exact, so there is no fractional accumulator and no phase
error building up across a long packet.

The alternatives were worse. 50 MHz direct gives 4.1667 samples per bit and needs a
fractional DPLL. 24 MHz (2×) leaves nowhere to sample.

It is a **second PLL** rather than another `pll1` output, for the reason in
[architecture](../architecture.md#clocks): `pll1`'s outputs all use `multiply_by => 1`
and share a VCO that is a plain multiple of 50 MHz. It occupies the slot that used to
hold an unconnected PLL instance.

`locked` is wired through to [`usb_host`](usb_host.md) and readable from software, so a
test program can distinguish "the PLL never came up" from "the PLL is fine but nothing
is answering".

## Related

- [Architecture](../architecture.md#clocks) — the clock tree in context
- [Pinout](../pinout.md#timing-constraints)

## The MegaWizard metadata can disagree with the hardware

`pll.vhd` carries two descriptions of `c0`: the `clk0_divide_by` in the actual
instantiation, which is what gets synthesised, and a `DIV_FACTOR0` line in the
`Retrieval info` block at the bottom, which is what the MegaWizard reloads if the PLL is
ever reopened in the GUI.

**They had drifted apart.** The instantiation said `10` (5 MHz) while `DIV_FACTOR0` said
`20` (2.5 MHz) — the residue of an old ÷20 detune, corrected in one place and not the
other. Nothing would have reported it: opening the PLL in the wizard and clicking Finish
would have regenerated the design at *half speed*, with no error, no warning, and a
machine that simply ran slowly.

`c0` is now ×2 ÷1 = 100 MHz, and `MULT_FACTOR0` / `DIV_FACTOR0` / `OUTPUT_FREQ0` /
`EFF_OUTPUT_FREQ_VALUE0` were all edited to match. If you hand-edit a divider, edit the
`Retrieval info` to match — it is not a comment, it is the wizard's saved state. Several
of the *other* outputs' `Retrieval info` entries are still stale from earlier edits
(`DIV_FACTOR1` says 8 for a ÷2 output); they are harmless only for as long as nobody
opens the wizard.
