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
-- ---------------------------------------------------------------------------
-- WHERE THE BEAM IS, ASKED RATHER THAN GUESSED
--
-- This module used to carry its own 800 x 525 scan counters, clocked from c3 at
-- 50 MHz while vga.vhd scanned the same geometry from c1 at 25 MHz. Two copies
-- of one fact, and the header here said as much: "the PHASE is arbitrary ...
-- wire vga's VS in here instead if that ever matters."
--
-- It mattered. The copies did not merely drift, they disagreed from the start.
-- This module called lines 400..524 the vertical retrace; vga.vhd draws the
-- picture on lines 35..434. So a program that polled bit 3, saw it set, and
-- concluded it was safe to rewrite the screen was in fact given the last 35
-- visible lines -- 1.1 ms of active display -- before blanking really began.
-- Horizontally the same 35-line offset appeared as 288 ticks of error on bit 0.
--
-- So there are no counters here now. DISPEN and VRET come straight from the
-- counters that actually address the video memory, and the two cannot disagree
-- because there is only one of them.
--
-- We deliberately answer ONLY 0x3DA (CGA), NOT 0x3BA (MDA). 0x3BA still reads
-- 0xFF ("no MDA"), so BIOSes that check both pick CGA and use 0xB8000.
--
-- Wiring (top level):
--   DISPEN  <- vga's DISPEN     '1' while pixels are being drawn
--   VRET    <- vga's VRET       '1' on every non-displayed line
--   RD      <- the I/O READ strobe (IOR), active-low -- the read counterpart of
--              the strobe that feeds sevenseg's WR. Must be I/O-only, so a
--              memory read of address 0x003DA does NOT trigger it.
--   ADDR    <- the 16-bit I/O address bus (same one sevenseg/ctrl_reg watch)
--   DATAOUT -> the shared CPU read-data bus (alongside the other peripherals)
--
-- DISPEN and VRET are generated on c1 and sampled here by an asynchronous CPU
-- read, which is not synchronised and does not need to be: this is a status bit
-- that software polls in a loop. A read that catches the edge returns the value
-- from either side of it, and the next read a microsecond later is unambiguous.
-- That is how the real card behaves too.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;

ENTITY cga_status IS
  PORT(
        DISPEN  : IN    std_logic;                          -- from vga.vhd
        VRET    : IN    std_logic;                          -- from vga.vhd
        RD      : IN    std_logic;                          -- I/O read strobe, active LOW (IOR)
        ADDR    : IN    std_logic_vector(15 DOWNTO 0);
        DATAOUT : INOUT std_logic_vector(7  DOWNTO 0));
END cga_status;

ARCHITECTURE behavior OF cga_status IS
  SIGNAL status : std_logic_vector(7 DOWNTO 0);
  SIGNAL sel    : std_logic;
BEGIN

  status(0)          <= NOT DISPEN;                     -- in blanking
  status(2 DOWNTO 1) <= "00";
  status(3)          <= VRET;                           -- vertical retrace
  status(7 DOWNTO 4) <= "0000";                         -- keep it well clear of 0xFF

  sel <= '1' WHEN (RD = '0' AND ADDR = x"03DA") ELSE '0';

  DATAOUT <= status WHEN sel = '1' ELSE "ZZZZZZZZ";

END behavior;
