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
| `c0` | OUT | 5 MHz |
| `c1` | OUT | 25 MHz |
| `c2` | OUT | 1.1905 MHz |
| `c3` | OUT | 50 MHz |
| `c4` | OUT | unused (`OPEN`) |

### Dividers and consumers

| Output | Divider | Frequency | Drives |
|---|---|---|---|
| `c0` | ÷10 | **5 MHz** | `CPU_CLK` and the whole I/O bus — `busdecode`, `ppi8255`, `sevenseg`, `ctrl_reg`, `int8259`, `dma8237`, `fdc8272`, `flash`, `bootrom`, `vga.CLK_CPU` |
| `c1` | ÷2 | **25 MHz** | `vga.CLK_VGA` |
| `c2` | ÷42 | **1.1905 MHz** | `timer8253` |
| `c3` | ÷1 | **50 MHz** | `mem_hybrid`, `ps2_kbd_ppi`, `cga_status` |

> **Reading `pll.vhd`:** `inclk0_input_frequency => 20000` is a **period in
> picoseconds** — 20 ns, i.e. 50 MHz. It is *not* kHz. Misreading it produced a
> confident but entirely wrong conclusion that the 8253 ran at 476 kHz, and sent an
> investigation off after a non-existent bug. `c1` landing on exactly 25 MHz (the
> standard VGA pixel clock) independently confirms the 50 MHz input.

`c0` at 5 MHz is the machine's speed. It was briefly ÷20 (2.5 MHz) in uncommitted
work, which halved performance *and* silently halved the floppy link's baud rate,
because `fdc8272` computes `BAUD_DIV = CLK_FREQ / BAUD` from a generic that still said
5 MHz.

### pll2

A second `pll` instance exists in the top level with **every output unconnected** — a
leftover from the schematic era. Quartus optimises it away; the fitter reports one
PLL in use.

## clkgen — reset stretch

Deliberately trivial: it turns the reset input into a clean, minimum-width
synchronous reset for everything else.

### Ports

| Port | Dir | Purpose |
|---|---|---|
| `CLK` | IN | 5 MHz (`c0`) |
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

## Related

- [Architecture](../architecture.md#clocks) — the clock tree in context
- [Pinout](../pinout.md#timing-constraints)
