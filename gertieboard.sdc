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
#     busdecode<->PSRAM paths unanalyzed). ALL of them, including the pixel
#     clock -- it used to be excepted, and the exception cost a day; see the
#     note at the clock groups.
#   * The off-chip V20 bus is a slow, handshake-governed interface (READY
#     controls correctness, not single-cycle setup), so the CPU pins are
#     false-pathed both directions. This is what clears the red WITHOUT any
#     bogus input/output-delay numbers.
#   * Every external memory is constrained: the SDRAM the textbook way (it has
#     a real clock), the PSRAM and flash as bounded pad delays (they do not).
#     Nothing off-chip is unanalysed any more.
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

# CPU_CLK is NO LONGER clk_q. cpuclk re-registers it on the FALLING edge of the
# 100 MHz master, so the pin runs exactly 5 ns behind the internal bus clock --
# deliberate skew, handed straight to READY's aperture. The source here must be
# that register, not clk_q, or the analyser prices the pin at the internal
# clock's edges and the 5 ns simply does not appear in any report.
create_generated_clock -name CPU_CLK_OUT \
    -source [get_pins {cpuclk1|clk_pad|q}] \
    [get_ports CPU_CLK]

derive_clock_uncertainty

# -----------------------------------------------------------------------------
# Clock groups
#   - USB 48 MHz: its own async domain, and the only one. usb_host crosses GO as
#     a toggle through a three-stage synchroniser, samples its command registers
#     only while the engine is idle, and moves packet data through dual-port
#     buffers never accessed from both sides at once -- BUSY enforces that.
#   - everything else, pixel clock included: synchronous, timed together
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
set_false_path -from * -to [get_ports {CPU_RST CPU_NMI CPU_INTR CPU_HLD}]

