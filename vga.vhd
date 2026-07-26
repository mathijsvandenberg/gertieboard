LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;
USE  work.FONT.all;

--------------------------------------------------------------------------------
-- vga.vhd  --  CGA-compatible display adapter
--
-- Text mode (80x25, 16/16 colors) as before, plus CGA graphics modes:
--     mode 4/5 : 320x200, 4 colors, 2 bpp   (each CGA pixel doubled 2x2)
--     mode 6   : 640x200, 2 colors, 1 bpp   (doubled vertically only)
-- The 640x400 active area is exactly 2x 320x200, so no timing changes.
--
-- Video RAM is now the full CGA 16 KB at 0xB8000-0xBBFFF with the classic
-- interleave: even scanlines at +0x0000, odd scanlines at +0x2000, 80 bytes
-- per scanline. Text mode still uses the first 4 KB as before.
--
-- Mode selection is via the standard CGA I/O registers, latched from the I/O
-- bus (new IOWR / IOADDR ports -- wire to the same IO_WR / IO_ADDR nets that
-- feed sevenseg and ctrl_reg):
--     0x3D8  mode control : bit 1 = graphics, bit 2 = b/w (mode-5 palette),
--                           bit 3 = video enable, bit 4 = 640x200 1 bpp
--     0x3D9  color select : bits 3:0 = background/border color (fg in mode 6),
--                           bit 4 = intensity, bit 5 = palette
--                           (0 = green/red/brown, 1 = cyan/magenta/white)
-- 6845 CRTC accesses (0x3D4/5) are ignored -- timing is fixed in hardware.
--------------------------------------------------------------------------------

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
		  IOWR					  : IN std_logic;                       -- I/O write strobe (active low)
		  IOADDR				  : IN std_logic_vector(15 DOWNTO 0);  -- latched I/O address
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
  SIGNAL MEMCHR   : std_logic_vector(7 DOWNTO 0);   -- char code / even VRAM byte
  SIGNAL MEMATT   : std_logic_vector(7 DOWNTO 0);   -- attribute / odd VRAM byte
  -- Extra pipeline stage so the attribute lines up in time with CHAR.
  SIGNAL ATTR_REG : std_logic_vector(7 DOWNTO 0);

  -- CPU read-back path.  Both halves are read every cycle; the registered
  -- ADDR(0) selects which one is returned.
  SIGNAL MEMC_DOUT_CPU : std_logic_vector(7 DOWNTO 0);
  SIGNAL MEMA_DOUT_CPU : std_logic_vector(7 DOWNTO 0);
  SIGNAL MEM_DOUT_CPU  : std_logic_vector(7 DOWNTO 0);
  SIGNAL ADDR0_REG     : std_logic;

  -- Split the 16 KB VRAM (0xB8000-0xBBFFF) into two 8 K halves:
  --   MEMC : even byte offsets (ADDR(0) = '0') -- text: characters
  --   MEMA : odd  byte offsets (ADDR(0) = '1') -- text: attributes
  TYPE MEMHALF IS ARRAY (0 TO 8191) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL MEMC : MEMHALF;
  SIGNAL MEMA : MEMHALF;

  ATTRIBUTE ramstyle : STRING;
  ATTRIBUTE ramstyle OF MEMC : SIGNAL IS "M9K";
  ATTRIBUTE ramstyle OF MEMA : SIGNAL IS "M9K";

  -- Decoded foreground / background colors (text mode).
  SIGNAL fg_color, bg_color : std_logic_vector(3 DOWNTO 0);
  SIGNAL fg_rgb,   bg_rgb   : std_logic_vector(5 DOWNTO 0);

  -- CGA control registers.
  SIGNAL mode_q : std_logic_vector(7 DOWNTO 0) := x"29";  -- 0x3D8: text, enabled
  SIGNAL pal_q  : std_logic_vector(7 DOWNTO 0) := x"20";  -- 0x3D9: palette 1
  SIGNAL gfx_on : std_logic;                              -- graphics mode
  SIGNAL hires  : std_logic;                              -- 640x200 1 bpp
  SIGNAL bw     : std_logic;                              -- mode-5 palette

  -- Graphics scan-out.
  -- Byte offset within a bank: 80 * (cga_y / 2) + cga_x / 4, where
  -- cga_x = XX/2 (or XX in hires) and cga_y = YY/2.  Both modes fetch a new
  -- byte every 8 VGA clocks, so the fetch address is the same expression.
  SIGNAL goff    : std_logic_vector(12 DOWNTO 0);  -- offset within bank
  SIGNAL txt_idx : std_logic_vector(12 DOWNTO 0);  -- text cell index
  SIGNAL vga_idx : std_logic_vector(12 DOWNTO 0);  -- muxed scan read index
  SIGNAL GSEL    : std_logic;                      -- even/odd byte select
  SIGNAL GPIX2   : std_logic_vector(1 DOWNTO 0);   -- 2-bpp pixel (mode 4/5)
  SIGNAL GPIX1   : std_logic;                      -- 1-bpp pixel (mode 6)
  SIGNAL gcol4   : std_logic_vector(3 DOWNTO 0);   -- graphics color index
  SIGNAL RGBGFX  : std_logic_vector(5 DOWNTO 0);
  SIGNAL PIXRGB  : std_logic_vector(5 DOWNTO 0);

