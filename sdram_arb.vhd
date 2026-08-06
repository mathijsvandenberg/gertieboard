--------------------------------------------------------------------------------
-- sdram_arb.vhd  --  two masters, one SDRAM
--
--   client 0   ega_mem, which is the display and the CPU's path to it
--   client 1   sdram_io, the diagnostic window SDRAMTST drives
--
-- A plain mux would not do. sdram_ctrl requires REQ to be held until ACK, so if
-- the selection could change part way through an access the address would move
-- under a command already issued and both masters would be given the other's
-- answer. So the grant is LATCHED for the whole access and only reconsidered
-- when the controller acknowledges.
--
-- Client 0 wins a tie, because it is the one with a deadline: a late diagnostic
-- read is nothing, a late scanline is on the screen.
--
-- ---------------------------------------------------------------------------
-- LOCK: A TRANSACTION IS NOT ONE ACCESS
--
-- Both clients build a 32-bit pixel out of TWO 16-bit accesses -- planes 1:0
-- then planes 3:2. Granting between them lets the other client in half way
-- through, and a prefetch that reads its low word before a CPU write and its
-- high word after gets a pixel with two planes old and two new. One wrong
-- colour, one pixel group wide, scattered wherever drawing happened to overlap
-- the raster: speckle, and not the kind that looks like a memory fault.
--
-- So a client raises LOCK for the whole pair and the grant is held until it
-- drops. This is not fairness either -- it is atomicity.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;

ENTITY sdram_arb IS
  PORT(
        CLK    : IN  std_logic;
        RESET  : IN  std_logic;

        -- client 0 (priority)
        R0_REQ : IN  std_logic;
        R0_LOCK: IN  std_logic;      -- hold the grant across a whole transaction
        R0_WE  : IN  std_logic;
        R0_A   : IN  std_logic_vector(23 DOWNTO 0);
        R0_D   : IN  std_logic_vector(15 DOWNTO 0);
        R0_BE  : IN  std_logic_vector(1 DOWNTO 0);
        R0_ACK : OUT std_logic;

        -- client 1
        R1_REQ : IN  std_logic;
        R1_LOCK: IN  std_logic;
        R1_WE  : IN  std_logic;
        R1_A   : IN  std_logic_vector(23 DOWNTO 0);
        R1_D   : IN  std_logic_vector(15 DOWNTO 0);
        R1_BE  : IN  std_logic_vector(1 DOWNTO 0);
        R1_ACK : OUT std_logic;

        -- to sdram_ctrl
        S_REQ  : OUT std_logic;
        S_WE   : OUT std_logic;
        S_A    : OUT std_logic_vector(23 DOWNTO 0);
        S_D    : OUT std_logic_vector(15 DOWNTO 0);
        S_BE   : OUT std_logic_vector(1 DOWNTO 0);
        S_ACK  : IN  std_logic);
END sdram_arb;

ARCHITECTURE behavior OF sdram_arb IS
  SIGNAL busy : std_logic := '0';
  SIGNAL sel1 : std_logic := '0';        -- '1' = client 1 holds the grant
BEGIN

  S_REQ <= R1_REQ WHEN (busy = '1' AND sel1 = '1') ELSE
           R0_REQ WHEN  busy = '1'                 ELSE '0';
  S_WE  <= R1_WE  WHEN sel1 = '1' ELSE R0_WE;
  S_A   <= R1_A   WHEN sel1 = '1' ELSE R0_A;
  S_D   <= R1_D   WHEN sel1 = '1' ELSE R0_D;
  S_BE  <= R1_BE  WHEN sel1 = '1' ELSE R0_BE;

  -- The acknowledgement goes only to whoever asked.
  R0_ACK <= S_ACK AND busy AND (NOT sel1);
  R1_ACK <= S_ACK AND busy AND sel1;

  PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      IF RESET = '1' THEN
        busy <= '0';
        sel1 <= '0';
      ELSIF busy = '0' THEN
        IF R0_REQ = '1' THEN
          sel1 <= '0';
          busy <= '1';
        ELSIF R1_REQ = '1' THEN
          sel1 <= '1';
          busy <= '1';
        END IF;
      ELSIF S_ACK = '1' THEN
        -- Reconsider only between TRANSACTIONS, not between accesses.
        IF (sel1 = '0' AND R0_LOCK = '1') OR (sel1 = '1' AND R1_LOCK = '1') THEN
          busy <= '1';                   -- same client keeps it
        ELSE
          busy <= '0';
        END IF;
      END IF;
    END IF;
  END PROCESS;

END behavior;