# -----------------------------------------------------------------------------
# ...EXCEPT THE TWO SIGNALS THE HANDSHAKE CANNOT COVER.
#
# The argument above is right for address and command: the bus cycle is long,
# READY governs it, and a single-edge requirement on those is meaningless. It is
# WRONG for READY and for read data, and the uPD70108 datasheet says why -- both
# are referenced to the CPU's OWN CLOCK EDGES, with requirements no handshake
# can satisfy on their behalf:
#
#     tSRYLK   READY setup to CLK-fall      -8 ns   (may arrive 8 ns AFTER it)
#     tSRYHK   READY setup to CLK-rise      tKKL-8  -- the same instant
#     tHKRYL   READY hold from CLK-rise     20 ns
#     tSDK     read data setup to CLK-fall  20 ns   (-8 part)
#     tHKD     read data hold from CLK-fall 10 ns
#
# READY *IS* the handshake, so it cannot be governed by the handshake. And
# leaving these two false-pathed is not "not constraining them", it is telling
# the fitter they are free -- so it places them differently every build. That is
# the same failure the PSRAM pads had, and it presents the same way: some
# bitstreams boot and run for hours, some do not, the difference survives a
# power cycle, and nothing in any report says which one you have.
#
# MEASURED on the previous fit, launch edge to pin, slow corner:
#
#     CPU_CLK    4.442 ns
#     CPU_RDY   18.441 ns    -- 14.0 ns behind the clock; the part allows 8
#     CPU_AD    22.891 ns
#
# So READY has been arriving late, into the sampling aperture rather than well
# clear of it, and whether a given build lands inside or outside that aperture
# is decided by placement. Hence: works or crashes per build, stable once it
# boots.
#
# THESE BOUNDS ARE DERIVED. READY must be valid 8 ns after CLK-fall AT THE CPU.
#
# The clock does not arrive instantly: it leaves through a pad of its own, and
# the CPU therefore sees CLK-fall that much after the internal edge. That flight
# time is genuinely part of READY's budget -- but it can only be CLAIMED if it
# is guaranteed, so CPU_CLK gets a bounded window of its own below and the
# derivation uses the MINIMUM of that window (earliest possible clock, worst
# case for READY):
#
#     READY  10.35 ns  = 2.5 (CPU_CLK min) + 8.0 (tSRYLK) - 0.15 (board SKEW)
#
# That last term was 0.5 ns at first, which confused flight time with skew. What
# matters is the DIFFERENCE between the clock's trace and READY's, and they go
# to adjacent pins of the same DIP socket a few centimetres away. 0.15 ns is
# about 2.5 cm of length mismatch between them, which is already generous.
#
# The 2.5 ns is DELIBERATE SKEW, not an observation. Holding the CPU's clock
# back hands that time straight to READY, and it costs nothing in the other
# direction: the CPU's own outputs then arrive 3 ns later relative to the
# sampling edge, against a bus period of 60 ns at the fastest step. It also
# widens the read-data budget, which is referenced to the same edge.
#
# Being straight about it: 3.0 ns was asked for first, because it cleared READY.
# The fitter could only guarantee 2.722 on a direct pad path, so the ask came
# down to 2.5 -- what can actually be promised, not what would have been
# convenient. What makes that legitimate rather than moving the goalposts is that
# tSRYLK is untouched -- the part still gets its 8 ns -- and the clock is now
# GUARANTEED not to arrive before 3.0 ns rather than merely observed not to.
# Claiming the measured 4.442 ns without constraining it would have been the
# real mistake: the fitter is free to make the clock faster, and the first build
# that did would have broken READY silently.
#
# Read data is launched at least one bus period before the edge that samples it
# -- READY is what releases the cycle -- so its budget is a period plus the
# clock's arrival less tSDK. At the fastest step (60 ns) that is 60 - 20 = 40,
# again claiming nothing for the clock's pad delay, less the same board skew:
#
#     DATA   39.5 ns   = 60.0 (period) - 20.0 (tSDK) - 0.5 (board, kept
#                        conservative here: this one has 29 ns of slack anyway)
#
# If a later edit makes either of these fail, the answer is to shorten the path
# -- READY is combinational out of RAM_READY today -- not to raise the number.
# Raising it rebuilds the lottery somewhere else.
# -----------------------------------------------------------------------------
# The clock's own flight time, pinned at both ends. The window is what makes the
# 2.0 ns above claimable; the upper end keeps the clock from drifting so late
# that it eats into the data budget from the other side.
# RE-DERIVED 2026-08-16. This was 2.500, and that number was load-bearing: it
# was the ONLY thing holding the CPU's clock back, so READY's budget was built
# on it and the fitter could only just supply it (2.722 ns on a direct pad path
# was the most it would promise, which is why the ask came down to 2.500 in the
# first place). Under a percent of margin on a hand-placed pad delay is not a
# guarantee, and the hardware proved it: a finger on CPU_CLK was the difference
# between booting and not.
#
# The skew now comes from cpuclk instead, which re-registers the bus clock on
# the FALLING edge of the 100 MHz master. That is 5.000 ns exactly, at every
# speed step and every corner, because it is a clock edge and not a wire.
#
# So this bound no longer has to buy anything -- it only keeps the pad honest,
# and it is lowered to what the I/O-cell register actually delivers (2.071 ns
# at the fast corner). FAST_OUTPUT_REGISTER puts that flop in the IOE, so the
# path is the pad and nothing else and does not wander between builds.
#
#     READY budget = 5.000 (fabric skew) + 1.500 (pad min)
#                  + 8.000 (tSRYLK)      - 0.150 (board)   = 14.35 ns
#
# CPU_RDY stays constrained at 10.350 rather than being relaxed to that. The
# extra 4 ns is deliberate margin against the one number here that is NOT
# trustworthy: tSRYLK is the datasheet's, specified at 4.5-5.5 V, and this part
# runs at 3.33 V. Undervolted CMOS is slower by an amount no datasheet states,
# so the allowance is smaller than 8 ns by an unknown margin. Spending the
# fabric skew on that unknown instead of banking it is the whole point.
set_min_delay -to [get_ports {CPU_CLK}]    1.500
set_max_delay -to [get_ports {CPU_CLK}]    6.000

