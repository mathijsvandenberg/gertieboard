# clkgen and pll

Sources: [`clkgen.vhd`](../../clkgen.vhd), [`pll.vhd`](../../pll.vhd) / [`pll.qip`](../../pll.qip)
· Instances `clkgen1`, `pll1`, `pll2`

## pll — clock generation

An `altpll` megafunction wrapper. The DE0-Nano's 50 MHz oscillator comes in on
`inclk0`; four outputs are used.

### Ports

| Port | Dir | Purpose |
|---|---|---|
| `inclk0` | IN | 50 MHz reference (`CLOCK50`, `PIN_R8`) |
| `c0` | OUT | 10 MHz |
| `c1` | OUT | 25 MHz |
| `c2` | OUT | 1.1905 MHz |
| `c3` | OUT | 50 MHz |
| `c4` | OUT | unused (`OPEN`) |

### Dividers and consumers

| Output | Divider | Frequency | Drives |
|---|---|---|---|
| `c0` | ÷5 | **10 MHz** | `CPU_CLK` and the whole I/O bus — `busdecode`, `ppi8255`, `sevenseg`, `ctrl_reg`, `int8259`, `dma8237`, `fdc8272`, `flash`, `bootrom`, `vga.CLK_CPU` |
| `c1` | ÷2 | **25 MHz** | `vga.CLK_VGA` |
| `c2` | ÷42 | **1.1905 MHz** | `timer8253` |
| `c3` | ÷1 | **50 MHz** | `mem_hybrid`, `ps2_kbd_ppi`, `cga_status` |

> **Reading `pll.vhd`:** `inclk0_input_frequency => 20000` is a **period in
> picoseconds** — 20 ns, i.e. 50 MHz. It is *not* kHz. Misreading it produced a
> confident but entirely wrong conclusion that the 8253 ran at 476 kHz, and sent an
> investigation off after a non-existent bug. `c1` landing on exactly 25 MHz (the
> standard VGA pixel clock) independently confirms the 50 MHz input.

`c0` at 10 MHz is the machine's speed. It was briefly ÷20 (2.5 MHz) in uncommitted
work, which halved performance *and* silently halved the floppy link's baud rate,
because `fdc8272` computes `BAUD_DIV = CLK_FREQ / BAUD` from a generic that still said
5 MHz.

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
| `CLK` | IN | 10 MHz (`c0`) |
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

So `RST_OUT` stays high while the request is asserted and for 10 CPU clocks (2 µs)
after it releases.

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
`derive_pll_clocks`, and creates a generated clock for the `CPU_CLK` output pin. The
VGA pixel clock is its own asynchronous group; the rest are integer-related and timed
together.

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
`20` (2.5 MHz) — the residue of the ÷20 detune above, corrected in one place and not the
other. Nothing would have reported it: opening the PLL in the wizard and clicking Finish
would have regenerated the design at *half speed*, with no error, no warning, and a
machine that simply ran slowly.

Both now say `5`. If you hand-edit a divider, edit the `Retrieval info` to match — it is
not a comment, it is the wizard's saved state.
