--------------------------------------------------------------------------------
-- mem_hybrid.vhd  --  drop-in replacement for the single RAM block
--
-- Splits the memory map across reliable M9K and PSRAM:
--   M9K   : 0x00000..0x07FFF (low RAM: IVT, BDA, stack)
--           0xE0000..0xE0FFF (4 KB fixed-disk block buffer, invisible to DOS)
--   PSRAM : 0x08000..0x9FFFF (conventional RAM)  +  0xF0000..0xFFFFF (64 KB BIOS)
--
-- The low RAM stays in M9K so the stack/IVT are rock-solid; the full 64 KB
-- F-segment is PSRAM-backed (no mirroring), populated by the 64 KB bootloader.
--
-- External interface matches the old RAM block plus a CTRL input. Wire CTRL to
-- DIP switches for the fastest loop (flip + press reset), or to an I/O-write
-- latch if you want the CPU to set it.
--
-- Both sub-blocks tri-state DATAOUT off-range, so their outputs share the bus;
-- their address ranges are disjoint so there is never contention. READY is muxed
-- by the decode.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;

ENTITY mem_hybrid IS
  PORT(
        CLK_RAM : IN    std_logic;
        RESET   : IN    std_logic;
        DATAIN  : IN    std_logic_vector(7  DOWNTO 0);
        ADDR    : IN    std_logic_vector(19 DOWNTO 0);
        RD      : IN    std_logic;                          -- /MEMR (active LOW)
        WR      : IN    std_logic;                          -- /MEMW (active LOW)
        DATAOUT : INOUT std_logic_vector(7  DOWNTO 0);
        READY   : OUT   std_logic;
        CTRL    : IN    std_logic_vector(7  DOWNTO 0);       -- PSRAM runtime tuning
        RAM_SCK : OUT   std_logic;
        RAM_CS  : OUT   std_logic;
        RAM_SIO : INOUT std_logic_vector(3 DOWNTO 0));
END mem_hybrid;

ARCHITECTURE struct OF mem_hybrid IS

  COMPONENT m9k_mem
    PORT( CLK_RAM : IN  std_logic; RESET : IN std_logic;
          DATAIN  : IN  std_logic_vector(7 DOWNTO 0);
          ADDR    : IN  std_logic_vector(19 DOWNTO 0);
          RD, WR  : IN  std_logic;
          DATAOUT : INOUT std_logic_vector(7 DOWNTO 0);
          READY   : OUT std_logic);
  END COMPONENT;

  COMPONENT psram_ctrl
    PORT( CLK_RAM : IN  std_logic; RESET : IN std_logic;
          DATAIN  : IN  std_logic_vector(7 DOWNTO 0);
          ADDR    : IN  std_logic_vector(19 DOWNTO 0);
          RD, WR  : IN  std_logic;
          DATAOUT : INOUT std_logic_vector(7 DOWNTO 0);
          READY   : OUT std_logic;
          CTRL    : IN  std_logic_vector(7 DOWNTO 0);
          RAM_SCK : OUT std_logic; RAM_CS : OUT std_logic;
          RAM_SIO : INOUT std_logic_vector(3 DOWNTO 0));
  END COMPONENT;

  SIGNAL ready_m9k : std_logic;
  SIGNAL ready_ps  : std_logic;
  SIGNAL sel_ps    : std_logic;

BEGIN

  -- PSRAM owns conventional RAM 0x08000..0x9FFFF AND the 64 KB F-segment BIOS
  -- 0xF0000..0xFFFFF; M9K owns the low 32 KB (0x00000..0x07FFF) plus the 4 KB
  -- disk buffer at 0xE0000. Note 0xE0000..0xE0FFF falls through to M9K here
  -- because sel_ps only claims 0xF0000 and above -- do not widen it to 0xE0000.
  sel_ps <= '1' WHEN ((ADDR >= x"08000") AND (ADDR < x"A0000"))
                  OR  (ADDR >= x"F0000")
            ELSE '0';

  u_m9k : m9k_mem
    PORT MAP( CLK_RAM => CLK_RAM, RESET => RESET, DATAIN => DATAIN, ADDR => ADDR,
              RD => RD, WR => WR, DATAOUT => DATAOUT, READY => ready_m9k );

  u_psram : psram_ctrl
    PORT MAP( CLK_RAM => CLK_RAM, RESET => RESET, DATAIN => DATAIN, ADDR => ADDR,
              RD => RD, WR => WR, DATAOUT => DATAOUT, READY => ready_ps, CTRL => CTRL,
              RAM_SCK => RAM_SCK, RAM_CS => RAM_CS, RAM_SIO => RAM_SIO );

  -- mux READY by the active region (both are '1' when their region is idle)
  READY <= ready_ps WHEN sel_ps = '1' ELSE ready_m9k;

END struct;
