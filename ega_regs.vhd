--------------------------------------------------------------------------------
-- ega_regs.vhd  --  the EGA register file at I/O 0x3C0..0x3CF
--
-- vga.vhd draws the picture; this decides what the picture is made of. Three
-- separate register blocks live behind these ports, and EGA software drives all
-- three constantly -- the write path in particular is reprogrammed several times
-- per drawing operation, not configured once at startup.
--
--     0x3C0        Attribute Controller   16 palette registers, and mode
--     0x3C4/0x3C5  Sequencer              map mask: which planes a write reaches
--     0x3CE/0x3CF  Graphics Controller    the whole read-modify-write path
--
-- Only mode 0Dh (320x200x16) is targeted. That is four planes of 8 KB, which is
-- what fits on this device -- see docs/status.md. The register model here is
-- complete enough for software written against a real EGA to work unmodified,
-- because software does not ask which mode you implemented.
--
-- ---------------------------------------------------------------------------
-- THE 0x3C0 FLIP-FLOP, WHICH IS THE PART THAT CATCHES PEOPLE
--
-- The Attribute Controller has ONE port for both its index and its data. Writes
-- alternate: index, data, index, data. Which one the next write means is held in
-- a single flip-flop -- and that flip-flop is reset to "expect an index" by
-- READING PORT 0x3DA.
--
-- That is not a quirk to work around, it is how every EGA program resynchronises
-- before touching the palette, precisely because the alternation can be left in
-- either state by whatever ran before. A card that ignores the 0x3DA read looks
-- fine until a program takes the reset for granted, and then writes every index
-- as data and every colour as an index. The result is a picture in the wrong
-- colours rather than an error.
--
-- So this module watches the I/O READ strobe for 0x3DA. It does not answer that
-- port -- cga_status does -- it only observes it. No coupling between the two is
-- needed and none exists.
--
-- ---------------------------------------------------------------------------
-- HOW THE CARD KNOWS IT IS IN EGA MODE
--
-- Not from a bit somebody invented for this board. Graphics Controller register
-- 6 (Miscellaneous) carries bit 0 = "graphics mode" and bits 3:2 = which host
-- window the display memory appears in. Mode 0Dh sets it to 0x05: graphics, and
-- 0xA0000 for 64 KB. Text mode 3 sets 0x0E: alphanumeric, and 0xB8000 for 32 KB.
--
--     ega_on <= gc(6)(0) AND (gc(6)(3 DOWNTO 2) = "01")
--
-- That is the same test the real hardware makes, so software that sets modes by
-- programming registers directly -- rather than through INT 10h -- gets the same
-- answer here as it would on the card it was written for. A private enable bit
-- would have worked only for software that knew about this board, which is none
-- of it.
--
-- Wiring (top level):
--   CLK     <- n_c0, the peripheral clock the other I/O modules use
--   RD/WR   <- n_io_rd / n_io_wr, active low, I/O strobes only
--   ADDR    <- n_io_addr        DATA -> n_cpu_wdata
--   DATAOUT -> n_periph_rdata, the shared tri-state read bus
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;
USE  IEEE.NUMERIC_STD.ALL;

ENTITY ega_regs IS
  PORT(
        CLK      : IN    std_logic;
        DATA     : IN    std_logic_vector(7 DOWNTO 0);   -- CPU -> device
        ADDR     : IN    std_logic_vector(15 DOWNTO 0);  -- I/O address
        RD       : IN    std_logic;                      -- active LOW I/O read
        WR       : IN    std_logic;                      -- active LOW I/O write
        DATAOUT  : INOUT std_logic_vector(7 DOWNTO 0);   -- 'Z' when not addressed

        -- To vga.vhd
        EGA_ON   : OUT   std_logic;                      -- mode 0Dh is active
        MAP_MASK : OUT   std_logic_vector(3 DOWNTO 0);   -- SEQ 2
        SET_RES  : OUT   std_logic_vector(3 DOWNTO 0);   -- GC 0
        EN_SR    : OUT   std_logic_vector(3 DOWNTO 0);   -- GC 1
        COL_CMP  : OUT   std_logic_vector(3 DOWNTO 0);   -- GC 2
        ROTATE   : OUT   std_logic_vector(2 DOWNTO 0);   -- GC 3(2:0)
        FUNC_SEL : OUT   std_logic_vector(1 DOWNTO 0);   -- GC 3(4:3)
        RD_MAP   : OUT   std_logic_vector(1 DOWNTO 0);   -- GC 4
        WR_MODE  : OUT   std_logic_vector(1 DOWNTO 0);   -- GC 5(1:0)
        RD_MODE  : OUT   std_logic;                      -- GC 5(3)
        COL_DC   : OUT   std_logic_vector(3 DOWNTO 0);   -- GC 7
        BIT_MASK : OUT   std_logic_vector(7 DOWNTO 0);   -- GC 8
        -- The palette, flattened: entry i is PALETTE(6i+5 DOWNTO 6i)
        PALETTE  : OUT   std_logic_vector(95 DOWNTO 0));
