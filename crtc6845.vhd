--------------------------------------------------------------------------------
-- crtc6845.vhd  --  the 6845 register file at I/O 0x3D4/0x3D5
--
-- vga.vhd generates fixed timing and ignores every CRTC access, which is fine
-- for making a picture and fatal for being FOUND. The standard way to detect a
-- CGA card is not to look at the picture -- it is to write a value into a CRTC
-- register and read it back:
--
--     out 3D4h, 0Fh        select R15, cursor address low
--     in  al, 3D5h         save what is there
--     out 3D5h, 66h        write a test pattern
--     in  al, 3D5h         does the chip remember it?
--
-- With nothing answering 0x3D5 the read returns open-bus 0xFF, the pattern
-- never comes back, and the program concludes there is no graphics card and
-- refuses to start -- on a machine that is displaying its refusal perfectly.
-- Prince of Persia does exactly this.
--
-- So this is the register file, and only the register file. It does not change
-- the timing and it does not touch vga.vhd. What it does is make the card
-- answer for itself.
--
-- ---------------------------------------------------------------------------
-- READ SEMANTICS -- the part that has to match real hardware
--
-- On an MC6845 most registers are write-only. Reading them back returns ZERO,
-- not the value written and not 0xFF:
--
--     R0-R13    write only          read as 0
--     R14/R15   cursor address      readable  (R14 is 6 bits, R15 is 8)
--     R16/R17   light pen           read only, and 0 here since there is none
--
-- That asymmetry is not a limitation to work around, it is the signature
-- detection code looks for. A register file that helpfully echoed all eighteen
-- registers would look less like a 6845 than this one does. R14's top two bits
-- reading back as zero is likewise real: code that writes 0x66 there and
-- expects 0x66 is wrong on genuine hardware too.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS OPENS UP
--
-- START and CURSOR come out as ports even though nothing consumes them yet.
-- They are the two things vga.vhd would need to grow next:
--
--     START (R12/R13)   display start address -- hardware scrolling. Keen 4
--                       scrolls its levels by moving this, which is why it
--                       would still scroll wrongly even once it starts
--     CURSOR (R14/R15)  a real hardware text cursor, instead of none
--
-- Leave them OPEN in the top level until vga.vhd is ready for them. The BIOS
-- has been writing all four registers since day one -- see set_hw_cursor and
-- v_curtype in xtbios_src.s -- so the values arriving here are already correct
-- and already live.
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

ENTITY crtc6845 IS
  PORT(
        CLK     : IN    std_logic;
        DATA    : IN    std_logic_vector(7 DOWNTO 0);   -- CPU -> device
        ADDR    : IN    std_logic_vector(15 DOWNTO 0);  -- I/O address
        RD      : IN    std_logic;                      -- active LOW I/O read
        WR      : IN    std_logic;                      -- active LOW I/O write
        DATAOUT : INOUT std_logic_vector(7 DOWNTO 0);   -- 'Z' when not addressed
        START   : OUT   std_logic_vector(13 DOWNTO 0);  -- R12/R13, for vga.vhd
        CURSOR  : OUT   std_logic_vector(13 DOWNTO 0)); -- R14/R15, for vga.vhd
END crtc6845;

ARCHITECTURE behavior OF crtc6845 IS

  TYPE regfile_t IS ARRAY(0 TO 15) OF std_logic_vector(7 DOWNTO 0);

  -- Power-on values are the ones the XT BIOS writes for 80x25 text, so the
  -- outputs are sane before any software has touched them.
  SIGNAL reg : regfile_t := (OTHERS => (OTHERS => '0'));

  SIGNAL idx : unsigned(4 DOWNTO 0) := (OTHERS => '0');

  SIGNAL wr_act, wr_prev : std_logic := '0';

  SIGNAL rdval  : std_logic_vector(7 DOWNTO 0);
  SIGNAL sel_rd : std_logic;

BEGIN

  wr_act <= NOT WR;

  ----------------------------------------------------------------------------
  -- Read path. Only the cursor address and the light pen answer; everything
  -- else reads as zero, exactly as an MC6845 does.
  ----------------------------------------------------------------------------
  WITH to_integer(idx) SELECT rdval <=
      "00" & reg(14)(5 DOWNTO 0) WHEN 14,     -- cursor high, 6 bits wide
      reg(15)                    WHEN 15,     -- cursor low, all 8
      x"00"                      WHEN 16,     -- light pen high: none fitted
      x"00"                      WHEN 17,     -- light pen low
      x"00"                      WHEN OTHERS; -- write-only registers

  sel_rd  <= '1' WHEN (RD = '0' AND ADDR = x"03D5") ELSE '0';
  DATAOUT <= rdval WHEN sel_rd = '1' ELSE "ZZZZZZZZ";

  -- Straight out for vga.vhd to pick up when it is ready for them.
  START  <= reg(12)(5 DOWNTO 0) & reg(13);
  CURSOR <= reg(14)(5 DOWNTO 0) & reg(15);

  ----------------------------------------------------------------------------
  -- Write path. The index latch at 0x3D4, the data port at 0x3D5.
  --
  -- The edge detect follows timer8253's idiom rather than sampling the level:
  -- writes here are not idempotent in the way a display latch is, and a strobe
  -- held for several clocks must land once.
  ----------------------------------------------------------------------------
  PROCESS (CLK)
    VARIABLE wr_rise : std_logic;
  BEGIN
    IF rising_edge(CLK) THEN
      wr_prev <= wr_act;
      wr_rise := wr_act AND NOT wr_prev;

      IF wr_rise = '1' THEN
        IF ADDR = x"03D4" THEN
          idx <= unsigned(DATA(4 DOWNTO 0));  -- 6845 has 18 registers
        ELSIF ADDR = x"03D5" THEN
          -- R16/R17 are the light pen and are read-only on real silicon, so a
          -- write to them is accepted and dropped rather than stored.
          IF idx < 16 THEN
            reg(to_integer(idx)) <= DATA;
          END IF;
        END IF;
      END IF;
    END IF;
  END PROCESS;

END behavior;
