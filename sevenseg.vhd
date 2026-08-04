LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;

--------------------------------------------------------------------------------
-- sevenseg.vhd  --  one digit shows a FULL BYTE by time-multiplexing.
--
-- A byte written to I/O port 0x80 is displayed as:
--     high nibble   for T_NIBBLE   (500 ms)
--     low  nibble   for T_NIBBLE   (500 ms)
--     blank (gap)   for T_BLANK    (1 s)
--   then it repeats. So 0x73 shows  "7" ... "3" ......(dark)......  "7" ...
--
-- Whenever a NEW value is written, the cycle restarts from the high nibble, so
-- a POST code that the firmware halts on is shown cleanly from the start and
-- keeps repeating.
--
-- Timing assumes CLK = 10 MHz (c0). The two constants below are raw cycle
-- counts, so they must be rescaled if c0 ever changes again.
--------------------------------------------------------------------------------

ENTITY sevenseg IS
  PORT(
        CLK     : IN  std_logic;
        DATA    : IN  std_logic_vector(7 DOWNTO 0);
        ADDR    : IN  std_logic_vector(15 DOWNTO 0);
        WR      : IN  std_logic;
        SEG_A   : OUT std_logic;
        SEG_B   : OUT std_logic;
        SEG_C   : OUT std_logic;
        SEG_D   : OUT std_logic;
        SEG_E   : OUT std_logic;
        SEG_F   : OUT std_logic;
        SEG_G   : OUT std_logic);
END sevenseg;

ARCHITECTURE behavior OF sevenseg IS

  -- 8.333 MHz: 1 ms = 8333 cycles.
  CONSTANT T_NIBBLE : integer := 8_333_333;            -- 500 ms per nibble
  CONSTANT T_BLANK  : integer := 16_666_666;           -- 1 s blank gap

  CONSTANT P_LO     : integer := T_NIBBLE;             -- low nibble starts here
  CONSTANT P_BLANK  : integer := 2*T_NIBBLE;           -- blank starts here
  CONSTANT P_END    : integer := 2*T_NIBBLE + T_BLANK; -- wrap (full cycle length)

  SIGNAL display_byte : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL phase_cnt    : integer RANGE 0 TO P_END-1 := 0;
  SIGNAL cur_nib      : std_logic_vector(3 DOWNTO 0);
  SIGNAL blank        : std_logic;
  SIGNAL SEG          : std_logic_vector(6 DOWNTO 0);

BEGIN

  ----------------------------------------------------------------------------
  -- Capture the byte written to port 0x80, and run the phase counter.
  -- A changed value restarts the cycle from the high nibble.
  ----------------------------------------------------------------------------
  PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      -- free-running phase counter
      IF phase_cnt = P_END-1 THEN
        phase_cnt <= 0;
      ELSE
        phase_cnt <= phase_cnt + 1;
      END IF;

      -- new byte on port 0x80 -> latch it and restart from the high nibble
      IF (WR = '0' AND ADDR = x"0080" AND DATA /= display_byte) THEN
        display_byte <= DATA;
        phase_cnt    <= 0;
      END IF;
    END IF;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- Which nibble is on screen, and when the digit is dark.
  ----------------------------------------------------------------------------
  cur_nib <= display_byte(7 DOWNTO 4) WHEN phase_cnt < P_LO
        ELSE display_byte(3 DOWNTO 0);
  blank   <= '1' WHEN phase_cnt >= P_BLANK ELSE '0';

  ----------------------------------------------------------------------------
  -- Hex -> active-high 7-seg (same table as before), blanked during the gap.
  ----------------------------------------------------------------------------
  PROCESS (cur_nib, blank)
  BEGIN
    IF blank = '1' THEN
      SEG <= "0000000";                 -- all segments off
    ELSE
      CASE cur_nib IS
        WHEN "0000" => SEG <= "1111110";
        WHEN "0001" => SEG <= "0110000";
        WHEN "0010" => SEG <= "1101101";
        WHEN "0011" => SEG <= "1111001";
        WHEN "0100" => SEG <= "0110011";
        WHEN "0101" => SEG <= "1011011";
        WHEN "0110" => SEG <= "1011111";
        WHEN "0111" => SEG <= "1110000";
        WHEN "1000" => SEG <= "1111111";
        WHEN "1001" => SEG <= "1111011";
        WHEN "1010" => SEG <= "1110111";
        WHEN "1011" => SEG <= "0011111";
        WHEN "1100" => SEG <= "1001110";
        WHEN "1101" => SEG <= "0111101";
        WHEN "1110" => SEG <= "1001111";
        WHEN "1111" => SEG <= "1000111";
        WHEN OTHERS => SEG <= "0000000";
      END CASE;
    END IF;
  END PROCESS;

  SEG_A <= SEG(6);
  SEG_B <= SEG(5);
  SEG_C <= SEG(4);
  SEG_D <= SEG(3);
  SEG_E <= SEG(2);
  SEG_F <= SEG(1);
  SEG_G <= SEG(0);

END;