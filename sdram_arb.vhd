--------------------------------------------------------------------------------
-- sdram_arb.vhd  --  three masters, one SDRAM
--
--   client 0   ega_mem, the display prefetch and the CPU's path to EGA memory
--   client 2   the CPU's conventional memory
--   client 1   sdram_io, the diagnostic window SDRAMTST drives
--
-- A plain mux would not do. sdram_ctrl requires REQ to be held until ACK, so if
-- the selection could change part way through an access the address would move
-- under a command already issued and both masters would be given the other's
-- answer. So the grant is LATCHED for the whole access and only reconsidered
-- when the controller acknowledges.
--
-- ---------------------------------------------------------------------------
-- PRIORITY, AND WHY IT IS IN THIS ORDER
--
-- It is not fairness. Each client is ranked by what a late answer costs:
--
--   0  the display     a late scanline is ON THE SCREEN. The prefetch has one
--                      row time to fetch a row and cannot be told to wait.
--   2  the CPU         a late answer is a slower machine. busdecode holds READY
--                      and the processor simply stalls -- correct, just slower.
--   1  the diagnostic  nothing waits on it but a test program, deliberately run.
--
-- The display cannot starve the CPU: a row fetch is ~17.6 us of every 63.5, so
-- roughly seventy per cent of the memory is idle from the display's point of
-- view, and the CPU is served in every gap between columns. Nor can the CPU
-- starve the diagnostic window, because an 8088 bus cycle leaves gaps an order
-- of magnitude larger than one SDRAM access.
--
-- ---------------------------------------------------------------------------
-- LOCK: A TRANSACTION IS NOT ONE ACCESS
--
-- Clients build a wider datum out of SEVERAL 16-bit accesses -- ega_mem takes
-- two, planes 1:0 then planes 3:2. Granting between them lets another client in
-- half way through, and a prefetch that reads its low word before a CPU write
-- and its high word after gets a pixel with two planes old and two new. One
-- wrong colour, one pixel group wide, scattered wherever drawing happened to
-- overlap the raster: speckle, and not the kind that looks like a memory fault.
--
-- So a client raises LOCK for the whole transaction and the grant is held until
-- it drops. This is not fairness either -- it is atomicity.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;

ENTITY sdram_arb IS
  PORT(
        CLK    : IN  std_logic;
        RESET  : IN  std_logic;

        -- client 0 (highest priority: the display)
        R0_REQ : IN  std_logic;
        R0_LOCK: IN  std_logic;      -- hold the grant across a whole transaction
        R0_WE  : IN  std_logic;
        R0_A   : IN  std_logic_vector(23 DOWNTO 0);
        R0_D   : IN  std_logic_vector(15 DOWNTO 0);
        R0_BE  : IN  std_logic_vector(1 DOWNTO 0);
        R0_ACK : OUT std_logic;

        -- client 1 (lowest priority: the diagnostic window)
        R1_REQ : IN  std_logic;
        R1_LOCK: IN  std_logic;
        R1_WE  : IN  std_logic;
        R1_A   : IN  std_logic_vector(23 DOWNTO 0);
        R1_D   : IN  std_logic_vector(15 DOWNTO 0);
        R1_BE  : IN  std_logic_vector(1 DOWNTO 0);
        R1_ACK : OUT std_logic;

        -- client 2 (the CPU's conventional memory). Tie REQ low and it is as if
        -- this port were not here -- which is exactly how it is wired until the
        -- SDRAM-backed memory that uses it exists.
        R2_REQ : IN  std_logic;
        R2_LOCK: IN  std_logic;
        R2_WE  : IN  std_logic;
        R2_A   : IN  std_logic_vector(23 DOWNTO 0);
        R2_D   : IN  std_logic_vector(15 DOWNTO 0);
        R2_BE  : IN  std_logic_vector(1 DOWNTO 0);
        R2_ACK : OUT std_logic;

        -- to sdram_ctrl
        S_REQ  : OUT std_logic;
        S_WE   : OUT std_logic;
        S_A    : OUT std_logic_vector(23 DOWNTO 0);
        S_D    : OUT std_logic_vector(15 DOWNTO 0);
        S_BE   : OUT std_logic_vector(1 DOWNTO 0);
        S_ACK  : IN  std_logic);
END sdram_arb;

ARCHITECTURE behavior OF sdram_arb IS
  -- Who holds the grant. Named rather than encoded: this used to be a single
  -- "sel1" bit, which said which of two clients had it and could not be
  -- extended without every expression in the file having to be re-read.
  TYPE owner_t IS (OWN_R0, OWN_R1, OWN_R2);
  SIGNAL owner : owner_t := OWN_R0;
  SIGNAL busy  : std_logic := '0';
BEGIN

  -- REQ is gated by busy so the controller never sees a request before the
  -- grant that goes with it; the rest follow the owner unconditionally, because
  -- they are only sampled while REQ is high.
  S_REQ <= '0'     WHEN busy = '0'      ELSE
           R0_REQ  WHEN owner = OWN_R0  ELSE
           R2_REQ  WHEN owner = OWN_R2  ELSE
           R1_REQ;

  S_WE  <= R0_WE   WHEN owner = OWN_R0 ELSE R2_WE  WHEN owner = OWN_R2 ELSE R1_WE;
  S_A   <= R0_A    WHEN owner = OWN_R0 ELSE R2_A   WHEN owner = OWN_R2 ELSE R1_A;
  S_D   <= R0_D    WHEN owner = OWN_R0 ELSE R2_D   WHEN owner = OWN_R2 ELSE R1_D;
  S_BE  <= R0_BE   WHEN owner = OWN_R0 ELSE R2_BE  WHEN owner = OWN_R2 ELSE R1_BE;

  -- The acknowledgement goes only to whoever asked.
  R0_ACK <= S_ACK WHEN (busy = '1' AND owner = OWN_R0) ELSE '0';
  R1_ACK <= S_ACK WHEN (busy = '1' AND owner = OWN_R1) ELSE '0';
  R2_ACK <= S_ACK WHEN (busy = '1' AND owner = OWN_R2) ELSE '0';

  PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      IF RESET = '1' THEN
        busy  <= '0';
        owner <= OWN_R0;
      ELSIF busy = '0' THEN
        -- Strict priority, in the order argued at the top of this file.
        IF R0_REQ = '1' THEN
          owner <= OWN_R0; busy <= '1';
        ELSIF R2_REQ = '1' THEN
          owner <= OWN_R2; busy <= '1';
        ELSIF R1_REQ = '1' THEN
          owner <= OWN_R1; busy <= '1';
        END IF;
      ELSIF S_ACK = '1' THEN
        -- Reconsider only between TRANSACTIONS, not between accesses.
        IF (owner = OWN_R0 AND R0_LOCK = '1') OR
           (owner = OWN_R1 AND R1_LOCK = '1') OR
           (owner = OWN_R2 AND R2_LOCK = '1') THEN
          busy <= '1';                   -- same client keeps it
        ELSE
          busy <= '0';
        END IF;
      END IF;
    END IF;
  END PROCESS;

END behavior;