set_max_delay -to [get_ports {CPU_RDY}]   10.350
set_max_delay -to [get_ports {CPU_AD[*]}] 39.500

# The 8237's address and the DMA page register reach CPU_RDY only through the
# MEM_ADDR mux, and that mux selects them only while HLDA is asserted -- which
# is exactly when the CPU is OFF THE BUS and sampling nothing. They are real
# wires but they cannot carry a real requirement, and leaving them in was
# costing the analysis its worst path for a cycle the CPU is not part of.
set_false_path -from [get_registers {*dma8237*|DMA_ADDR[*]}] -to [get_ports {CPU_RDY}]
set_false_path -from [get_registers {*busdecode*|dma_page[*]}] -to [get_ports {CPU_RDY}]

# -----------------------------------------------------------------------------
# VGA outputs, debug header and reset
#
# The monitor re-syncs on every frame and the DBG pins only feed a logic
# analyser, so neither has a meaningful setup/hold requirement on-chip.
# -----------------------------------------------------------------------------
set_false_path -from * -to [get_ports {VGA_HS VGA_VS VGA_RGB[*] DBG[*]}]
set_false_path -from [get_ports RESET] -to *

# -----------------------------------------------------------------------------
# SDRAM -- ISSI IS42S16160B-7, 32 MB, on the DE0-Nano's dedicated pins.
#
# A REAL synchronous interface, and the only external one here that is: the part
# has a free-running clock and both directions are referenced to it. So it is
# constrained the textbook way, with the device's own numbers.
#
# DRAM_CLK is the INVERTED controller clock (see the note in sdram_ctrl.vhd), so
# the part latches on its rising edge while this design changes its outputs on
# ours -- half a clock of setup and half of hold, with no PLL phase tap. That is
# why the generated clock below is declared -invert: it is not cosmetic, it is
# what tells the analyser that the launch and latch edges are 10 ns apart rather
# than coincident. Declared without it, every path here would be analysed at a
# 0 ns requirement and the interface would look catastrophically broken.
#
# Numbers are the -7 grade at CAS latency 2, which is what sdram_ctrl programs:
#
#   tAC  6.0 ns   access time from CLK        -> set_input_delay  -max
#   tOH  2.5 ns   output data hold from CLK   -> set_input_delay  -min
#   tSU  1.5 ns   input setup to CLK          -> set_output_delay -max
#   tHD  0.8 ns   input hold from CLK         -> set_output_delay -min
#
# plus ~0.2 ns for the board, which is short and on-module. If the part is ever
# swapped for a different speed grade these four numbers are the only thing that
# changes -- they are the datasheet, not a tuning knob.
#
# THE READ CAPTURE IS NOW THE WORST PATH IN THE DESIGN, at +0.26 ns, and that is
# a better place for it to be than where it was. The 10 ns half-cycle is spent:
#
#     2.45 ns  DRAM_CLK through the output cell to the pin
#     6.20 ns  tAC + board -- the part, before the data even starts back
#     0.73 ns  input buffer
#     0.94 ns  pad to rd_reg, the ONLY part of it that is routing
#
# Nearly all of that is silicon and datasheet, which is why the number no longer
# moves: the same netlist closes at +0.260, +0.260, +0.260 and +0.258 across four
# fitter seeds. Before the interfaces were constrained the worst path was inside
# the fabric and the same four seeds gave -0.040 .. +0.327 -- a design whose
# correctness was decided by placement. A critical path made of physics is one
# that behaves the same on every build, and that is worth more than a larger
# number that wanders.
#
# To buy margin here, in order of cost: CAS latency 3 (tAC 6.0 -> 5.4, one extra
# clock per read, and the capture cycle count in sdram_ctrl must move with it);
# or capture on a phase-shifted PLL tap (c4 exists and is unused). Do not reach
# for either until something needs it -- +0.26 ns is met at slow/85C, which is
# the corner that matters.
# -----------------------------------------------------------------------------
create_generated_clock -name DRAM_CLK_PIN \
    -source [get_pins {pll1|altpll_component|auto_generated|pll1|clk[3]}] \
    -invert \
    [get_ports DRAM_CLK]

