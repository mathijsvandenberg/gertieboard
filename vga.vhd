LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;
USE  work.FONT.all;


ENTITY vga IS
  PORT(
        -- Common
        CLK_VGA              : IN std_logic;
		  CLK_CPU				  : IN std_logic;
        RESET                : IN std_logic;
		  WR						  : IN std_logic;
		  RD						  : IN std_logic;
		  ADDR					  : IN std_logic_vector(19 DOWNTO 0);
		  DATAIN					  : IN std_logic_vector(7 DOWNTO 0);
 		  HS                 	  : OUT std_logic;
 		  VS                 	  : OUT std_logic;
 		  RGB               	  : OUT std_logic_vector(5 DOWNTO 0);
		  DATAOUT				  : INOUT std_logic_vector(7 DOWNTO 0);
		  DEBUG 					  : OUT std_logic);
		  	
   END vga;
	
ARCHITECTURE behavior OF vga IS

  --------------------------------------------------------------------------
  -- Standard CGA 4-bit IRGB attribute -> 6-bit RRGGBB display color.
  -- Color 6 is brown (not yellow-green) per the IBM CGA palette.
  --------------------------------------------------------------------------
  FUNCTION cga_to_rgb(c : std_logic_vector(3 DOWNTO 0)) RETURN std_logic_vector IS
  BEGIN
    CASE c IS
      WHEN "0000" => RETURN "000000";  -- 0  Black
      WHEN "0001" => RETURN "000010";  -- 1  Blue
      WHEN "0010" => RETURN "001000";  -- 2  Green
      WHEN "0011" => RETURN "001010";  -- 3  Cyan
      WHEN "0100" => RETURN "100000";  -- 4  Red
      WHEN "0101" => RETURN "100010";  -- 5  Magenta
      WHEN "0110" => RETURN "100100";  -- 6  Brown
      WHEN "0111" => RETURN "101010";  -- 7  Light gray
      WHEN "1000" => RETURN "010101";  -- 8  Dark gray
      WHEN "1001" => RETURN "010111";  -- 9  Light blue
      WHEN "1010" => RETURN "011101";  -- 10 Light green
      WHEN "1011" => RETURN "011111";  -- 11 Light cyan
      WHEN "1100" => RETURN "110101";  -- 12 Light red
      WHEN "1101" => RETURN "110111";  -- 13 Light magenta
      WHEN "1110" => RETURN "111101";  -- 14 Yellow
      WHEN "1111" => RETURN "111111";  -- 15 White
      WHEN OTHERS => RETURN "000000";
    END CASE;
  END FUNCTION;

  SIGNAL X  : std_logic_vector(10 DOWNTO 0);
  SIGNAL Y  : std_logic_vector(10 DOWNTO 0);
  SIGNAL XX : std_logic_vector(10 DOWNTO 0);
  SIGNAL YY : std_logic_vector(10 DOWNTO 0);

  SIGNAL VALID    : std_logic;
  SIGNAL CHAR     : std_logic;
  SIGNAL RGBCHR   : std_logic_vector(5 DOWNTO 0);

  -- VGA-side scan-out registers (one BRAM read each).
  SIGNAL MEMCHR   : std_logic_vector(7 DOWNTO 0);   -- char code for current cell
  SIGNAL MEMATT   : std_logic_vector(7 DOWNTO 0);   -- attribute for current cell
  -- Extra pipeline stage so the attribute lines up in time with CHAR.
  SIGNAL ATTR_REG : std_logic_vector(7 DOWNTO 0);

  -- CPU read-back path.  Both halves are read every cycle; the registered
  -- ADDR(0) selects which one is returned.
  SIGNAL MEMC_DOUT_CPU : std_logic_vector(7 DOWNTO 0);
  SIGNAL MEMA_DOUT_CPU : std_logic_vector(7 DOWNTO 0);
  SIGNAL MEM_DOUT_CPU  : std_logic_vector(7 DOWNTO 0);
  SIGNAL ADDR0_REG     : std_logic;

  -- Split the 4 KB B800 page into two 2 K halves:
  --   MEMC : characters  (even byte offsets, ADDR(0) = '0')
  --   MEMA : attributes  (odd  byte offsets, ADDR(0) = '1')
  TYPE MEMHALF IS ARRAY (0 TO 2047) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL MEMC : MEMHALF;
  SIGNAL MEMA : MEMHALF;

  ATTRIBUTE ramstyle : STRING;
  ATTRIBUTE ramstyle OF MEMC : SIGNAL IS "M9K";
  ATTRIBUTE ramstyle OF MEMA : SIGNAL IS "M9K";

  -- Decoded foreground / background colors.
  SIGNAL fg_color, bg_color : std_logic_vector(3 DOWNTO 0);
  SIGNAL fg_rgb,   bg_rgb   : std_logic_vector(5 DOWNTO 0);

