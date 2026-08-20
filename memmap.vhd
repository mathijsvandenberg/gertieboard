--------------------------------------------------------------------------------
-- memmap.vhd  --  the memory map, in ONE place
--
-- Four modules need to agree about which addresses belong to whom:
--
--     mem_hybrid   routes the access to a controller
--     psram_ctrl   decides whether the access is its business
--     m9k_mem      decides the same, for its two windows
--     busdecode    decides whether to wait on RAM_READY at all
--
-- They used to answer that question independently, in four hand-written
-- expressions. Changing one of them is how the boot loader came to hang at POST
-- code 02: mem_hybrid had been taught that low memory was PSRAM, psram_ctrl had
-- not, so the first stack push was routed to a controller that did not claim the
-- address. Nothing drove READY and the CPU stopped on 0x7C00 -- an address that
-- looks entirely ordinary. There was no error and there could not be one, and
-- finding it meant reasoning about which instruction was the first to touch the
-- stack.
--
-- So the boundaries live here and the modules ask rather than restate. A change
-- to the map is now a change to one file.
--
-- THE MAP
--
--     0x00000..0x9FFFF   PSRAM    all 640 KB of conventional memory, ONE speed
--     0xA0000..0xDFFFF   nothing  EGA window and the CGA framebuffer, which
--                                 vga.vhd answers for itself
--     0xE0000..0xE0FFF   M9K      fixed-disk block buffer, invisible to DOS
--     0xE1000..0xEFFFF   nothing
--     0xF0000..0xFBFFF   PSRAM    0xFF fill. Kept backed because BIOSFLSH reads
--                                 the whole 64 KB F-segment when copying the
--                                 BIOS to flash
--     0xFC000..0xFFFFF   M9K      the BIOS image, 16 KB, zero wait states
--
-- Conventional memory is deliberately uniform. It used to be split -- low 32 KB
-- on-chip, the rest serial -- which made the 640 KB a machine with two speeds,
-- where a program's timing depended on where DOS happened to load it. Software
-- of this era calibrates delay loops against itself, so that is not a detail.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;
USE  IEEE.STD_LOGIC_UNSIGNED.ALL;

PACKAGE memmap IS

  -- Boundaries. Every one of them is used at least twice below, which is the
  -- point: they cannot drift apart any more.
  CONSTANT CONV_END : std_logic_vector(19 DOWNTO 0) := x"A0000";  -- 640 KB ends
  CONSTANT BUF_BASE : std_logic_vector(19 DOWNTO 0) := x"E0000";  -- disk buffer
  CONSTANT BUF_END  : std_logic_vector(19 DOWNTO 0) := x"E1000";
  CONSTANT FSEG_BASE: std_logic_vector(19 DOWNTO 0) := x"F0000";  -- F-segment
  -- 24 KB, grown from 16. The BIOS ran out of room: .text had reached
  -- .rtdata with the USB floppy driver in it, and the only space left was
  -- 386 bytes above the font. M9K is what backs this, and the part had
  -- room -- see m9k_mem for the cost.
  CONSTANT BIOS_BASE: std_logic_vector(19 DOWNTO 0) := x"FA000";  -- BIOS image

  -- WHICH CHIP BACKS CONVENTIONAL MEMORY.
  --
  -- Not strictly part of the map -- the map says which addresses are RAM, not
  -- what kind of RAM -- but this is the file every module already asks, so it is
  -- where a switch can be read by all of them without new dependencies.
  --
  -- FALSE is the QPI PSRAM on the top board. It works from a warm reset and
  -- fails from a cold one: the probe finds all 256 test bytes wrong and reads
  -- return nothing, which is the part not having entered QPI mode. Init clock
  -- rate, the clock edge data is placed on, chip select at power-up and PLL lock
  -- gating were each fixed in turn, and a reflow was done; the count went 208,
  -- 252, 254, 255 -- worsening with time on the bench, not with the changes.
  -- Warming the PSRAM makes it worse and warming the FPGA makes it better, so
  -- whatever it is, it is analogue and it is over there.
  --
  -- TRUE is the DE0-Nano's SDRAM, which is already carrying the EGA bit planes
  -- through Keen 4, is verified across all 65536 plane offsets by EGAVFY, is
  -- factory-mounted, is 32 MB against 8, and is the only external interface on
  -- this board whose timing is actually constrained. It is also about twice as
  -- fast on a cache miss.
  --
  -- Flipping this back to FALSE and rebuilding is the whole revert.
  CONSTANT USE_SDRAM_RAM : boolean := TRUE;

  -- Who owns this address?
  --
  -- owned_by_cpuram is the region: 640 KB plus the backed part of the
  -- F-segment. owned_by_psram is the OLD NAME for the same question, kept so
  -- psram_ctrl.vhd -- the fallback -- needs no edit to stay working. It is an
  -- alias, not a copy, so the two cannot drift.
  FUNCTION owned_by_cpuram  (a : std_logic_vector(19 DOWNTO 0)) RETURN std_logic;
  FUNCTION owned_by_psram   (a : std_logic_vector(19 DOWNTO 0)) RETURN std_logic;
  FUNCTION owned_by_bios    (a : std_logic_vector(19 DOWNTO 0)) RETURN std_logic;
  FUNCTION owned_by_diskbuf (a : std_logic_vector(19 DOWNTO 0)) RETURN std_logic;

  -- Does a memory cycle here have to wait on RAM_READY?
  --
  -- Deliberately BROADER than the union of the three owners: it also covers
  -- 0xE1000..0xEFFFF, which nothing backs. That is the behaviour busdecode has
  -- always had, and it is kept bit-for-bit so introducing this package changes
  -- no logic. An unbacked address there falls to the T >= 128 backstop and
  -- returns rubbish, which is what it did before and is a fair answer for
  -- reading memory that is not there.
  FUNCTION needs_ram_handshake (a : std_logic_vector(19 DOWNTO 0)) RETURN std_logic;

