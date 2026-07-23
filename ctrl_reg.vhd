--------------------------------------------------------------------------------
-- ctrl_reg.vhd  --  writable I/O register at port 0xE4 -> PSRAM CTRL
--
-- OUT 0xE4, AL  latches AL and presents it on CTRL(7:0), which feeds
-- mem_hybrid/psram_ctrl:
--     CTRL(2:0) = SCK_DIV (1..7; 0 treated as 1)
--     CTRL(6:3) = RD_LAT  (0..15)
--     CTRL(7)   = reserved
--
-- Same I/O-write interface as sevenseg.vhd: it watches the address bus and the
-- (active-low) write strobe. Wire CLK/DATA/ADDR/WR to the SAME nets that feed
-- sevenseg, and connect CTRL to mem_hybrid.CTRL.
--
-- Power-on default = 0x02  (SCK_DIV=2 -> ~12.5 MHz SCK, RD_LAT=0): the value the
-- on-screen finder locked in (all pages pass). The CPU can still re-tune live via
-- OUT 0xE4 if you want to push SCK faster later.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;

ENTITY ctrl_reg IS
  PORT(
        CLK  : IN  std_logic;
        DATA : IN  std_logic_vector(7 DOWNTO 0);
        ADDR : IN  std_logic_vector(15 DOWNTO 0);
        WR   : IN  std_logic;                       -- active-low I/O write strobe
        CTRL : OUT std_logic_vector(7 DOWNTO 0));
END ctrl_reg;

ARCHITECTURE behavior OF ctrl_reg IS
  SIGNAL ctrl_q : std_logic_vector(7 DOWNTO 0) := x"02";
BEGIN
  PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      IF (WR = '0' AND ADDR = x"00E4") THEN
        ctrl_q <= DATA;
      END IF;
    END IF;
  END PROCESS;

  CTRL <= ctrl_q;
END behavior;