BEGIN

  -- ---------------- CPU side -----------------------------------------
  -- Writes go to MEMC or MEMA depending on the low address bit.
  -- The CPU sees a flat 4 KB page from 0xB8000-0xB8FFF where even
  -- addresses are characters and odd addresses are attributes - exactly
  -- the layout DOS/BIOS expects for color text mode.
  CPU_PORT : PROCESS (CLK_CPU)
  BEGIN
    IF rising_edge(CLK_CPU) THEN
      IF (WR = '0' AND ADDR(19 DOWNTO 12) = x"B8" AND ADDR(0) = '0') THEN
        MEMC(conv_integer(ADDR(11 DOWNTO 1))) <= DATAIN;
      END IF;
      IF (WR = '0' AND ADDR(19 DOWNTO 12) = x"B8" AND ADDR(0) = '1') THEN
        MEMA(conv_integer(ADDR(11 DOWNTO 1))) <= DATAIN;
      END IF;

      -- Registered read of both halves; mux on registered ADDR(0).
      MEMC_DOUT_CPU <= MEMC(conv_integer(ADDR(11 DOWNTO 1)));
      MEMA_DOUT_CPU <= MEMA(conv_integer(ADDR(11 DOWNTO 1)));
      ADDR0_REG     <= ADDR(0);
    END IF;
  END PROCESS;

  MEM_DOUT_CPU <= MEMA_DOUT_CPU WHEN ADDR0_REG = '1' ELSE MEMC_DOUT_CPU;

  -- ---------------- VGA side -----------------------------------------
  -- One cell index = 80 * text_row + text_col.  Both BRAMs are read at
  -- the same index; we no longer need the "* 2" stride because the
  -- attribute lives in a parallel array, not at the next byte offset.
  VGA_PORT : PROCESS (CLK_VGA)
  BEGIN
    IF rising_edge(CLK_VGA) THEN
      MEMCHR <= MEMC(80 * conv_integer(YY(10 DOWNTO 4))
                       + conv_integer(XX(10 DOWNTO 3)));
      MEMATT <= MEMA(80 * conv_integer(YY(10 DOWNTO 4))
                       + conv_integer(XX(10 DOWNTO 3)));
    END IF;
  END PROCESS;

  -- X/Y scan counters (unchanged)
  PROCESS (CLK_VGA)
  BEGIN
    IF (rising_edge(CLK_VGA)) THEN
      IF (X < 799) THEN
        X <= X + 1;
        IF (X > 143 AND X < 784) THEN
          XX <= XX + 1;
        END IF;
      ELSE
        X  <= "00000000000";
        XX <= "00000000000";
        IF (Y < 524) THEN
          Y <= Y + 1;
          IF (Y > 34 AND Y < 515) THEN
            YY <= YY + 1;
          END IF;
        ELSE
          Y  <= "00000000000";
          YY <= "00000000000";
        END IF;
      END IF;
    END IF;
  END PROCESS;

  -- Glyph lookup + attribute pipeline align.
  -- CHAR is registered out of GetChar (1-cycle delay from MEMCHR).
  -- ATTR_REG is delayed one extra cycle from MEMATT so it tracks CHAR.
  PROCESS (CLK_VGA)
  BEGIN
    IF (rising_edge(CLK_VGA)) THEN
      CHAR     <= GetChar(XX(2 DOWNTO 0) - 1, YY(3 DOWNTO 0), MEMCHR(7 DOWNTO 0));
      ATTR_REG <= MEMATT;
    END IF;
  END PROCESS;

  -- HSYNC and VSYNC generation
  HS    <= '0' WHEN X < 96 ELSE '1';
  VS    <= '0' WHEN Y < 2  ELSE '1';
  VALID <= '1' WHEN (X > 144 AND X < 784 AND Y > 34 AND Y < 515) ELSE '0';

  -- ---------------- Color decode -------------------------------------
  -- Attribute byte layout (CGA, 16/16 mode):
  --   bit 7   : background intensity     (bit 7 is BLINK in real CGA's
  --             default mode; we treat it as bg intensity to give a
  --             full 16/16 palette.  Mask to '0' if blink is preferred.)
  --   bits 6:4: background R,G,B
  --   bit 3   : foreground intensity
  --   bits 2:0: foreground R,G,B
  fg_color <= ATTR_REG(3 DOWNTO 0);
  bg_color <= ATTR_REG(7 DOWNTO 4);
  fg_rgb   <= cga_to_rgb(fg_color);
  bg_rgb   <= cga_to_rgb(bg_color);

  RGBCHR <= fg_rgb WHEN (CHAR = '1') ELSE bg_rgb;
  RGB    <= RGBCHR WHEN (VALID = '1') ELSE "000000";

  -- CPU read-back of the text page
  DATAOUT <= MEM_DOUT_CPU
             WHEN (RD = '0' AND ADDR(19 DOWNTO 12) = x"B8")
             ELSE "ZZZZZZZZ";

  DEBUG <= Y(5);

END;