END PACKAGE memmap;


PACKAGE BODY memmap IS

  -- The F-segment half is the complement of owned_by_bios within 0xF0000, and
  -- is spelled out in bits for the same reason: it shares the CPU_RDY path.
  --   0xF0000..0xF9FFF  =  a(19 DOWNTO 16) = "1111"  and NOT in the BIOS
  FUNCTION owned_by_cpuram (a : std_logic_vector(19 DOWNTO 0)) RETURN std_logic IS
  BEGIN
    IF a < CONV_END THEN
      RETURN '1';
    ELSIF (a(19 DOWNTO 16) = "1111")
      AND ((a(15) = '0') OR ((a(14) = '0') AND (a(13) = '0'))) THEN
      RETURN '1';
    ELSE
      RETURN '0';
    END IF;
  END FUNCTION;

  FUNCTION owned_by_psram (a : std_logic_vector(19 DOWNTO 0)) RETURN std_logic IS
  BEGIN
    RETURN owned_by_cpuram(a);
  END FUNCTION;

  -- WRITTEN AS BIT TESTS, NOT AS A COMPARISON, AND THAT IS THE WHOLE POINT.
  --
  -- 0xFC000 was a lucky boundary: "a >= 0xFC000" is just a(19 DOWNTO 14) all
  -- ones, six inputs and one gate. 0xFA000 is not, so the same expression
  -- became a real 20-bit magnitude comparator -- and this decode feeds
  -- CPU_RDY, whose whole budget is 10.35 ns from busdecode's latched address.
  -- Growing the BIOS to 24 KB cost -0.371 ns there and the build was refused.
  --
  -- The region is still expressible cheaply, just not as a comparison:
  -- 0xFA000..0xFFFFF is a(19 DOWNTO 15) = "11111" with the bottom quarter of
  -- that 32 KB window, where a(14 DOWNTO 13) = "00", taken back out.
  FUNCTION owned_by_bios (a : std_logic_vector(19 DOWNTO 0)) RETURN std_logic IS
  BEGIN
    IF (a(19 DOWNTO 15) = "11111") AND ((a(14) OR a(13)) = '1') THEN
      RETURN '1';
    ELSE
      RETURN '0';
    END IF;
  END FUNCTION;

  FUNCTION owned_by_diskbuf (a : std_logic_vector(19 DOWNTO 0)) RETURN std_logic IS
  BEGIN
    IF (a >= BUF_BASE) AND (a < BUF_END) THEN RETURN '1'; ELSE RETURN '0'; END IF;
  END FUNCTION;

  FUNCTION needs_ram_handshake (a : std_logic_vector(19 DOWNTO 0)) RETURN std_logic IS
  BEGIN
    IF (a < CONV_END) OR (a >= BUF_BASE) THEN RETURN '1'; ELSE RETURN '0'; END IF;
  END FUNCTION;

END PACKAGE BODY memmap;