BEGIN

  -- ---------------- CPU side -----------------------------------------
  -- Writes go to MEMC or MEMA depending on the low address bit.
  -- The CPU sees a flat 16 KB page from 0xB8000-0xBBFFF.  For text mode
  -- even addresses are characters and odd addresses are attributes -
  -- exactly the layout DOS/BIOS expects for color text mode.
  CPU_PORT : PROCESS (CLK_CPU)
  BEGIN
    IF rising_edge(CLK_CPU) THEN
      IF (WR = '0' AND ADDR(19 DOWNTO 14) = "101110" AND ADDR(0) = '0') THEN
        MEMC(conv_integer(ADDR(13 DOWNTO 1))) <= DATAIN;
      END IF;
      IF (WR = '0' AND ADDR(19 DOWNTO 14) = "101110" AND ADDR(0) = '1') THEN
        MEMA(conv_integer(ADDR(13 DOWNTO 1))) <= DATAIN;
      END IF;

      -- Registered read of both halves; mux on registered ADDR(0).
      MEMC_DOUT_CPU <= MEMC(conv_integer(ADDR(13 DOWNTO 1)));
      MEMA_DOUT_CPU <= MEMA(conv_integer(ADDR(13 DOWNTO 1)));
      ADDR0_REG     <= ADDR(0);

      -- CGA mode / color-select registers (same latch style as ctrl_reg).
      IF (IOWR = '0' AND IOADDR = x"03D8") THEN
        mode_q <= DATAIN;
      END IF;
      IF (IOWR = '0' AND IOADDR = x"03D9") THEN
        pal_q <= DATAIN;
      END IF;
    END IF;
  END PROCESS;

  MEM_DOUT_CPU <= MEMA_DOUT_CPU WHEN ADDR0_REG = '1' ELSE MEMC_DOUT_CPU;

  gfx_on <= mode_q(1);
  hires  <= mode_q(4);
  bw     <= mode_q(2);

  -- ---------------- VGA side -----------------------------------------
  -- Text: one cell index = 80 * text_row + text_col; both BRAMs are read
  -- at the same index (char + attribute in parallel arrays).
  -- Graphics: CGA interleave -- bank = cga_y(0) (bit 13 of the byte
  -- address = YY(1)), byte offset = 80 * (cga_y/2) + cga_x/4.  The byte
  -- address' bit 0 picks MEMC/MEMA; the rest is the array index.  The
  -- scan side performs ONE read per array per clock in either mode, so
  -- the read address is muxed by the mode bit.
  goff    <= conv_std_logic_vector(80 * conv_integer(YY(10 DOWNTO 2))
                                      + conv_integer(XX(10 DOWNTO 3)), 13);
  txt_idx <= conv_std_logic_vector(80 * conv_integer(YY(10 DOWNTO 4))
                                      + conv_integer(XX(10 DOWNTO 3)), 13);
  vga_idx <= YY(1) & goff(12 DOWNTO 1) WHEN gfx_on = '1' ELSE txt_idx;

  VGA_PORT : PROCESS (CLK_VGA)
  BEGIN
    IF rising_edge(CLK_VGA) THEN
      MEMCHR <= MEMC(conv_integer(vga_idx));
      MEMATT <= MEMA(conv_integer(vga_idx));
      GSEL   <= goff(0);
    END IF;
  END PROCESS;

  -- X/Y scan counters (unchanged)
  PROCESS (CLK_VGA)
  BEGIN
    IF (rising_edge(CLK_VGA)) THEN
      IF (X < 799) THEN
        X <= X + 1;
        -- XX must run TWO clocks ahead of the visible window, because the pixel
        -- pipeline is two registers deep: vga_idx -> MEMCHR -> CHAR. Content
        -- fetched at XX = n therefore reaches the output at X = n + 2.
        --
        -- Active video is X = 144..783 (96 sync + 48 back porch + 640). Starting
        -- XX at 142 lands cell 0 column 0 exactly on X = 144.
        --
        -- This used to start at 144, which put the image at X = 146..785: one
        -- stale pixel down the left edge and the last two columns pushed into the
        -- front porch. The stale pixel was the ROW'S FIRST CHARACTER, column 7 --
        -- during blanking XX = 0, so MEMCHR already holds cell 0 while the
        -- wrapped "XX(2:0) - 1" index reads 7. It looked like a sliver of the
        -- first letter mirrored into the left margin, and it changed per line
        -- because the first letter changes.
        --
        -- It went unnoticed for a long time because the previous font was
        -- left-aligned: only 12 printable glyphs used column 7 at all. The
        -- Philips P2120 font is inset one pixel, so 188 characters use it and the
        -- artifact appeared on nearly every line.
        IF (X > 141 AND X < 782) THEN
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
  -- The graphics pixel select uses the same "-1" fudge as the font column
  -- so the pixel lines up with the byte fetched two clocks earlier.
  PROCESS (CLK_VGA)
    VARIABLE psel  : std_logic_vector(10 DOWNTO 0);
    VARIABLE gbyte : std_logic_vector(7 DOWNTO 0);
  BEGIN
    IF (rising_edge(CLK_VGA)) THEN
      CHAR     <= GetChar(XX(2 DOWNTO 0) - 1, YY(3 DOWNTO 0), MEMCHR(7 DOWNTO 0));
      ATTR_REG <= MEMATT;

      psel := XX - 1;
      IF (GSEL = '1') THEN
        gbyte := MEMATT;
      ELSE
        gbyte := MEMCHR;
      END IF;
      -- mode 4/5: 4 pixels per byte, 2 bpp, leftmost pixel in bits 7:6;
      -- each CGA pixel spans 2 VGA clocks -> select on psel(2:1).
      CASE psel(2 DOWNTO 1) IS
        WHEN "00"   => GPIX2 <= gbyte(7 DOWNTO 6);
        WHEN "01"   => GPIX2 <= gbyte(5 DOWNTO 4);
        WHEN "10"   => GPIX2 <= gbyte(3 DOWNTO 2);
        WHEN OTHERS => GPIX2 <= gbyte(1 DOWNTO 0);
      END CASE;
      -- mode 6: 8 pixels per byte, 1 bpp, MSB first.
      GPIX1 <= gbyte(7 - conv_integer(psel(2 DOWNTO 0)));
    END IF;
  END PROCESS;

  -- HSYNC and VSYNC generation
  HS    <= '0' WHEN X < 96 ELSE '1';
  VS    <= '0' WHEN Y < 2  ELSE '1';
  -- Exactly the 640 active pixels, X = 144..783, now that XX is aligned to them.
  VALID <= '1' WHEN (X > 143 AND X < 784 AND Y > 34 AND Y < (515-80)) ELSE '0';

  -- ---------------- Color decode -------------------------------------
  -- Text attribute byte layout (CGA, 16/16 mode):
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

  -- Graphics color index:
  --   mode 4  pixel 00       -> background color (0x3D9 bits 3:0)
  --   mode 4  pixel 01/10/11 -> intensity & pixel & palette-bit
  --           (palette 0: green/red/brown, palette 1: cyan/magenta/white)
  --   mode 5  (b/w bit set)  -> cyan/red/white
  --   mode 6  pixel 1        -> 0x3D9 bits 3:0, pixel 0 -> black
  gcol4 <= pal_q(3 DOWNTO 0)  WHEN hires = '0' AND GPIX2 = "00"             ELSE
           pal_q(4) & "011"   WHEN hires = '0' AND bw = '1' AND GPIX2 = "01" ELSE
           pal_q(4) & "100"   WHEN hires = '0' AND bw = '1' AND GPIX2 = "10" ELSE
           pal_q(4) & "111"   WHEN hires = '0' AND bw = '1'                  ELSE
           pal_q(4) & GPIX2 & pal_q(5) WHEN hires = '0'                      ELSE
           pal_q(3 DOWNTO 0)  WHEN GPIX1 = '1'                               ELSE
           "0000";

  RGBGFX <= cga_to_rgb(gcol4);

  PIXRGB <= RGBGFX WHEN gfx_on = '1' ELSE RGBCHR;
  RGB    <= PIXRGB WHEN (VALID = '1' AND mode_q(3) = '1') ELSE "000000";

  -- CPU read-back of the video page
  DATAOUT <= MEM_DOUT_CPU
             WHEN (RD = '0' AND ADDR(19 DOWNTO 14) = "101110")
             ELSE "ZZZZZZZZ";

  DEBUG <= Y(5);

END;
