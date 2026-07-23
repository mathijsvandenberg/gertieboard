--------------------------------------------------------------------------------
-- com1_stub.vhd  --  just enough fake COM1 (0x3F8..0x3FF) to not hang
--
-- Ruud's Diagnostic ROM, very early (step 3 sends checkpoint 0x33, step 4 then
-- talks to a serial port at 0x3F8 if one "exists"), emits its checkpoints to
-- COM1. With no UART, those ports fall through to the open-bus 0xFF -- and a
-- Line Status Register (0x3FD) reading 0xFF says BOTH "transmitter ready" (bit5)
-- AND "receive data available" (bit0) AND all error bits. Ruud's serial routine
-- then loops forever draining a receive buffer that is permanently "full", and
-- the machine sits at checkpoint 0x33.
--
-- This stub answers the COM1 register block with an *idle* UART status:
--   0x3FD (LSR) -> 0x60   THRE (bit5) + TEMT (bit6) set  => transmitter ready
--                         DR (bit0) clear                => no receive data
--                         error bits clear               => nothing to react to
--   other COM1 regs -> 0x00, so a UART-presence probe (scratch-register or
--                      loopback/MSR test) sees a mismatch and concludes "absent",
--                      and Ruud simply skips COM1 output altogether.
--
-- Net effect: Ruud either skips COM1 (most likely) or "transmits" into the void
-- without ever blocking, and execution flows past 0x33 into the real tests.
--
-- This does NOT implement a working UART -- there is no real serial output. It
-- only prevents the diagnostic from wedging on a non-existent one. (Same idea,
-- and same wiring, as cga_status: it just satisfies a probe.)
--
-- Wiring (BDF), identical pattern to cga_status:
--   RD      <- the I/O READ strobe (IOR), active-low (I/O-only)
--   ADDR    <- the 16-bit I/O address bus
--   DATAOUT -> the shared CPU read-data bus
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;

ENTITY com1_stub IS
  PORT(
        RD      : IN    std_logic;                          -- I/O read strobe, active LOW (IOR)
        ADDR    : IN    std_logic_vector(15 DOWNTO 0);
        DATAOUT : INOUT std_logic_vector(7  DOWNTO 0));
END com1_stub;

ARCHITECTURE behavior OF com1_stub IS
  SIGNAL sel_lsr : std_logic;   -- 0x3FD line status register
  SIGNAL sel_com : std_logic;   -- rest of the 0x3F8..0x3FF block
BEGIN

  sel_lsr <= '1' WHEN (RD = '0' AND ADDR = x"03FD") ELSE '0';
  sel_com <= '1' WHEN (RD = '0' AND ADDR >= x"03F8" AND ADDR <= x"03FF"
                                AND ADDR /= x"03FD") ELSE '0';

  DATAOUT <= x"60"       WHEN sel_lsr = '1' ELSE   -- idle UART: TX ready, no RX, no errors
             x"00"       WHEN sel_com = '1' ELSE   -- presence probe -> "absent"
             "ZZZZZZZZ";

END behavior;