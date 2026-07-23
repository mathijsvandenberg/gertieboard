--------------------------------------------------------------------------------
-- cga_status.vhd  --  CGA status register at I/O port 0x3DA
--
-- Real BIOSes and diagnostics (Philips BIOS, Ruud, SuperSoft) detect a CGA card
-- by reading 0x3DA and checking it is NOT 0xFF; they also poll it to wait for
-- display-enable / vertical-retrace. Without it, an IN from 0x3DA falls through
-- to the open-bus 0xFF, the BIOS decides "no CGA," and never writes 0xB8000 ->
-- blank screen. (xtramtest writes 0xB8000 directly, which is why it works.)
--
-- This returns a valid CGA status:
--     bit 0 = display-enable / blanking ('1' during h/v blanking)
--     bit 3 = vertical retrace window
--     bits 1,2,4..7 = 0   -> the byte is NEVER 0xFF, so the card is "detected"
--
-- The counters mirror the VGA scan timing (800 x 525 pixels = 59.5 Hz), so
-- games that pace themselves on bit 3 (Digger etc.) run at the true frame
-- rate.  NOTE this module is clocked from c3 = 50 MHz while vga.vhd scans on
-- c1 = 25 MHz, so the horizontal counts here are in doubled (50 MHz) ticks --
-- see the architecture body.
--
-- The FREQUENCY matches the display, but the PHASE is arbitrary (fixed at
-- power-up) because the two counters free-run independently, so vsync-synced
-- animation may tear at one fixed screen line. Wire vga's VS in here instead
-- if that ever matters.
--
-- We deliberately answer ONLY 0x3DA (CGA), NOT 0x3BA (MDA). 0x3BA still reads
-- 0xFF ("no MDA"), so BIOSes that check both pick CGA and use 0xB8000.
--
-- Wiring (BDF):
--   CLK     <- 25 MHz VGA clock (c1)         (free-running timing source)
--   RD      <- the I/O READ strobe (IOR), active-low -- the read counterpart of
--              the strobe that feeds sevenseg's WR. Must be I/O-only, so a
--              memory read of address 0x003DA does NOT trigger it.
--   ADDR    <- the 16-bit I/O address bus (same one sevenseg/ctrl_reg watch)
--   DATAOUT -> the shared CPU read-data bus (alongside the other peripherals)
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;
USE  IEEE.NUMERIC_STD.ALL;

ENTITY cga_status IS
  PORT(
        CLK     : IN    std_logic;                          -- free-run timing (25 MHz VGA clk)
        RD      : IN    std_logic;                          -- I/O read strobe, active LOW (IOR)
        ADDR    : IN    std_logic_vector(15 DOWNTO 0);
        DATAOUT : INOUT std_logic_vector(7  DOWNTO 0));
END cga_status;

ARCHITECTURE behavior OF cga_status IS
  -- IMPORTANT: this module is clocked from PLL c3 = 50 MHz, which is TWICE the
  -- 25 MHz (c1) pixel clock vga.vhd scans with.  The counters therefore run in
  -- 50 MHz ticks and every horizontal figure is DOUBLED: one 800-pixel line is
  -- 1600 ticks, the 640-pixel active area is 1280 ticks.  Sizing these for
  -- 25 MHz would make the retrace toggle at 119 Hz instead of 59.5 Hz and run
  -- every vsync-paced game at double speed.
  --   50 MHz / (1600 * 525) = 59.52 Hz
  SIGNAL hcnt   : unsigned(10 DOWNTO 0) := (OTHERS => '0');  -- 0..1599 (50 MHz ticks)
  SIGNAL vcnt   : unsigned(9  DOWNTO 0) := (OTHERS => '0');  -- 0..524  (lines)
  SIGNAL status : std_logic_vector(7 DOWNTO 0);
  SIGNAL sel    : std_logic;
BEGIN

  -- Shadow scan counters: same 800 x 525 geometry as vga.vhd, 640 x 400
  -- active area (last 125 lines = vertical blanking, ~4 ms per frame).
  PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      IF (hcnt = 1599) THEN
        hcnt <= (OTHERS => '0');
        IF (vcnt = 524) THEN
          vcnt <= (OTHERS => '0');
        ELSE
          vcnt <= vcnt + 1;
        END IF;
      ELSE
        hcnt <= hcnt + 1;
      END IF;
    END IF;
  END PROCESS;

  status(0)          <= '1' WHEN (hcnt >= 1280 OR vcnt >= 400) ELSE '0'; -- in blanking
  status(2 DOWNTO 1) <= "00";
  status(3)          <= '1' WHEN (vcnt >= 400) ELSE '0';                 -- vertical retrace
  status(7 DOWNTO 4) <= "0000";                                 -- keep it well clear of 0xFF

  sel <= '1' WHEN (RD = '0' AND ADDR = x"03DA") ELSE '0';

  DATAOUT <= status WHEN sel = '1' ELSE "ZZZZZZZZ";

END behavior;
