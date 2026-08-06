LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  work.memmap.ALL;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;

--------------------------------------------------------------------------------
-- busdecode.vhd  --  CPU bus decode + DMA bus arbitration
--
-- Normal operation is exactly as before: latch the address on ALE, generate
-- combinational IO/MEM strobes, drive the READY handshake.
--
-- When the 8237 owns the bus (HLDA = '1') the memory path is switched over to
-- the DMA engine:
--     MEM_ADDR <= page(19:16) & DMA_ADDR(15:0)
--     MEM_RD/MEM_WR  <= DMA_MEMR/DMA_MEMW
--     DATA_OUT (-> RAM datain) <= DMA_DOUT   (the byte the FDC is sending to RAM)
-- The reverse direction (RAM read data -> FDC) is wired straight from the RAM's
-- DATAOUT to the FDC's DMA_DIN at the top level, so it doesn't pass through here.
--
-- The DMA page register (the XT's separate 74LS612) lives here: an I/O write to
-- 0x81 loads channel-2's page (address bits 19:16). Without it the BIOS's 20-bit
-- buffer address would be truncated to 64 KB.
--------------------------------------------------------------------------------

ENTITY busdecode IS
  PORT(
        -- Common
		  CLK				: IN std_logic;
        AD          : INOUT std_logic_vector(7 DOWNTO 0);
        A  	              : IN std_logic_vector(19 DOWNTO 8);
		  RD	              : IN std_logic;
        WR	           	  : IN std_logic;
        ALE		           : IN std_logic;
        DEN 	           : IN std_logic;
		  DTR 	           : IN std_logic;
		  IOM 	           : IN std_logic;
		  RAM_READY			  : IN std_logic;

		  DATA_IN		: IN std_logic_vector(7 DOWNTO 0);
		  DATA_OUT		: OUT std_logic_vector(7 DOWNTO 0);

		  IO_ADDR		: OUT std_logic_vector(15 DOWNTO 0);
		  EGA_CLAIM		: IN std_logic;   -- vga owns this address and is not ready
		  IO_RD			: OUT std_logic;
		  IO_WR			: OUT std_logic;
		  MEM_ADDR		: OUT std_logic_vector(19 DOWNTO 0);
		  MEM_RD			: OUT std_logic;
		  MEM_WR			: OUT std_logic;
		  READY			: OUT std_logic;

		  -- DMA arbitration (from 8237 / FDC)
		  HLDA			: IN std_logic;                         -- bus granted to DMA
		  DMA_ADDR		: IN std_logic_vector(15 DOWNTO 0);     -- 8237 current address
		  DMA_MEMR		: IN std_logic;                         -- active LOW
		  DMA_MEMW		: IN std_logic;                         -- active LOW
		  DMA_DOUT		: IN std_logic_vector(7 DOWNTO 0);      -- FDC byte -> RAM

		  -- Boot ROM overlay (from bootrom)
		  ROM_EN			: IN std_logic;                         -- '1' = overlay active
		  ROM_DATA		: IN std_logic_vector(7 DOWNTO 0));     -- boot ROM byte at MEM_ADDR(7:0)


   END busdecode;

ARCHITECTURE behavior OF busdecode IS

SIGNAL T : INTEGER RANGE 0 TO 1023;
SIGNAL ADDR : STD_LOGIC_VECTOR(19 DOWNTO 0);
SIGNAL MEMADDR : boolean;
SIGNAL MEMADDR2 : boolean;

-- latched CPU views (driven to the outputs through the DMA mux)
SIGNAL maddr_l  : STD_LOGIC_VECTOR(19 DOWNTO 0);
SIGNAL ioaddr_l : STD_LOGIC_VECTOR(15 DOWNTO 0);

-- DMA page register (channel 2 = port 0x81)
SIGNAL dma_page : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
SIGNAL wr_prev  : STD_LOGIC := '1';

-- Boot ROM overlay: active for a memory read in 0xFFF00..0xFFFFF while ROM_EN=1
SIGNAL in_overlay : STD_LOGIC;

BEGIN


	PROCESS (CLK)
	BEGIN
	IF (rising_edge(CLK)) THEN
		wr_prev <= WR;

		IF (ALE = '1' AND IOM = '0') THEN
			T <= 1;
			ioaddr_l <= x"FFFF"; -- Bogus, make sure it does not match any logic address
			maddr_l  <= A(19 DOWNTO 8) & AD(7 DOWNTO 0);
			ADDR     <= A(19 DOWNTO 8) & AD(7 DOWNTO 0);
		ELSIF (ALE = '1' AND IOM = '1') THEN
			T <= 1;
			ioaddr_l <= A(15 DOWNTO 8) & AD(7 DOWNTO 0);
			maddr_l  <= x"FFFFF";
			ADDR     <= "0000" & A(15 DOWNTO 8) & AD(7 DOWNTO 0);
		ELSE
			T <= T + 1;
		END IF;

		-- DMA page register: I/O write to 0x81 (ch2). ADDR holds the latched
		-- I/O address; AD carries the data byte during the data phase.
		IF (wr_prev = '0' AND WR = '1' AND IOM = '1' AND ADDR(15 DOWNTO 0) = x"0081") THEN
			dma_page <= AD(3 DOWNTO 0);
		END IF;
	END IF;
	END PROCESS;

	-- ---- Address / strobe outputs: CPU normally, 8237 during HLDA ----
	MEM_ADDR <= (dma_page & DMA_ADDR) WHEN HLDA = '1' ELSE maddr_l;
	IO_ADDR  <= ioaddr_l;

	IO_RD <=  NOT(NOT RD AND IOM);
	IO_WR <=  NOT(NOT WR AND IOM);

	MEM_RD <= DMA_MEMR WHEN HLDA = '1' ELSE NOT(NOT RD AND NOT IOM);
	MEM_WR <= DMA_MEMW WHEN HLDA = '1' ELSE NOT(NOT WR AND NOT IOM);

	-- ---- Data routing ----
	-- To RAM datain: the FDC's DMA byte during HLDA, else the CPU write data.
	DATA_OUT <= DMA_DOUT                WHEN HLDA = '1'
	       ELSE AD(7 DOWNTO 0)          WHEN (DTR = '1' AND DEN = '0')
	       ELSE "00000000";

	-- ---- Boot ROM overlay ----
	-- During reset (ROM_EN=1) a memory read of 0xFFF00..0xFFFFF returns the boot
	-- ROM instead of PSRAM. WRITES are unaffected -> they pass through to PSRAM,
	-- so the bootloader can fill the BIOS image underneath the overlay.
	-- 1 KB window 0xFFC00..0xFFFFF (was 256 bytes at 0xFFF00). Keep this in
	-- step with the rom_t size in bootrom.vhd.
	in_overlay <= '1' WHEN (ROM_EN = '1' AND IOM = '0'
	                        AND maddr_l(19 DOWNTO 10) = "1111111111")
	         ELSE '0';

	-- Drive read data back to the CPU only when the CPU owns the bus.
	-- Boot ROM wins over PSRAM data for the overlay window.
	AD <= ROM_DATA WHEN (HLDA = '0' AND DTR = '0' AND DEN = '0' AND in_overlay = '1')
	 ELSE DATA_IN  WHEN (HLDA = '0' AND DTR = '0' AND DEN = '0')
	 ELSE "ZZZZZZZZ";

	-- Memory cycles are governed by RAM_READY. The T-based clause is only a
	-- backstop against a wedged memory controller, so it must be LONGER than the
	-- slowest legitimate access -- otherwise it releases the CPU early and the
	-- data bus is sampled before the PSRAM has driven it (silent corruption).
	-- It used to be T >= 10, which a 16-byte PSRAM cache-line fill (~18 CPU
	-- clocks at SCK_DIV=2) would trip on every miss.
	--
	-- THIS COUNTS CPU CLOCKS, so its duration halved when c0 went from 5 MHz to
	-- 10 MHz. 64 clocks was 12.8 us at 5 MHz and would be only 6.4 us at 10,
	-- against a worst case of 61 SCK cycles at SCK_DIV=2 (~4.9 us) -- still
	-- clear, but with a quarter of the margin it was designed with. 128 keeps
	-- the original 12.8 us. The PSRAM side is on c3 and did not get faster, so
	-- the absolute deadline it has to beat has not moved.
	READY <=  '1' WHEN (T >= 128 AND MEMADDR AND IOM = '0')
      ELSE '1' WHEN (MEMADDR AND IOM = '0' AND RAM_READY = '1')
      ELSE '1' WHEN (T >= 3 AND (NOT MEMADDR OR IOM = '1'))
      ELSE '0';


	--MEMADDR <= TRUE WHEN (ADDR > x"09FFF" AND ADDR < x"A0000") OR (ADDR > x"DFFFF" AND ADDR < x"F0000") ELSE FALSE;

	-- BIOS area (0xF0000..0xFFFFF) is now PSRAM as well, so treat it as memory.
	-- The EGA window is a memory cycle too, when EGA is on. It cannot go in
	-- memmap.vhd because it depends on the MODE and not only on the address:
	-- the same 0xA0000 is unclaimed in CGA modes, and claiming it there would
	-- send every access to the T >= 128 backstop -- 15 us apiece.
	MEMADDR <= (needs_ram_handshake(ADDR) = '1') OR (EGA_CLAIM = '1');



END;