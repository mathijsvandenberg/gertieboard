--------------------------------------------------------------------------------
-- m9k_mem.vhd  --  reliable on-chip M9K low RAM for the hybrid map
--
-- Backs ONLY the low 32 KB:
--   0x00000..0x07FFF  -- IVT, BDA, stack, trampoline scratch
-- The BIOS now lives in the PSRAM-backed F-segment (full 64 KB, no mirror), so
-- this block no longer touches 0xF0000+. 32 M9K blocks.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;

ENTITY m9k_mem IS
  PORT(
        CLK_RAM : IN    std_logic;
        RESET   : IN    std_logic;
        DATAIN  : IN    std_logic_vector(7  DOWNTO 0);
        ADDR    : IN    std_logic_vector(19 DOWNTO 0);
        RD      : IN    std_logic;                          -- /MEMR (active LOW)
        WR      : IN    std_logic;                          -- /MEMW (active LOW)
        DATAOUT : INOUT std_logic_vector(7  DOWNTO 0);
        READY   : OUT   std_logic);
END m9k_mem;

ARCHITECTURE m9k OF m9k_mem IS

  CONSTANT DEPTH : integer := 16#8000#;      -- 32 KB low RAM

  TYPE mem_t IS ARRAY(0 TO DEPTH-1) OF std_logic_vector(7 DOWNTO 0);
  SIGNAL mem : mem_t;

  SIGNAL in_win  : std_logic;
  SIGNAL midx    : integer RANGE 0 TO DEPTH-1;
  SIGNAL cpu_rd  : std_logic;
  SIGNAL cpu_wr  : std_logic;
  SIGNAL cpu_op  : std_logic;
  SIGNAL dout    : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL we      : std_logic := '0';

  TYPE st_t IS (M_IDLE, M_WAIT, M_DONE);
  SIGNAL st        : st_t := M_IDLE;
  SIGNAL ready_int : std_logic := '1';

BEGIN

  in_win <= '1' WHEN (ADDR < x"08000") ELSE '0';
  midx   <= conv_integer(ADDR(14 DOWNTO 0));    -- 0x0000..0x7FFF

  cpu_rd <= in_win AND (NOT RD);
  cpu_wr <= in_win AND (NOT WR);
  cpu_op <= cpu_rd OR cpu_wr;

  DATAOUT <= dout WHEN cpu_rd = '1' ELSE "ZZZZZZZZ";
  READY   <= '0'  WHEN (cpu_op = '1' AND st = M_IDLE) ELSE ready_int;

  PROCESS (CLK_RAM)
  BEGIN
    IF rising_edge(CLK_RAM) THEN
      IF (we = '1' AND in_win = '1') THEN
        mem(midx) <= DATAIN;
      END IF;
      dout <= mem(midx);
    END IF;
  END PROCESS;

  PROCESS (CLK_RAM, RESET)
  BEGIN
    IF RESET = '1' THEN
      st <= M_IDLE; ready_int <= '1'; we <= '0';
    ELSIF rising_edge(CLK_RAM) THEN
      we <= '0';
      CASE st IS
        WHEN M_IDLE =>
          ready_int <= '1';
          IF cpu_wr = '1' THEN we <= '1'; ready_int <= '0'; st <= M_WAIT;
          ELSIF cpu_rd = '1' THEN ready_int <= '0'; st <= M_WAIT; END IF;
        WHEN M_WAIT =>
          ready_int <= '1'; st <= M_DONE;
        WHEN M_DONE =>
          ready_int <= '1';
          IF RD = '1' AND WR = '1' THEN st <= M_IDLE; END IF;
      END CASE;
    END IF;
  END PROCESS;

END m9k;