END ega_regs;

ARCHITECTURE behavior OF ega_regs IS

  TYPE seq_t IS ARRAY(0 TO 7)  OF std_logic_vector(7 DOWNTO 0);
  TYPE gc_t  IS ARRAY(0 TO 15) OF std_logic_vector(7 DOWNTO 0);
  TYPE pal_t IS ARRAY(0 TO 15) OF std_logic_vector(5 DOWNTO 0);

  -- Power-on values are a real EGA's after a mode-0Dh set, so the outputs are
  -- sane before any software has touched them. In particular MAP_MASK defaults
  -- to all four planes enabled and BIT_MASK to all bits: a write that reaches
  -- the card before the sequencer is programmed then does something visible
  -- rather than silently nothing, which is much easier to debug.
  SIGNAL seq : seq_t := (2 => x"0F", OTHERS => x"00");
  SIGNAL gc  : gc_t  := (8 => x"FF", OTHERS => x"00");

  -- The default EGA palette. Index 6 is 0x14 and not 0x06 -- that is what makes
  -- colour 6 BROWN instead of dark yellow, the same exception the CGA palette
  -- has in cga_to_rgb(). Getting this wrong is not subtle on screen: every
  -- period game uses colour 6 for wood, earth and skin.
  SIGNAL pal : pal_t := (
      0  => "000000", 1  => "000001", 2  => "000010", 3  => "000011",
      4  => "000100", 5  => "000101", 6  => "010100", 7  => "000111",
      8  => "111000", 9  => "111001", 10 => "111010", 11 => "111011",
      12 => "111100", 13 => "111101", 14 => "111110", 15 => "111111");

  SIGNAL seq_idx : unsigned(2 DOWNTO 0) := (OTHERS => '0');
  SIGNAL gc_idx  : unsigned(3 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ac_idx  : unsigned(4 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ac_ff   : std_logic := '0';       -- '0' = next 0x3C0 write is an index

  SIGNAL wr_act, wr_prev : std_logic := '0';
  SIGNAL rd_act, rd_prev : std_logic := '0';

  SIGNAL rdval  : std_logic_vector(7 DOWNTO 0);
  SIGNAL sel_rd : std_logic;

BEGIN

  wr_act <= NOT WR;
  rd_act <= NOT RD;

  ----------------------------------------------------------------------------
  -- Read path. The EGA is far more readable than the 6845 -- the sequencer and
  -- graphics controller echo what was written, which is what BIOSes rely on to
  -- save and restore state around a mode change.
  ----------------------------------------------------------------------------
  rdval <= seq(to_integer(seq_idx))              WHEN ADDR = x"03C5" ELSE
           gc(to_integer(gc_idx))                WHEN ADDR = x"03CF" ELSE
           "00" & pal(to_integer(ac_idx(3 DOWNTO 0)))
                                                 WHEN (ADDR = x"03C1" AND ac_idx < 16) ELSE
           "00000" & std_logic_vector(seq_idx)   WHEN ADDR = x"03C4" ELSE
           "0000" & std_logic_vector(gc_idx)     WHEN ADDR = x"03CE" ELSE
           x"00";

  sel_rd  <= '1' WHEN (RD = '0' AND (ADDR = x"03C5" OR ADDR = x"03CF" OR
                                     ADDR = x"03C1" OR ADDR = x"03C4" OR
                                     ADDR = x"03CE")) ELSE '0';
  DATAOUT <= rdval WHEN sel_rd = '1' ELSE "ZZZZZZZZ";

  ----------------------------------------------------------------------------
  -- Straight out for vga.vhd.
  ----------------------------------------------------------------------------
  -- Graphics mode AND memory map = 01. The map field is bits 3:2, so "01" is
  -- bit 3 CLEAR and bit 2 SET -- the opposite way round from how it reads if
  -- you take the bits in the order they are written:
  --     00 = A0000 128K    01 = A0000 64K    10 = B0000 32K    11 = B8000 32K
  -- Mode 0Dh writes 0x05 here (graphics, A0000 64K); text mode 3 writes 0x0E
  -- (alphanumeric, B8000 32K), which is why the CGA path keeps working.
  EGA_ON   <= gc(6)(0) AND (NOT gc(6)(3)) AND gc(6)(2);

  MAP_MASK <= seq(2)(3 DOWNTO 0);
  SET_RES  <= gc(0)(3 DOWNTO 0);
  EN_SR    <= gc(1)(3 DOWNTO 0);
  COL_CMP  <= gc(2)(3 DOWNTO 0);
  ROTATE   <= gc(3)(2 DOWNTO 0);
  FUNC_SEL <= gc(3)(4 DOWNTO 3);
  RD_MAP   <= gc(4)(1 DOWNTO 0);
  WR_MODE  <= gc(5)(1 DOWNTO 0);
  RD_MODE  <= gc(5)(3);
  COL_DC   <= gc(7)(3 DOWNTO 0);
  BIT_MASK <= gc(8);

  PAL_FLAT : FOR i IN 0 TO 15 GENERATE
    PALETTE(6*i+5 DOWNTO 6*i) <= pal(i);
  END GENERATE;

  ----------------------------------------------------------------------------
  -- Write path, and the 0x3DA observation.
  --
  -- Edge-detected rather than level-sampled, following crtc6845 and timer8253:
  -- the strobe is held low for several CLK edges and the 0x3C0 flip-flop must
  -- toggle ONCE per write. Sampling the level would flip it several times per
  -- access and land every other value in the wrong register -- and it would do
  -- so at a rate that depends on the bus clock, so it would look like a
  -- frequency problem rather than a design one.
  ----------------------------------------------------------------------------
  PROCESS (CLK)
    VARIABLE wr_rise : std_logic;
    VARIABLE rd_rise : std_logic;
  BEGIN
    IF rising_edge(CLK) THEN
      wr_prev <= wr_act;
      rd_prev <= rd_act;
      wr_rise := wr_act AND NOT wr_prev;
      rd_rise := rd_act AND NOT rd_prev;

      -- Reading the status port resets the attribute controller's flip-flop.
      -- Observed, not answered: cga_status drives 0x3DA's data.
      IF (rd_rise = '1' AND ADDR = x"03DA") THEN
        ac_ff <= '0';
      END IF;

      IF wr_rise = '1' THEN
        CASE ADDR IS

          WHEN x"03C4" => seq_idx <= unsigned(DATA(2 DOWNTO 0));
          WHEN x"03C5" => seq(to_integer(seq_idx)) <= DATA;

          WHEN x"03CE" => gc_idx  <= unsigned(DATA(3 DOWNTO 0));
          WHEN x"03CF" => gc(to_integer(gc_idx)) <= DATA;

          -- One port, two meanings, alternating.
          WHEN x"03C0" =>
            IF ac_ff = '0' THEN
              ac_idx <= unsigned(DATA(4 DOWNTO 0));
              ac_ff  <= '1';
            ELSE
              -- Indices 0..15 are the palette; 16..31 are mode/overscan and
              -- are accepted and dropped. Mode 0Dh needs none of them, and
              -- storing them would imply they do something.
              IF ac_idx < 16 THEN
                pal(to_integer(ac_idx(3 DOWNTO 0))) <= DATA(5 DOWNTO 0);
              END IF;
              ac_ff <= '0';
            END IF;

          WHEN OTHERS => NULL;
        END CASE;
      END IF;
    END IF;
  END PROCESS;

END behavior;
