# =============================================================================
# gertieboard.sdc
#
# One PLL, integer-ratio outputs -> all SYNCHRONOUS to each other:
#   c0 (clk[0]) = 100  MHz  master for the programmable CPU clock
#   c1 (clk[1]) = 25   MHz  VGA pixel clock
#   c2 (clk[2]) = 1.19 MHz  8253 counter clock (50/42, ~XT's 1.193182)
#   c3 (clk[3]) = 50   MHz  RAM / system
#
# The bus clock is no longer a PLL output. cpuclk1 divides c0 by a high count
# plus a low count, both selected at run time through I/O 0xE5 (cpuclk.vhd),
# giving 5 .. 16.667 MHz with every edge on c3's 20 ns grid.
# Two consequences for this file:
#
#   * CPU_CLK_INT is declared at the FASTEST step the hardware will accept
#     (cpuclk's MAX_IDX, currently 6 = /6 of 100 MHz = 16.667 MHz). That makes
#     the timing report a statement about the worst case the machine can be
#     COMMANDED into, not about the step it happens to boot at. Raise MAX_IDX
#     and this divide together or the report stops meaning anything.
#   * Every step's rising edges land on c3's 20 ns grid, so the crossings
#     between the bus clock and the 50 MHz side are analysed at a 20 ns
#     requirement at every step. Only bus-clock-to-bus-clock paths tighten as
#     the step rises, which is why a single worst-case declaration covers the
#     whole ladder.
#
# A SECOND PLL (pll48_1) makes 48 MHz for the USB SIE. It is derived from the
# same 50 MHz input but is NOT integer-related to the others (24/25), so it
# gets its own asynchronous group. Leaving it out of the groups is what put
# -2.483 ns of setup slack on c0: the analyser paired 5 MHz launches with
# 48 MHz latches and took the worst edge alignment, right across the domain
# crossing (TNS -4474 ns). Nothing was really broken -- but negative slack is
# what stalled this project for years, so it does not get to sit there.
#
# Key points:
#   * The PLL outputs are integer-related, so they are timed TOGETHER, not
#     declared asynchronous (that was the original bug that left the
#     busdecode<->PSRAM paths unanalyzed).
#   * The VGA pixel clock is the one exception: it meets the system clock only
#     inside the dual-port framebuffer BRAM, so it is its own async group.
#   * The off-chip V20 bus is a slow, handshake-governed interface (READY
#     controls correctness, not single-cycle setup), so the CPU pins are
#     false-pathed both directions. This is what clears the red WITHOUT any
#     bogus input/output-delay numbers.
# =============================================================================

# -----------------------------------------------------------------------------
# Clocks
# -----------------------------------------------------------------------------
create_clock -name CLOCK50 -period 20.000 [get_ports CLOCK50]
derive_pll_clocks

# The bus clock, as produced by cpuclk1's toggle flop, at the fastest step.
#
# -divide_by models a 50 % duty cycle; the fastest step is really 33 % (20 ns
# high, 40 ns low). That mismatch is harmless HERE because nothing internal is
# clocked on this net's falling edge -- the rising edges, which are what the
# model gets right, are every 60 ns either way. Do not "fix" it by describing
# the duty: the reason the duty is 33 % is that both edges then land on c3's
# 20 ns grid, and that is a property of the hardware, not of the analysis.
create_generated_clock -name CPU_CLK_INT \
    -source [get_pins {pll1|altpll_component|auto_generated|pll1|clk[0]}] \
    -divide_by 6 \
    [get_pins {cpuclk1|clk_q|q}]

create_generated_clock -name CPU_CLK_OUT \
    -source [get_pins {cpuclk1|clk_q|q}] \
    [get_ports CPU_CLK]

derive_clock_uncertainty

