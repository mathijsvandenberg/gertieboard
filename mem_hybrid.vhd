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
USE  work.memmap.ALL;
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
        MEM_READY : OUT std_logic;   -- PSRAM init complete; gates the CPU reset
        CTRL    : IN    std_logic_vector(7  DOWNTO 0);       -- PSRAM runtime tuning
        RAM_SCK : OUT   std_logic;
        RAM_CS  : OUT   std_logic;
        RAM_SIO : INOUT std_logic_vector(3 DOWNTO 0);
        -- SDRAM client (arbiter port 2), used when USE_SDRAM_RAM is TRUE. Tied
        -- off by this file when it is not, so the top level wires them either way.
        SD_REQ  : OUT   std_logic;
        SD_LOCK : OUT   std_logic;
        SD_WE   : OUT   std_logic;
        SD_ADDR : OUT   std_logic_vector(23 DOWNTO 0);
        SD_DIN  : OUT   std_logic_vector(15 DOWNTO 0);
        SD_BE   : OUT   std_logic_vector(1 DOWNTO 0);
        SD_DOUT : IN    std_logic_vector(15 DOWNTO 0);
        SD_ACK  : IN    std_logic;
        SD_INIT : IN    std_logic);      -- sdram_ctrl's INIT_DONE
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
          INIT_DONE : OUT std_logic;
          CTRL    : IN  std_logic_vector(7 DOWNTO 0);
          RAM_SCK : OUT std_logic; RAM_CS : OUT std_logic;
          RAM_SIO : INOUT std_logic_vector(3 DOWNTO 0));
  END COMPONENT;

  COMPONENT sdram_mem
    PORT( CLK_RAM : IN  std_logic; RESET : IN std_logic;
          DATAIN  : IN  std_logic_vector(7 DOWNTO 0);
          ADDR    : IN  std_logic_vector(19 DOWNTO 0);
          RD, WR  : IN  std_logic;
          DATAOUT : INOUT std_logic_vector(7 DOWNTO 0);
          READY   : OUT std_logic;
          SD_REQ  : OUT std_logic; SD_LOCK : OUT std_logic; SD_WE : OUT std_logic;
          SD_ADDR : OUT std_logic_vector(23 DOWNTO 0);
          SD_DIN  : OUT std_logic_vector(15 DOWNTO 0);
          SD_BE   : OUT std_logic_vector(1 DOWNTO 0);
          SD_DOUT : IN  std_logic_vector(15 DOWNTO 0);
          SD_ACK  : IN  std_logic);
  END COMPONENT;

  SIGNAL ready_m9k : std_logic;
  SIGNAL ready_ps  : std_logic;

