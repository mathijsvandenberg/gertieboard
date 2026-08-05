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
		  -- Text cursor, from crtc6845. Tie CURSOR to all-ones and CUR_MOD to
		  -- "01" to disable it: both mean "not here" and neither can draw.
		  -- There is deliberately no START here; see the note at the scan address.
		  CURSOR				  : IN std_logic_vector(13 DOWNTO 0);  -- R14/R15 cell
		  CUR_TOP				  : IN std_logic_vector(4 DOWNTO 0);   -- R10(4:0)
		  CUR_BOT				  : IN std_logic_vector(4 DOWNTO 0);   -- R11(4:0)
		  CUR_MOD				  : IN std_logic_vector(1 DOWNTO 0);   -- R10(6:5)
		  -- EGA, from ega_regs. All of these are ignored unless EGA_ON.
		  EGA_ON				  : IN std_logic;
		  -- CRTC display start (R12/R13) and row stride (R19 / 0x13). EGA only:
		  -- the CGA path deliberately ignores both, see the scan address below.
		  EGA_START				  : IN std_logic_vector(15 DOWNTO 0);
		  EGA_OFFS				  : IN std_logic_vector(7 DOWNTO 0);
		  MAP_MASK				  : IN std_logic_vector(3 DOWNTO 0);
		  SET_RES				  : IN std_logic_vector(3 DOWNTO 0);
		  EN_SR					  : IN std_logic_vector(3 DOWNTO 0);
		  ROTATE				  : IN std_logic_vector(2 DOWNTO 0);
		  FUNC_SEL				  : IN std_logic_vector(1 DOWNTO 0);
		  RD_MAP				  : IN std_logic_vector(1 DOWNTO 0);
		  WR_MODE				  : IN std_logic_vector(1 DOWNTO 0);
		  BIT_MASK				  : IN std_logic_vector(7 DOWNTO 0);
		  PALETTE				  : IN std_logic_vector(95 DOWNTO 0);
 		  HS                 	  : OUT std_logic;
 		  VS                 	  : OUT std_logic;
 		  -- Scan state for cga_status (port 0x3DA). These come from the counters
 		  -- BELOW rather than from a second set kept in step by hand: there is one
 		  -- display and there must be one description of where the beam is.
 		  DISPEN				  : OUT std_logic;   -- '1' while pixels are being drawn
 		  VRET					  : OUT std_logic;   -- '1' on every non-displayed line
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

  -- CPU read-back path. All four planes are read every cycle; which one is
  -- returned depends on the mode -- the registered ADDR(0) for CGA, the read
  -- map select for EGA.
  SIGNAL MEM_DOUT_CPU  : std_logic_vector(7 DOWNTO 0);
  SIGNAL ADDR0_REG     : std_logic;

  ----------------------------------------------------------------------------
  -- FOUR 8 KB ARRAYS, VIEWED TWO WAYS
  --
  -- CGA sees 16 KB at 0xB8000 split by the low address bit:
  --   PL0 : even byte offsets (ADDR(0) = '0') -- text: characters
  --   PL1 : odd  byte offsets (ADDR(0) = '1') -- text: attributes
  --
  -- EGA mode 0Dh sees four bit planes at 0xA0000, all at the SAME offset, with
  -- the plane chosen by register rather than by address:
  --   PL0 : blue     PL1 : green     PL2 : red     PL3 : intensity
  --
  -- They are the same memory. That is not a compromise to save space, it is
  -- what an EGA card is: one display memory the mode decides how to read. A
  -- program entering mode 0Dh finds the CGA screen's contents underneath it,
  -- exactly as it would on the real card.
  --
  -- It is also what makes this fit. Mode 0Dh needs 32 M9K blocks; 26 were free.
  -- Reusing CGA's existing 16 leaves a net 16 to find, and that fits with room
  -- to spare. Allocating EGA's planes separately would need 48 against 26 and
  -- there would be no EGA on this board.
  ----------------------------------------------------------------------------
  TYPE MEMHALF IS ARRAY (0 TO 8191) OF STD_LOGIC_VECTOR(7 DOWNTO 0);
  SIGNAL PL0 : MEMHALF;
  SIGNAL PL1 : MEMHALF;
  SIGNAL PL2 : MEMHALF;
  SIGNAL PL3 : MEMHALF;

  ATTRIBUTE ramstyle : STRING;
  ATTRIBUTE ramstyle OF PL0 : SIGNAL IS "M9K";
  ATTRIBUTE ramstyle OF PL1 : SIGNAL IS "M9K";
  ATTRIBUTE ramstyle OF PL2 : SIGNAL IS "M9K";
  ATTRIBUTE ramstyle OF PL3 : SIGNAL IS "M9K";

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

  ----------------------------------------------------------------------------
  -- Text cursor
  --
  -- The BIOS has always written the cursor position to CRTC R14/R15 and its
  -- shape to R10/R11; until crtc6845 existed there was nothing on the other end
  -- of those writes, so there was no cursor at all. These signals are that
  -- other end.
  --
  -- The cell match has to travel the SAME two pipeline stages as the character
  -- it belongs to (vga_idx -> MEMCHR -> CHAR), or the cursor would be drawn two
  -- pixels away from its own cell. Hence cur_c0/1/2 rather than one compare.
  --
  -- The row match does not need delaying: it depends only on YY, which is
  -- constant for a whole scanline. GetChar already uses YY directly for the
  -- same reason.
  ----------------------------------------------------------------------------
  SIGNAL cur_c0, cur_c1, cur_c2 : std_logic := '0';
  SIGNAL cur_row   : std_logic;
  SIGNAL cur_on    : std_logic;
  SIGNAL cur_first : std_logic_vector(4 DOWNTO 0);
  SIGNAL cur_last  : std_logic_vector(4 DOWNTO 0);
  SIGNAL cur_blink : std_logic;
  SIGNAL frame_cnt : std_logic_vector(5 DOWNTO 0) := (OTHERS => '0');
  SIGNAL vga_idx : std_logic_vector(12 DOWNTO 0);  -- muxed scan read index
  SIGNAL GSEL    : std_logic;                      -- even/odd byte select
  SIGNAL GPIX2   : std_logic_vector(1 DOWNTO 0);   -- 2-bpp pixel (mode 4/5)
  SIGNAL GPIX1   : std_logic;                      -- 1-bpp pixel (mode 6)
  SIGNAL gcol4   : std_logic_vector(3 DOWNTO 0);   -- graphics color index
  SIGNAL RGBGFX  : std_logic_vector(5 DOWNTO 0);
  SIGNAL PIXRGB  : std_logic_vector(5 DOWNTO 0);

  ----------------------------------------------------------------------------
  -- EGA CPU-side signals
  ----------------------------------------------------------------------------
  SIGNAL ega_sel  : std_logic;                      -- CPU is addressing 0xA0000
  SIGNAL cga_sel  : std_logic;                      -- ...or 0xB8000
  SIGNAL cpu_idx  : std_logic_vector(12 DOWNTO 0);  -- index into every plane
  SIGNAL ega_wr   : std_logic;

  -- THE LATCHES. Four bytes, one per plane, loaded on a CPU READ of display
  -- memory and held until the next one. They are the whole reason EGA writes
  -- are fast: a program reads one address to fill them, then writes elsewhere,
  -- and 32 bits move for one bus cycle each way.
  SIGNAL lat0, lat1, lat2, lat3 : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');

  -- Registered plane read-back, shared by the latches and the CPU read path.
  SIGNAL p0_cpu, p1_cpu, p2_cpu, p3_cpu : std_logic_vector(7 DOWNTO 0);

  -- Per-plane write data, computed combinationally from the latches, the
  -- rotated CPU byte, set/reset, the function select and the bit mask.
  SIGNAL wd0, wd1, wd2, wd3 : std_logic_vector(7 DOWNTO 0);
  SIGNAL rot_data           : std_logic_vector(7 DOWNTO 0);

  -- Resolved write port: one enable and one datum per plane, so each array has
  -- exactly one write statement. See the note above the assignments.
  SIGNAL wen0, wen1, wen2, wen3 : std_logic;
  SIGNAL wdat0, wdat1           : std_logic_vector(7 DOWNTO 0);

  -- Scan-side plane reads for EGA.
  SIGNAL s2, s3 : std_logic_vector(7 DOWNTO 0);   -- planes 2 and 3;
                                                  -- 0 and 1 are MEMCHR/MEMATT
  SIGNAL ega_idx        : std_logic_vector(12 DOWNTO 0);
  -- Row base, accumulated once per CGA scanline; see the scan address.
  SIGNAL row_base       : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ega_stride     : std_logic_vector(15 DOWNTO 0);
  -- START and OFFSET cross c0 -> c1 and are sampled once a field, so they get
  -- two flops each. Fourteen-odd bits sampled at one instant is a metastability
  -- hazard whose symptom is one field drawn from a nonsense address -- rare
  -- enough to read as an intermittent glitch rather than a fault.
  SIGNAL st_s1, st_s2   : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL of_s1, of_s2   : std_logic_vector(7 DOWNTO 0)  := (OTHERS => '0');
  SIGNAL ega_col        : std_logic_vector(3 DOWNTO 0);
  SIGNAL ega_pal        : std_logic_vector(5 DOWNTO 0);
  SIGNAL RGBEGA         : std_logic_vector(5 DOWNTO 0);

  ----------------------------------------------------------------------------
  -- One plane's worth of the EGA write path.
  --
  -- Every plane does the same thing to a different source byte, so this is
  -- written once. src is already chosen by write mode; what happens after is
  -- identical: combine with the latch through the function select, then let the
  -- bit mask decide, bit by bit, whether the result or the ORIGINAL LATCH
  -- CONTENT survives.
  --
  -- That last part is the one people get wrong. The bit mask does not mask the
  -- write to zero -- masked-out bits come back from the latch, which is why a
  -- masked write must always be preceded by a read of the same address. A
  -- program that skips the read gets the previous latch content smeared into
  -- the bits it thought it was protecting.
  ----------------------------------------------------------------------------
  -- One bit, eight times. Used wherever EGA expands a single plane bit into a
  -- whole byte -- set/reset and write mode 2 both do it.
  FUNCTION rep8(b : std_logic) RETURN std_logic_vector IS
  BEGIN
    RETURN b & b & b & b & b & b & b & b;
  END FUNCTION;

  FUNCTION ega_plane(src  : std_logic_vector(7 DOWNTO 0);
                     lat  : std_logic_vector(7 DOWNTO 0);
                     fsel : std_logic_vector(1 DOWNTO 0);
                     mask : std_logic_vector(7 DOWNTO 0))
                     RETURN std_logic_vector IS
    VARIABLE v : std_logic_vector(7 DOWNTO 0);
  BEGIN
    CASE fsel IS
      WHEN "00"   => v := src;             -- replace
      WHEN "01"   => v := src AND lat;
      WHEN "10"   => v := src OR  lat;
      WHEN OTHERS => v := src XOR lat;
    END CASE;
    RETURN (v AND mask) OR (lat AND NOT mask);
  END FUNCTION;