# -----------------------------------------------------------------------------
# Clock groups
#   - VGA pixel clock (c1): its own async domain (framebuffer BRAM handles CDC)
#   - USB 48 MHz: its own async domain. usb_host crosses GO as a toggle
#     through a three-stage synchroniser, samples its command registers only
#     while the engine is idle, and moves packet data through dual-port
#     buffers never accessed from both sides at once -- BUSY enforces that.
#   - everything else: synchronous, timed together
# -----------------------------------------------------------------------------
# c1 IS NOT ASYNCHRONOUS AND NO LONGER PRETENDS TO BE.
#
# It used to have its own group, on the stated grounds that it "meets the system
# clock only inside the dual-port framebuffer BRAM". That was true when it was
# written and stopped being true when the EGA planes moved to SDRAM: ega_mem
# carries row_addr -- a SIXTEEN-BIT BUS -- from c1 to c3, with fill_tgt beside
# it, and nothing about that is inside a BRAM.
#
# Cut from analysis, those seventeen wires were placed by luck. Nothing checked
# them, so a build could close timing and say nothing whatever about whether
# they arrive -- which is exactly how unrelated edits and fitter seeds came to
# decide whether the machine booted.
#
# c1 is 25 MHz from the same PLL as c3's 50 MHz: integer-related and phase
# aligned, like every other output here. So it is timed WITH them, which is what
# the note at the top of this file says the others are done for, and for the
# same reason. The two-flop synchronisers on those crossings stay -- they cost
# nothing and they are correct -- but correctness no longer RESTS on them.
#
# pll48_1 keeps its own group: 24/25 of the input, genuinely unrelated.
set_clock_groups -asynchronous \
    -group { pll48_1|altpll_component|auto_generated|pll1|clk[0] } \
    -group { CLOCK50 \
             pll1|altpll_component|auto_generated|pll1|clk[0] \
             pll1|altpll_component|auto_generated|pll1|clk[1] \
             pll1|altpll_component|auto_generated|pll1|clk[2] \
             pll1|altpll_component|auto_generated|pll1|clk[3] \
             CPU_CLK_INT \
             CPU_CLK_OUT }

# -----------------------------------------------------------------------------
# Off-chip V20 bus - false-pathed both directions
# Correctness is governed by the READY handshake and the long (>=200 ns) bus
# cycle, not by meeting setup on a single 20 ns system-clock edge. Constraining
# these with single-cycle delays produces false failures (the -10.9 / -3.1 ns
# paths in the previous report were entirely placeholder input/output delays).
# -----------------------------------------------------------------------------
set_false_path -from [get_ports {CPU_RD CPU_WR CPU_IOM CPU_ALE CPU_DEN \
                                 CPU_DTR CPU_INTA CPU_HLDA}] -to *
set_false_path -from [get_ports {CPU_A[*]}]  -to *
set_false_path -from [get_ports {CPU_AD[*]}] -to *
set_false_path -from * -to [get_ports {CPU_AD[*]}]
set_false_path -from * -to [get_ports {CPU_RDY CPU_CLK CPU_RST CPU_NMI \
                                       CPU_INTR CPU_HLD}]

# -----------------------------------------------------------------------------
# VGA outputs, debug header and reset
#
# The monitor re-syncs on every frame and the DBG pins only feed a logic
# analyser, so neither has a meaningful setup/hold requirement on-chip.
# -----------------------------------------------------------------------------
set_false_path -from * -to [get_ports {VGA_HS VGA_VS VGA_RGB[*] DBG[*]}]
set_false_path -from [get_ports RESET] -to *

# -----------------------------------------------------------------------------
# PSRAM pins: left unconstrained for now (the design runs reliably at the
# current 50 MHz system clock). To push the PSRAM faster, that becomes the
# separate "phase-shifted read capture" exercise: add a phase-shifted PLL tap
# (c4), capture RAM_SIO on it, and constrain RAM_SIO/RAM_SCK/RAM_CS here.
# -----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# timer8253's counting tick.
#
# The PIT's register interface runs on c0 so it can see a CPU I/O cycle, while
# its counters advance at c2's 1.1905 MHz. c2 is therefore fed in as DATA and
# sampled by a three-stage synchroniser (ct_sync). The analyser sees a clock
# net driving a register's D input and times it against c2's own edges, which
# is meaningless here and shows up as a hold violation of about -0.3 ns.
#
# Absorbing that is the synchroniser's entire job. What matters is the rate,
# which is exact, not the phase, which no 8253 user can observe.
set_false_path -from [get_clocks {pll1|altpll_component|auto_generated|pll1|clk[2]}]                -to   [get_registers {timer8253:timer1|ct_sync[0]}]