BEGIN

  -- THE 640 KB IS ONE KIND OF MEMORY, AND THE BIOS IS THE OTHER.
  --
  -- "PSRAM" below now means "whatever memmap.USE_SDRAM_RAM selects" -- the
  -- SDRAM, by default. The argument is unchanged by that and was never about
  -- the chip: what matters is that the whole 640 KB is ONE thing.
  --
  -- It used to be split: the low 32 KB in M9K and the rest of conventional RAM
  -- in PSRAM, with the BIOS in PSRAM too. That made the 640 KB a machine with
  -- two speeds, and where a program happened to land decided how fast it ran.
  -- Period software calibrates delay loops against itself, so the same game
  -- could time its music differently from one run to the next depending on
  -- nothing it could see. Uniform memory is worth more here than fast memory:
  -- a consistently slower machine is a machine you can reason about.
  --
  --   0x00000..0x9FFFF   PSRAM   all 640 KB, one speed throughout
  --   0xE0000..0xE0FFF   M9K     fixed-disk block buffer, invisible to DOS
  --   0xF0000..0xFBFFF   PSRAM   0xFF fill; BIOSFLSH reads the whole F-segment
  --   0xFC000..0xFFFFF   M9K     the BIOS image -- 16 KB, zero wait states
  --
  -- The BIOS in M9K is the other half of the point. Every INT 10h, INT 13h and
  -- INT 16h runs there, so interrupt service stops paying PSRAM latency, and
  -- there is now a defined region whose timing does not depend on a cache.
  --
  -- This also FREES M9K: 16 KB of BIOS plus 4 KB of buffer against the 36 KB
  -- the old split used.
  -- (The region test itself is no longer needed here -- see READY below.)

  u_m9k : m9k_mem
    PORT MAP( CLK_RAM => CLK_RAM, RESET => RESET, DATAIN => DATAIN, ADDR => ADDR,
              RD => RD, WR => WR, DATAOUT => DATAOUT, READY => ready_m9k );

  ----------------------------------------------------------------------------
  -- WHICH CHIP BACKS IT. memmap.USE_SDRAM_RAM picks, and because it is a
  -- CONSTANT only one of these is elaborated -- the other costs nothing, is not
  -- placed, and does not appear in timing. Both are kept in the tree so that
  -- reverting is a one-line edit to memmap and a rebuild, not a merge.
  --
  -- Whichever is chosen, it presents the same CPU-side interface and claims the
  -- same addresses (owned_by_cpuram), so nothing outside this generate can tell
  -- them apart. Exactly one drives DATAOUT and ready_ps, so there is no
  -- contention to reason about.
  ----------------------------------------------------------------------------
  use_sdram : IF USE_SDRAM_RAM GENERATE
    u_sdram : sdram_mem
      PORT MAP( CLK_RAM => CLK_RAM, RESET => RESET, DATAIN => DATAIN, ADDR => ADDR,
                RD => RD, WR => WR, DATAOUT => DATAOUT, READY => ready_ps,
                SD_REQ => SD_REQ, SD_LOCK => SD_LOCK, SD_WE => SD_WE,
                SD_ADDR => SD_ADDR, SD_DIN => SD_DIN, SD_BE => SD_BE,
                SD_DOUT => SD_DOUT, SD_ACK => SD_ACK );

    -- The CPU reset is released when memory is usable. That used to mean the
    -- PSRAM's QPI init; now it means sdram_ctrl's power-on sequence, which the
    -- top level already had to run before the display could fetch anything.
    MEM_READY <= SD_INIT;

    -- The PSRAM is not driven in this configuration. CS HIGH is deselected --
    -- leaving it floating would let the part see whatever the pin settles to.
    RAM_SCK <= '0';
    RAM_CS  <= '1';
    RAM_SIO <= (OTHERS => 'Z');
  END GENERATE;

  use_psram : IF NOT USE_SDRAM_RAM GENERATE
    u_psram : psram_ctrl
      PORT MAP( CLK_RAM => CLK_RAM, RESET => RESET, DATAIN => DATAIN, ADDR => ADDR,
                RD => RD, WR => WR, DATAOUT => DATAOUT, READY => ready_ps,
                INIT_DONE => MEM_READY, CTRL => CTRL,
                RAM_SCK => RAM_SCK, RAM_CS => RAM_CS, RAM_SIO => RAM_SIO );

    SD_REQ  <= '0';                 -- invisible to the arbiter
    SD_LOCK <= '0';
    SD_WE   <= '0';
    SD_ADDR <= (OTHERS => '0');
    SD_DIN  <= (OTHERS => '0');
    SD_BE   <= "11";
  END GENERATE;

  -- READY: AND, NOT A MUX -- and the reason is timing, not taste.
  --
  -- This used to select by region: READY <= ready_ps WHEN sel_ps='1' ELSE
  -- ready_m9k. That put a full 20-bit memory-map decode in the combinational
  -- path to the CPU's READY pin, and READY has the tightest external
  -- requirement in the machine -- the V20 wants it settled 8 ns after the clock
  -- falls (tSRYLK) and it was arriving 14 ns after. It had never been measured
  -- because the pin was false-pathed.
  --
  -- The decode was never needed. Each sub-block already answers '1' whenever
  -- its own region is not the one being addressed -- both gate their busy
  -- condition on their own ownership test and idle at ready_int='1' -- so
  -- whichever one is working pulls the line down and the other cannot mask it:
  --
  --     SDRAM region   ready_ps low while it works, ready_m9k idle '1'
  --     M9K region     ready_m9k low while it works, ready_ps  idle '1'
  --     unbacked       both '1', READY immediately -- same as the mux gave
  --
  -- So the answer is identical for every address, and the address decode leaves
  -- the READY path entirely: no register, no stale-select window, and not one
  -- extra wait state.
  READY <= ready_ps AND ready_m9k;

END struct;
