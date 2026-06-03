#create_clock -name {CLOCK50} -period 20 [get_ports {CLOCK50}]
#create_clock -name {CPU_IOM} -period 100 [get_ports {CPU_IOM}]
#derive_pll_clocks

#set_false_path -from [get_ports {RESET}]
	 
	  
	  
	  
#set_input_delay -clock {[get_clocks *|pll1|clk[0]]}  50 [get_ports {CPU_*}] 


#
#
#create_clock -name {RESET} -period 100 [get_ports {RESET}]
#
#
#
#
#create_clock -name {CPU_RD} -period 50 [get_ports {CPU_RD}]
#create_clock -name {CPU_WR} -period 50 [get_ports {CPU_WR}]
#create_clock -name {CPU_ALE} -period 50 [get_ports {CPU_ALE}]
#create_clock -name {CPU_DTR} -period 50 [get_ports {CPU_DTR}]
#create_clock -name {CPU_DEN} -period 50 [get_ports {CPU_DEN}]
#create_clock -name {CPU_IOM} -period 50 [get_ports {CPU_IOM}]
#create_clock -name {CPU_A} -period 50 [get_ports {CPU_A}]
#create_clock -name {CPU_AD[7..0]} -period 50 [get_ports {CPU_AD[7..0]}]
#
#create_clock -name {UART_RXD} -period 4000 [get_ports {UART_RXD}]



# =============================================================================
# Primary input clock
# =============================================================================
create_clock -name CLOCK50 -period 20.000 [get_ports CLOCK50]

# =============================================================================
# PLL-derived clocks
# Quartus reads the .qip/megafunction parameters and creates the three output
# clocks automatically. After first compile, look in the TimeQuest report under
# "Clocks" to see the exact derived names (typically
# pll1|altpll_component|auto_generated|pll1|clk[0..2] -> 5/25/1.19 MHz).
# =============================================================================
derive_pll_clocks

# =============================================================================
# CPU_CLK output pin (5 MHz from PLL c0, goes off-chip to peripherals)
# =============================================================================
create_generated_clock -name CPU_CLK_OUT \
    -source [get_pins {pll1|altpll_component|auto_generated|pll1|clk[0]}] \
    [get_ports CPU_CLK]

# =============================================================================
# Clock uncertainty (jitter + tool margin). Must come AFTER all clocks defined.
# =============================================================================
derive_clock_uncertainty

# =============================================================================
# Asynchronous clock groups
# The three PLL outputs are at unrelated frequencies. Domain crossings happen
# only in the dual-port framebuffer (handled by the M9K's two ports) and the
# 8253 (designed for an async gate input). Tell TimeQuest not to time paths
# between these groups.
# =============================================================================
set_clock_groups -asynchronous \
    -group { CLOCK50 } \
    -group { pll1|altpll_component|auto_generated|pll1|clk[0] CPU_CLK_OUT } \
    -group { pll1|altpll_component|auto_generated|pll1|clk[1] } \
    -group { pll1|altpll_component|auto_generated|pll1|clk[2] }

# =============================================================================
# VGA output pins — monitor is forgiving, no real setup/hold spec
# =============================================================================
set_false_path -from * -to [get_ports {HS VS RGB[*] DEBUG}]

# =============================================================================
# Optional: if you have an async reset button, mark it false_path
# (uncomment and adjust the port name)
# =============================================================================
# set_false_path -from [get_ports RESET_N] -to *