set sdram_out [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_DQM[*] \
                          DRAM_CS_N DRAM_RAS_N DRAM_CAS_N DRAM_WE_N DRAM_DQ[*]}]

set_output_delay -clock DRAM_CLK_PIN -max  1.7 $sdram_out
set_output_delay -clock DRAM_CLK_PIN -min -0.8 $sdram_out

set_input_delay  -clock DRAM_CLK_PIN -max  6.2 [get_ports {DRAM_DQ[*]}]
set_input_delay  -clock DRAM_CLK_PIN -min  2.5 [get_ports {DRAM_DQ[*]}]

# The clock pin itself has no setup requirement to satisfy against itself.
set_false_path -from * -to [get_ports DRAM_CLK]

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

# -----------------------------------------------------------------------------
# PSRAM (ESP-PSRAM64H, QPI) and serial FLASH (ISSI IS25LP016D)
#
# NOT the same kind of interface as the SDRAM above, and constraining them as if
# they were would be wrong. Neither part has a free-running clock: the FPGA
# generates SCK from a state machine AND samples the returning data on its own
# c3, so there is no external clock domain and no launch/latch edge pair for the
# analyser to reason about. A create_generated_clock on RAM_SCK would also be a
# lie -- SCK_DIV is runtime-tunable through I/O 0xE4, so that "clock" changes
# rate while the machine is running.
#
# What the hardware actually requires is a ROUND TRIP inside one SCK half-period:
#
#     SCK edge out  ->  device access  ->  data back  ->  captured on c3
#
# At the default SCK_DIV = 2 that budget is 40 ns; at the fastest setting the
# design allows, 20 ns. The device's share is small and fixed -- ESP-PSRAM64H
# tCHQV = 6 ns, IS25LP016D tV = 6 ns, plus a few hundred ps of board -- so the
# whole of the rest belongs to the FPGA's own pad paths.
#
# And the FPGA's share is precisely what was varying between builds. It is not
# tight; it was simply UNBOUNDED, so the fitter placed it differently every time
# and nothing anywhere would say what it had chosen.
#
# THESE BOUNDS ARE DERIVED, NOT CHOSEN. At the default SCK_DIV = 2:
#
#     out    14.0 ns   FPGA clock edge -> RAM_SCK/RAM_SIO at the pin
#     dev     6.0 ns   ESP-PSRAM64H tCHQV (IS25LP016D tV is the same 6 ns)
#     in      8.0 ns   RAM_SIO at the pin -> captured on c3
#     ----   -----
#            28.0 ns   of the 40 available -- 12 ns spare
#
# The out bound was 8 ns first, for no better reason than that it was a round
# number above the measurement of the day. Adding the PLL lock signal moved the
# placement, the same path came out at 8.16, and the build failed on a ceiling
# that was never the requirement. Picking a bound because today's number fits
# under it rebuilds the lottery in a new place: the next edit moves the number
# and the build fails for a reason that is not a real one.
#
# SCK_DIV = 1 IS NOT COVERED BY THIS and must not become the default. Its budget
# is 20 ns and 14 + 6 + 8 does not fit; it squeaks through today only because
# the measured numbers are better than the bounds. tCEM caps the other end at
# SCK_DIV <= 2 for a 16-byte burst in any case, so 40 ns is the figure that
# matters and 0x02 is the setting to keep.
#
# If the PSRAM is ever pushed faster, tighten these first, and the phase-shifted
# read capture (c4 exists and is unused) is the step after that.
# -----------------------------------------------------------------------------
set psram_out [get_ports {RAM_SCK RAM_CS RAM_SIO[*]}]
set flash_out [get_ports {FL_SCK FL_CS FL_MOSI}]

set_max_delay -to $psram_out 14.000
set_max_delay -to $flash_out 14.000

set_max_delay -from [get_ports {RAM_SIO[*]}] 8.000
set_max_delay -from [get_ports {FL_MISO}]    8.000
