--------------------------------------------------------------------------------
-- pll48.vhd  --  50 MHz -> 48 MHz for the USB host controller
--
-- USB full speed is 12 Mbps, and a soft SIE needs to oversample it. 4x is the
-- usual choice: fast enough to resynchronise on every transition, slow enough
-- that the logic closes timing easily. 4 x 12 = 48 MHz.
--
--   50 MHz x 24 / 25 = 48 MHz exactly
--
-- No fractional accumulator, no accumulated phase error over a 1023-bit packet.
-- The alternatives were worse: 50 MHz direct gives 4.1667 samples per bit and
-- needs a fractional DPLL, and 24 MHz (2x) leaves nowhere to sample.
--
-- This is a SECOND PLL rather than another output on pll1. All of pll1's
-- outputs use multiply_by => 1, so they share a VCO that is a plain multiple of
-- 50 MHz; adding a 24/25 output would force a different VCO for the whole
-- block, and 5 MHz / 25 MHz / 1.19 MHz / 50 MHz would all have to be re-derived
-- from it. Not worth disturbing four working clock domains. The device has four
-- PLLs and used one.
--
-- It replaces the dead `pll2` instance that the schematic conversion left in the
-- top level with all outputs OPEN.
--
-- inclk0_input_frequency is a PERIOD IN PICOSECONDS, not a frequency.
-- 20000 ps = 20 ns = 50 MHz. Misreading this field once produced a confident and
-- completely wrong conclusion about the 8253's clock -- see docs/gotchas.md.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY altera_mf;
USE altera_mf.all;

ENTITY pll48 IS
  PORT (
    inclk0 : IN  std_logic := '0';
    c0     : OUT std_logic;         -- 48 MHz
    locked : OUT std_logic
  );
END pll48;

ARCHITECTURE SYN OF pll48 IS

  SIGNAL sub_wire0 : std_logic_vector(4 DOWNTO 0);
  SIGNAL sub_wire1 : std_logic;
  SIGNAL sub_wire2 : std_logic;
  SIGNAL sub_wire3 : std_logic_vector(1 DOWNTO 0);

  COMPONENT altpll
    GENERIC (
      bandwidth_type          : STRING;
      clk0_divide_by          : NATURAL;
      clk0_duty_cycle         : NATURAL;
      clk0_multiply_by        : NATURAL;
      clk0_phase_shift        : STRING;
      compensate_clock        : STRING;
      inclk0_input_frequency  : NATURAL;
      intended_device_family  : STRING;
      lpm_hint                : STRING;
      lpm_type                : STRING;
      operation_mode          : STRING;
      pll_type                : STRING;
      port_activeclock        : STRING;
      port_areset             : STRING;
      port_clkbad0            : STRING;
      port_clkbad1            : STRING;
      port_clkloss            : STRING;
      port_clkswitch          : STRING;
      port_configupdate       : STRING;
      port_fbin               : STRING;
      port_inclk0             : STRING;
      port_inclk1             : STRING;
      port_locked             : STRING;
      port_pfdena             : STRING;
      port_phasecounterselect : STRING;
      port_phasedone          : STRING;
      port_phasestep          : STRING;
      port_phaseupdown        : STRING;
      port_pllena             : STRING;
      port_scanaclr           : STRING;
      port_scanclk            : STRING;
      port_scanclkena         : STRING;
      port_scandata           : STRING;
      port_scandataout        : STRING;
      port_scandone           : STRING;
      port_scanread           : STRING;
      port_scanwrite          : STRING;
      port_clk0               : STRING;
      port_clk1               : STRING;
      port_clk2               : STRING;
      port_clk3               : STRING;
      port_clk4               : STRING;
      port_clk5               : STRING;
      port_clkena0            : STRING;
      port_clkena1            : STRING;
      port_clkena2            : STRING;
      port_clkena3            : STRING;
      port_clkena4            : STRING;
      port_clkena5            : STRING;
      port_extclk0            : STRING;
      port_extclk1            : STRING;
      port_extclk2            : STRING;
      port_extclk3            : STRING;
      width_clock             : NATURAL
    );
    PORT (
      inclk  : IN  std_logic_vector(1 DOWNTO 0);
      clk    : OUT std_logic_vector(4 DOWNTO 0);
      locked : OUT std_logic
    );
  END COMPONENT;

BEGIN

  sub_wire1 <= sub_wire0(0);
  c0        <= sub_wire1;
  locked    <= sub_wire2;
  sub_wire3 <= '0' & inclk0;

  altpll_component : altpll
    GENERIC MAP (
      bandwidth_type          => "AUTO",
      clk0_divide_by          => 25,
      clk0_duty_cycle         => 50,
      clk0_multiply_by        => 24,      -- 50 * 24 / 25 = 48 MHz
      clk0_phase_shift        => "0",
      compensate_clock        => "CLK0",
      inclk0_input_frequency  => 20000,   -- picoseconds: 20 ns = 50 MHz
      intended_device_family  => "Cyclone IV E",
      lpm_hint                => "CBX_MODULE_PREFIX=pll48",
      lpm_type                => "altpll",
      operation_mode          => "NORMAL",
      pll_type                => "AUTO",
      port_activeclock        => "PORT_UNUSED",
      port_areset             => "PORT_UNUSED",
      port_clkbad0            => "PORT_UNUSED",
      port_clkbad1            => "PORT_UNUSED",
      port_clkloss            => "PORT_UNUSED",
      port_clkswitch          => "PORT_UNUSED",
      port_configupdate       => "PORT_UNUSED",
      port_fbin               => "PORT_UNUSED",
      port_inclk0             => "PORT_USED",
      port_inclk1             => "PORT_UNUSED",
      port_locked             => "PORT_USED",
      port_pfdena             => "PORT_UNUSED",
      port_phasecounterselect => "PORT_UNUSED",
      port_phasedone          => "PORT_UNUSED",
      port_phasestep          => "PORT_UNUSED",
      port_phaseupdown        => "PORT_UNUSED",
      port_pllena             => "PORT_UNUSED",
      port_scanaclr           => "PORT_UNUSED",
      port_scanclk            => "PORT_UNUSED",
      port_scanclkena         => "PORT_UNUSED",
      port_scandata           => "PORT_UNUSED",
      port_scandataout        => "PORT_UNUSED",
      port_scandone           => "PORT_UNUSED",
      port_scanread           => "PORT_UNUSED",
      port_scanwrite          => "PORT_UNUSED",
      port_clk0               => "PORT_USED",
      port_clk1               => "PORT_UNUSED",
      port_clk2               => "PORT_UNUSED",
      port_clk3               => "PORT_UNUSED",
      port_clk4               => "PORT_UNUSED",
      port_clk5               => "PORT_UNUSED",
      port_clkena0            => "PORT_UNUSED",
      port_clkena1            => "PORT_UNUSED",
      port_clkena2            => "PORT_UNUSED",
      port_clkena3            => "PORT_UNUSED",
      port_clkena4            => "PORT_UNUSED",
      port_clkena5            => "PORT_UNUSED",
      port_extclk0            => "PORT_UNUSED",
      port_extclk1            => "PORT_UNUSED",
      port_extclk2            => "PORT_UNUSED",
      port_extclk3            => "PORT_UNUSED",
      width_clock             => 5
    )
    PORT MAP (
      inclk  => sub_wire3,
      clk    => sub_wire0,
      locked => sub_wire2
    );

END SYN;
