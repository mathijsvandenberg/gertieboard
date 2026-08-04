# =============================================================================
# gertieboard.sdc
#
# One PLL, integer-ratio outputs -> all SYNCHRONOUS to each other:
#   c0 (clk[0]) = 5    MHz  busdecode + CPU_CLK output pin
#   c1 (clk[1]) = 25   MHz  VGA pixel clock
#   c2 (clk[2]) = 1.19 MHz  8253 counter clock (50/42, ~XT's 1.193182)
#   c3 (clk[3]) = 50   MHz  RAM / system
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

create_generated_clock -name CPU_CLK_OUT \
    -source [get_pins {pll1|altpll_component|auto_generated|pll1|clk[0]}] \
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
set_clock_groups -asynchronous \
    -group { pll1|altpll_component|auto_generated|pll1|clk[1] } \
    -group { pll48_1|altpll_component|auto_generated|pll1|clk[0] } \
    -group { CLOCK50 \
             pll1|altpll_component|auto_generated|pll1|clk[0] \
             pll1|altpll_component|auto_generated|pll1|clk[2] \
             pll1|altpll_component|auto_generated|pll1|clk[3] \
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