BEGIN

  -- ---------------- CPU side -----------------------------------------
  -- Writes go to MEMC or MEMA depending on the low address bit.
  -- The CPU sees a flat 16 KB page from 0xB8000-0xBBFFF.  For text mode
  -- even addresses are characters and odd addresses are attributes -
  -- exactly the layout DOS/BIOS expects for color text mode.
  cga_sel <= '1' WHEN ADDR(19 DOWNTO 14) = "101110"   ELSE '0';  -- 0xB8000
  ega_sel <= '1' WHEN (ADDR(19 DOWNTO 16) = "1010" AND
                       EGA_ON = '1')                  ELSE '0';  -- 0xA0000
  ega_wr  <= '1' WHEN (WR = '0' AND ega_sel = '1')    ELSE '0';

  -- CGA indexes by the WORD (the low bit picks the plane); EGA indexes by the
  -- byte, and every plane sees the same index.
  cpu_idx <= ADDR(12 DOWNTO 0) WHEN ega_sel = '1' ELSE ADDR(13 DOWNTO 1);

  -- The CPU byte, rotated right by GC 3(2:0). Almost always zero, and almost
  -- always left in place by software that does not use it -- but a barrel
  -- rotate is cheap and leaving it out breaks the programs that do.
  WITH ROTATE SELECT rot_data <=
      DATAIN                                                   WHEN "000",
      DATAIN(0)          & DATAIN(7 DOWNTO 1)                   WHEN "001",
      DATAIN(1 DOWNTO 0) & DATAIN(7 DOWNTO 2)                   WHEN "010",
      DATAIN(2 DOWNTO 0) & DATAIN(7 DOWNTO 3)                   WHEN "011",
      DATAIN(3 DOWNTO 0) & DATAIN(7 DOWNTO 4)                   WHEN "100",
      DATAIN(4 DOWNTO 0) & DATAIN(7 DOWNTO 5)                   WHEN "101",
      DATAIN(5 DOWNTO 0) & DATAIN(7 DOWNTO 6)                   WHEN "110",
      DATAIN(6 DOWNTO 0) & DATAIN(7)                            WHEN OTHERS;

  ----------------------------------------------------------------------------
  -- What each plane would be written with, by write mode.
  --
  --   0  the general case: per plane, either set/reset expanded to 0x00/0xFF
  --      (where enable-set/reset says so) or the rotated CPU byte
  --   1  the latches, straight through. The CPU data is IGNORED -- this is the
  --      fast copy, one bus cycle in and one out for 32 bits, and it is what
  --      EGA software scrolls and blits with
  --   2  the CPU data's low nibble as a COLOUR: bit n expanded to 0x00/0xFF
  --      across plane n, so one write paints eight pixels one colour
  --
  -- Write mode 3 exists on VGA, not EGA, and is not implemented.
  ----------------------------------------------------------------------------
  wd0 <= lat0 WHEN WR_MODE = "01" ELSE
         ega_plane(rep8(DATAIN(0)), lat0, FUNC_SEL, BIT_MASK)
                     WHEN WR_MODE = "10" ELSE
         ega_plane(rep8(SET_RES(0)), lat0, FUNC_SEL, BIT_MASK)
                     WHEN EN_SR(0) = '1' ELSE
         ega_plane(rot_data, lat0, FUNC_SEL, BIT_MASK);

  wd1 <= lat1 WHEN WR_MODE = "01" ELSE
         ega_plane(rep8(DATAIN(1)), lat1, FUNC_SEL, BIT_MASK)
                     WHEN WR_MODE = "10" ELSE
         ega_plane(rep8(SET_RES(1)), lat1, FUNC_SEL, BIT_MASK)
                     WHEN EN_SR(1) = '1' ELSE
         ega_plane(rot_data, lat1, FUNC_SEL, BIT_MASK);

  wd2 <= lat2 WHEN WR_MODE = "01" ELSE
         ega_plane(rep8(DATAIN(2)), lat2, FUNC_SEL, BIT_MASK)
                     WHEN WR_MODE = "10" ELSE
         ega_plane(rep8(SET_RES(2)), lat2, FUNC_SEL, BIT_MASK)
                     WHEN EN_SR(2) = '1' ELSE
         ega_plane(rot_data, lat2, FUNC_SEL, BIT_MASK);

  wd3 <= lat3 WHEN WR_MODE = "01" ELSE
         ega_plane(rep8(DATAIN(3)), lat3, FUNC_SEL, BIT_MASK)
                     WHEN WR_MODE = "10" ELSE
         ega_plane(rep8(SET_RES(3)), lat3, FUNC_SEL, BIT_MASK)
                     WHEN EN_SR(3) = '1' ELSE
         ega_plane(rot_data, lat3, FUNC_SEL, BIT_MASK);

  ----------------------------------------------------------------------------
  -- ONE WRITE STATEMENT PER PLANE. The CGA and EGA cases are resolved into a
  -- single enable and a single datum HERE, in logic, rather than as two
  -- separate assignments inside the clocked process.
  --
  -- That is not a matter of taste. Two writes to one array signal in a single
  -- clock stops Quartus inferring RAM at all -- it reports
  --
  --     Warning (11000): can't infer memory for variable 'pl0'
  --
  -- and quietly builds 8192 BYTES OF FLIP-FLOPS instead, which does not fit and
  -- does not resemble a memory-map problem when it fails. This design has been
  -- caught by it before; see docs/gotchas.md, "Two writes to one array signal
  -- in a single clock". PL2 and PL3 inferred correctly on the same build that
  -- PL0 and PL1 failed on, because only the first two carry both roles.
  --
  -- cpu_idx already carries the right index for either mode, so the address
  -- needs no mux of its own.
  ----------------------------------------------------------------------------
  wen0 <= '1' WHEN ((WR = '0' AND cga_sel = '1' AND ADDR(0) = '0') OR
                    (ega_wr = '1' AND MAP_MASK(0) = '1')) ELSE '0';
  wen1 <= '1' WHEN ((WR = '0' AND cga_sel = '1' AND ADDR(0) = '1') OR
                    (ega_wr = '1' AND MAP_MASK(1) = '1')) ELSE '0';
  wen2 <= '1' WHEN  (ega_wr = '1' AND MAP_MASK(2) = '1')  ELSE '0';
  wen3 <= '1' WHEN  (ega_wr = '1' AND MAP_MASK(3) = '1')  ELSE '0';

  wdat0 <= wd0 WHEN ega_sel = '1' ELSE DATAIN;
  wdat1 <= wd1 WHEN ega_sel = '1' ELSE DATAIN;

  CPU_PORT : PROCESS (CLK_CPU)
  BEGIN
    IF rising_edge(CLK_CPU) THEN

      -- ---- writes ----------------------------------------------------
      -- In CGA the low address bit chose the plane; in EGA the map mask does,
      -- and every enabled plane takes its own computed byte at the same index.
      --
      -- WR is a LEVEL held for the whole bus cycle, so this fires on several
      -- clock edges per access. That is safe, including for the XOR function,
      -- because every input is fixed for the duration: the latches only load on
      -- reads, so the result never feeds back into itself. Writing a second
      -- time writes the same byte.
      IF wen0 = '1' THEN PL0(conv_integer(cpu_idx)) <= wdat0; END IF;
      IF wen1 = '1' THEN PL1(conv_integer(cpu_idx)) <= wdat1; END IF;
      IF wen2 = '1' THEN PL2(conv_integer(cpu_idx)) <= wd2;   END IF;
      IF wen3 = '1' THEN PL3(conv_integer(cpu_idx)) <= wd3;   END IF;

      -- ---- reads -----------------------------------------------------
      -- All four planes every cycle. CGA needs two of them and EGA needs all
      -- four for the latches, so reading them unconditionally costs nothing
      -- and keeps one read port per array.
      p0_cpu    <= PL0(conv_integer(cpu_idx));
      p1_cpu    <= PL1(conv_integer(cpu_idx));
      p2_cpu    <= PL2(conv_integer(cpu_idx));
      p3_cpu    <= PL3(conv_integer(cpu_idx));
      ADDR0_REG <= ADDR(0);

      -- THE LATCHES LOAD ONLY WHILE A READ IS IN PROGRESS.
      --
      -- Not every cycle. If they simply followed the read data they would
      -- track the CPU's address, and write mode 1 -- read here, write there --
      -- would find them holding the DESTINATION's contents by the time the
      -- write landed. Every latch copy would write each address to itself and
      -- the screen would never change. Gating on RD makes them hold across the
      -- address change, which is the entire point of having them.
      IF (RD = '0' AND ega_sel = '1') THEN
        lat0 <= p0_cpu;
        lat1 <= p1_cpu;
        lat2 <= p2_cpu;
        lat3 <= p3_cpu;
      END IF;

      -- CGA mode / color-select registers (same latch style as ctrl_reg).
      IF (IOWR = '0' AND IOADDR = x"03D8") THEN
        mode_q <= DATAIN;
      END IF;
      IF (IOWR = '0' AND IOADDR = x"03D9") THEN
        pal_q <= DATAIN;
      END IF;
    END IF;
  END PROCESS;

  -- CGA read-back muxes on the registered low address bit; EGA read mode 0
  -- returns whichever plane READ MAP SELECT names.
  MEM_DOUT_CPU <= p0_cpu WHEN (ega_sel = '1' AND RD_MAP = "00") ELSE
                  p1_cpu WHEN (ega_sel = '1' AND RD_MAP = "01") ELSE
                  p2_cpu WHEN (ega_sel = '1' AND RD_MAP = "10") ELSE
                  p3_cpu WHEN  ega_sel = '1'                    ELSE
                  p1_cpu WHEN ADDR0_REG = '1' ELSE p0_cpu;

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
  --
  -- NO HARDWARE SCROLLING, and that is a decision rather than an omission.
  --
  -- crtc6845 brings out R12/R13, the 6845's display start address, and this
  -- once added it here: the address counter loads from R12/R13 at the top of
  -- each field instead of from zero, so software scrolls by moving a register
  -- rather than 4000 bytes of screen. That is how the real chip works and the
  -- arithmetic below was written to match it -- a cell index in text, doubled
  -- to bytes in graphics because the CGA fetches two bytes per count.
  --
  -- On this machine it made the picture worse in every mode that used it. Keen
  -- 4 came back overlapping itself, and Arkanoid's TEXT screen came out shifted
  -- -- text, where the unit is unambiguous and the arithmetic is a single
  -- addition. A start address that is honoured but lands in the wrong place is
  -- worse than one that is ignored, because software that never scrolls is
  -- unaffected by the second and corrupted by the first.
  --
  -- What was NOT established before it was reverted: whether the fault is in
  -- this addressing or in something else the CRTC ought to be supplying with it
  -- (R1, the row length, is hardcoded to 80 bytes here and a scrolling program
  -- may well be changing it). tools/scrolltst.com exists to settle that -- it
  -- drives R12/R13 by a known amount against a readable pattern -- and until it
  -- has been run, honouring the register is guesswork with the screen as the
  -- only output. So R12/R13 are latched by crtc6845, read back as a real 6845
  -- does, and go nowhere.
  goff    <= conv_std_logic_vector(80 * conv_integer(YY(10 DOWNTO 2))
                                      + conv_integer(XX(10 DOWNTO 3)), 13);
  txt_idx <= conv_std_logic_vector(80 * conv_integer(YY(10 DOWNTO 4))
                                      + conv_integer(XX(10 DOWNTO 3)), 13);
  ----------------------------------------------------------------------------
  -- EGA mode 0Dh scan address.
  --
  -- 320x200 with 16 colours is 8 pixels to a byte and 40 bytes to a row, and
  -- every plane holds the same byte at the same offset -- one bit of the
  -- colour each. So there is no interleave and no bank bit here: unlike CGA
  -- mode 4, consecutive rows are consecutive memory.
  --
  --     offset = 40 * cga_y + cga_x / 8,  cga_y = YY/2,  cga_x = XX/2
  --
  -- which is 40 * YY(10:1) + XX(10:4). Maximum 40*199 + 39 = 7999, inside the
  -- 8192 each plane holds.
  --
  -- 320x200 doubles into the 640x400 active area exactly, the same as CGA
  -- mode 4, so nothing about the timing changes.
  ----------------------------------------------------------------------------
  ----------------------------------------------------------------------------
  -- THE ROW STRIDE IS NOT 40. It is whatever the CRTC's Offset register says.
  --
  -- This used to be hardcoded at 40 bytes -- 320 pixels, eight to a byte -- and
  -- Keen 4 came out sheared, every scanline displaced a little further than the
  -- one above it. That progressive displacement is the signature of a stride
  -- mismatch and nothing else.
  --
  -- The Offset register (0x13) sets the width of a LOGICAL line in words, and
  -- software makes it wider than the display on purpose: the extra becomes the
  -- margin it scrolls into. A game with a 320-pixel window and a 352-pixel
  -- logical line moves horizontally by changing the start address instead of
  -- redrawing, which is the whole reason EGA scrolls smoothly and CGA does not.
  -- Hardcoding the stride assumes nobody ever wants that, and every scrolling
  -- game wants it.
  --
  -- ACCUMULATED, NOT MULTIPLIED. The obvious form is
  --
  --     ega_idx = start + stride * row + XX/16
  --
  -- but a variable stride makes that a real multiplier sitting in the 25 MHz
  -- pixel path, and the worst slack on this design is already +0.15 ns. So the
  -- row base is a register that gains one stride per CGA scanline, which is
  -- both cheaper and what an actual CRTC does: it latches the start address at
  -- the top of the field and adds the offset per row.
  ega_stride <= x"00" & of_s2(6 DOWNTO 0) & '0';      -- words -> bytes
  ega_idx    <= row_base(12 DOWNTO 0) + XX(10 DOWNTO 4);

  vga_idx <= ega_idx                   WHEN EGA_ON = '1' ELSE
             YY(1) & goff(12 DOWNTO 1) WHEN gfx_on = '1' ELSE
             txt_idx;

  -- Is the cell being fetched RIGHT NOW the one the CRTC points at? Compared
  -- here, beside vga_idx, so it can be pipelined alongside the character it
  -- refers to rather than chasing it two stages later.
  cur_c0 <= '1' WHEN (txt_idx = CURSOR(12 DOWNTO 0)) ELSE '0';

  VGA_PORT : PROCESS (CLK_VGA)
  BEGIN
    IF rising_edge(CLK_VGA) THEN
      -- EXACTLY ONE READ PER ARRAY PER CLOCK, in every mode. An M9K has two
      -- ports and both are spoken for -- CPU on one, scan on the other -- so a
      -- second scan read of the same array would make Quartus duplicate the
      -- RAM to serve it, and 32 blocks would silently become 48. There is no
      -- warning for that; it shows up as a fit that no longer closes.
      --
      -- Hence MEMCHR and MEMATT ARE planes 0 and 1. CGA reads them as
      -- character/attribute or as the even/odd graphics bytes; EGA reads the
      -- same two registers as its first two bit planes.
      MEMCHR <= PL0(conv_integer(vga_idx));
      MEMATT <= PL1(conv_integer(vga_idx));
      s2     <= PL2(conv_integer(vga_idx));
      s3     <= PL3(conv_integer(vga_idx));
      GSEL   <= goff(0);
      cur_c1 <= cur_c0;                 -- rides with MEMCHR, stage 1 of 2

      -- Clock-domain crossing, c0 -> c1. FREE-RUNNING, every pixel clock: a
      -- two-flop synchroniser only resolves metastability if the second flop
      -- gets a whole clock to settle after the first. Sampling these once a
      -- field instead would give the pair one edge every 16.8 ms and defeat
      -- the point of having two.
      st_s1 <= EGA_START;  st_s2 <= st_s1;
      of_s1 <= EGA_OFFS;   of_s2 <= of_s1;
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
            -- A new CGA scanline begins on every EVEN YY, because the 200-line
            -- picture is doubled into 400. So the row base advances at the end
            -- of every odd line: YY = 0,1 is row 0, and stepping off YY = 1
            -- sets up row 1.
            IF YY(0) = '1' THEN
              row_base <= row_base + ega_stride;
            END IF;
          END IF;
        ELSE
          Y  <= "00000000000";
          YY <= "00000000000";
          frame_cnt <= frame_cnt + 1;   -- one per field, drives the cursor blink

          -- Load the address counter from the start address, once per field.
          -- A 6845 does exactly this during vertical retrace and then simply
          -- counts, which is why software may write the register at any time
          -- without tearing the picture -- and why adding it per pixel instead,
          -- as the first attempt at CGA scrolling did, splits the screen at
          -- whatever line the write happened to land on.
          row_base <= st_s2;

          -- If the display start address is ever wired in again, it is latched
          -- HERE and nowhere else. A 6845 loads its address counter from
          -- R12/R13 at the top of each field and then simply counts; the
          -- register is not consulted again until the next field. Adding it at
          -- every pixel instead -- which is what the first attempt did -- means
          -- a write part way down the screen moves everything below it and
          -- nothing above it, and the picture splits at whatever scanline the
          -- write landed on.
          --
          -- It would also need synchronising: START is written by the CPU on c0
          -- and would be read here on c1, and an unsynchronised sample of
          -- fourteen bits taken once a field is a metastability hazard that
          -- shows up as one field displayed from a nonsense address. CURSOR
          -- crosses the same boundary unsynchronised and gets away with it,
          -- because a cursor in the wrong cell for one field of 59 is invisible
          -- and a scroll position is not.
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
      cur_c2   <= cur_c1;               -- rides with CHAR, stage 2 of 2

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

      -- EGA: one bit from each of the four planes, at the same position, MSB
      -- first -- plane 3 is the most significant, giving I R G B.
      --
      -- Computed HERE, in the second stage, for the same two reasons GPIX2 is:
      -- it must sit at the same pipeline depth as the CGA pixel or the EGA
      -- image would come out one VGA pixel to the left of everything else, and
      -- it must use the same "psel = XX - 1" compensation. That -1 is what
      -- makes the byte boundary work: at the clock where the byte index moves
      -- on, psel still points at the LAST pixel of the previous byte, which is
      -- exactly the byte the stage-1 registers are still holding.
      --
      -- Eight pixels per byte here against four in CGA mode 4, so the pixel
      -- field is psel(3:1) rather than psel(2:1).
      ega_col <= s3(7 - conv_integer(psel(3 DOWNTO 1))) &
                 s2(7 - conv_integer(psel(3 DOWNTO 1))) &
                 MEMATT(7 - conv_integer(psel(3 DOWNTO 1))) &
                 MEMCHR(7 - conv_integer(psel(3 DOWNTO 1)));
    END IF;
  END PROCESS;

  -- HSYNC and VSYNC generation
  HS    <= '0' WHEN X < 96 ELSE '1';
  VS    <= '0' WHEN Y < 2  ELSE '1';
  -- Exactly the 640 active pixels, X = 144..783, now that XX is aligned to them.
  VALID <= '1' WHEN (X > 143 AND X < 784 AND Y > 34 AND Y < (515-80)) ELSE '0';

  ----------------------------------------------------------------------------
  -- Scan state for port 0x3DA.
  --
  -- cga_status used to keep its own 800x525 counters and derive both bits from
  -- them. Same geometry, written twice -- and the two copies did not agree. It
  -- called lines 400..524 the vertical retrace, but the picture is drawn on
  -- lines 35..434, so it announced blanking while the BOTTOM 35 VISIBLE LINES
  -- were still being scanned. Software that waits for retrace before touching
  -- video memory -- which is every game that cares -- got 1.1 ms of the active
  -- display it had been promised was safe. Horizontally it was 288 ticks out
  -- for the same reason.
  --
  -- DISPEN is VALID, which is the definition of "pixels are being drawn", and
  -- VRET covers every line that is not displayed: 435..524 and 0..34, 125 lines
  -- of the 525. That is the same 3.97 ms window as before -- it is now in the
  -- right place, and it cannot drift again because there is nothing to drift
  -- from.
  DISPEN <= VALID;
  VRET   <= '1' WHEN (Y > 434 OR Y < 35) ELSE '0';

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

  ----------------------------------------------------------------------------
  -- Text cursor decode
  --
  -- SCANLINES DOUBLE. The BIOS programs a genuine CGA: R9 = 7, so eight lines
  -- to a cell, with the cursor on lines 6 and 7. This display is 400 active
  -- lines with SIXTEEN to a cell -- every CGA scanline drawn twice -- so the
  -- cursor's lines double with everything else. Taken literally, 6..7 of
  -- sixteen would sit across the middle of the character instead of under it.
  --
  -- Doubling also makes a two-line CGA cursor four lines here, which is right:
  -- it is the same fraction of the cell, and it matches how the glyph is
  -- stretched.
  cur_first <= CUR_TOP(3 DOWNTO 0) & '0';        -- first * 2
  cur_last  <= CUR_BOT(3 DOWNTO 0) & '1';        -- last * 2 + 1

  cur_row <= '1' WHEN (('0' & YY(3 DOWNTO 0)) >= cur_first AND
                       ('0' & YY(3 DOWNTO 0)) <= cur_last) ELSE '0';

  -- A first line ABOVE the last is how software hides the cursor without
  -- touching the blink bits, and it falls out of the comparison above for free.

  -- R10(6:5) selects the blink rate. 01 means "cursor off" and is honoured;
  -- 11 is the slower rate. Anything else blinks at the faster one, including
  -- the 00 this BIOS actually writes -- a machine of this era shows a blinking
  -- cursor with exactly that value, and reproducing the machine is the point.
  -- frame_cnt(3) is 8 fields on, 8 off: about 3.7 Hz at 59.5 Hz.
  cur_blink <= frame_cnt(4) WHEN CUR_MOD = "11" ELSE frame_cnt(3);

  cur_on <= '1' WHEN (cur_c2   = '1' AND cur_row   = '1' AND
                      gfx_on   = '0' AND CUR_MOD  /= "01" AND
                      cur_blink = '1') ELSE '0';

  -- Drawn in the cell's own foreground colour, so it inherits whatever colour
  -- the text under it is using rather than being hardcoded white.
  RGBCHR <= fg_rgb WHEN (CHAR = '1' OR cur_on = '1') ELSE bg_rgb;

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

  ----------------------------------------------------------------------------
  -- EGA colour decode
  --
  -- One bit from each plane at the same position makes the 4-bit index, plane 3
  -- most significant: I R G B. The index is NOT a colour -- it selects one of
  -- the sixteen attribute-controller palette registers, and THAT is the colour.
  -- The indirection is the point: a game repaints the whole screen by writing
  -- sixteen registers, which is how EGA titles fade and flash without touching
  -- a pixel.
  --
  -- Each palette register is six bits, two per channel, primary and secondary:
  --     bit 5 4 3 2 1 0
  --         r g b R G B          upper case = primary, lower = secondary
  --
  -- The primary contributes two thirds and the secondary one third, so the
  -- primary is the MORE significant of each channel's two bits when packed into
  -- this board's RRGGBB output. Getting that pair the wrong way round still
  -- produces sixteen distinct colours -- it just produces the wrong ones, dimly,
  -- which is far harder to spot than a blank screen.
  ----------------------------------------------------------------------------
  ega_pal <= PALETTE(6 * conv_integer(ega_col) + 5 DOWNTO
                     6 * conv_integer(ega_col));

  RGBEGA <= ega_pal(2) & ega_pal(5) &      -- red   : primary, secondary
            ega_pal(1) & ega_pal(4) &      -- green
            ega_pal(0) & ega_pal(3);       -- blue

  PIXRGB <= RGBEGA WHEN EGA_ON = '1' ELSE
            RGBGFX WHEN gfx_on = '1' ELSE
            RGBCHR;

  -- EGA has no equivalent of the CGA video-enable bit at 0x3D8 bit 3, and
  -- software in mode 0Dh never writes 0x3D8 at all -- so honouring it here
  -- would leave the screen black for every EGA program.
  RGB    <= PIXRGB WHEN (VALID = '1' AND (mode_q(3) = '1' OR EGA_ON = '1'))
            ELSE "000000";

  -- CPU read-back of the video page, from either window.
  DATAOUT <= MEM_DOUT_CPU
             WHEN (RD = '0' AND (cga_sel = '1' OR ega_sel = '1'))
             ELSE "ZZZZZZZZ";

  DEBUG <= Y(5);

END;
