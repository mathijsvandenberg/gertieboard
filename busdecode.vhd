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
		  DMA_CH		: IN std_logic_vector(1 DOWNTO 0) := "10";  -- which channel owns it
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
SIGNAL memaddr_q : boolean := FALSE;   -- registered address half of MEMADDR
SIGNAL MEMADDR2 : boolean;

-- latched CPU views (driven to the outputs through the DMA mux)
SIGNAL maddr_l  : STD_LOGIC_VECTOR(19 DOWNTO 0);
SIGNAL ioaddr_l : STD_LOGIC_VECTOR(15 DOWNTO 0);

-- DMA PAGE REGISTERS, ONE PER CHANNEL. Four nibbles in one vector, which is
-- also how the timing constraints refer to them.
--
-- This used to be a single register loaded only from port 0x81, channel 2's,
-- because the floppy was the only device doing DMA. A second device on another
-- channel then reads from whatever page the floppy driver last set: the
-- transfer completes, the count reaches zero, and the bytes come from a random
-- 64 KB of memory. The Sound Blaster read a different wrong page on every boot.
--
--   0x87 = ch0    0x83 = ch1    0x81 = ch2    0x82 = ch3
SIGNAL dma_page : STD_LOGIC_VECTOR(15 DOWNTO 0) := (OTHERS => '0');
SIGNAL page_sel : STD_LOGIC_VECTOR(3 DOWNTO 0) := (OTHERS => '0');
SIGNAL wr_prev  : STD_LOGIC := '1';

-- Boot ROM overlay: active for a memory read in 0xFFF00..0xFFFFF while ROM_EN=1
SIGNAL in_overlay : STD_LOGIC;

BEGIN


	PROCESS (CLK)
	BEGIN
	IF (rising_edge(CLK)) THEN
		wr_prev <= WR;

		-- memaddr_q is the address half of MEMADDR, decoded HERE rather than in
		-- the expression that drives READY. It is computed from the address
		-- arriving on the pins, not from the latched copy, so it lands on the
		-- SAME edge that latches ADDR -- one clock earlier than registering the
		-- old expression would have managed, and therefore free.
		--
		-- Why bother: needs_ram_handshake is a 20-bit range decode, and it sat
		-- in the combinational path to CPU_RDY, which has the tightest external
		-- requirement on the board (V20 tSRYLK: settled 8 ns after CLK falls).
		-- Moving it here puts it on the ALE path instead, which has a whole bus
		-- cycle of slack and nothing waiting on it.
		IF (ALE = '1' AND IOM = '0') THEN
			T <= 1;
			ioaddr_l <= x"FFFF"; -- Bogus, make sure it does not match any logic address
			maddr_l  <= A(19 DOWNTO 8) & AD(7 DOWNTO 0);
			ADDR     <= A(19 DOWNTO 8) & AD(7 DOWNTO 0);
			memaddr_q <= needs_ram_handshake(A(19 DOWNTO 8) & AD(7 DOWNTO 0)) = '1';
		ELSIF (ALE = '1' AND IOM = '1') THEN
			T <= 1;
			ioaddr_l <= A(15 DOWNTO 8) & AD(7 DOWNTO 0);
			maddr_l  <= x"FFFFF";
			ADDR     <= "0000" & A(15 DOWNTO 8) & AD(7 DOWNTO 0);
			-- I/O cycles land in the low 64 KB of the 20-bit space, where
			-- needs_ram_handshake answers '1'. That was true of the old
			-- expression too and is harmless: every clause that reads MEMADDR
			-- also tests IOM, which is what actually separates the two.
			memaddr_q <= needs_ram_handshake("0000" & A(15 DOWNTO 8) & AD(7 DOWNTO 0)) = '1';
		ELSE
			T <= T + 1;
		END IF;

		-- DMA page register: I/O write to 0x81 (ch2). ADDR holds the latched
		-- I/O address; AD carries the data byte during the data phase.
		-- The page for whichever channel owns the bus, REGISTERED. As a
		-- combinational mux it sat in the memory address path, which is
		-- constrained, and cost 1.1 ns of slack. It does not need to be live:
		-- the 8237 fixes the channel in D_IDLE and does not touch memory until
		-- D_MEM, so a value one clock behind DMA_CH is already settled by the
		-- time the address matters.
		CASE DMA_CH IS
			WHEN "00"   => page_sel <= dma_page(3 DOWNTO 0);
			WHEN "01"   => page_sel <= dma_page(7 DOWNTO 4);
			WHEN "10"   => page_sel <= dma_page(11 DOWNTO 8);
			WHEN OTHERS => page_sel <= dma_page(15 DOWNTO 12);
		END CASE;

		IF (wr_prev = '0' AND WR = '1' AND IOM = '1') THEN
			CASE ADDR(15 DOWNTO 0) IS
				WHEN x"0087" => dma_page(3 DOWNTO 0)   <= AD(3 DOWNTO 0);
				WHEN x"0083" => dma_page(7 DOWNTO 4)   <= AD(3 DOWNTO 0);
				WHEN x"0081" => dma_page(11 DOWNTO 8)  <= AD(3 DOWNTO 0);
				WHEN x"0082" => dma_page(15 DOWNTO 12) <= AD(3 DOWNTO 0);
				WHEN OTHERS  => NULL;
			END CASE;
		END IF;
	END IF;
	END PROCESS;

	-- ---- Address / strobe outputs: CPU normally, 8237 during HLDA ----
	MEM_ADDR <= (page_sel & DMA_ADDR) WHEN HLDA = '1' ELSE maddr_l;
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
	-- 2 KB window 0xFF800..0xFFFFF (was 1 KB at 0xFFC00, and 256 bytes at
	-- 0xFFF00 before that). Keep this in step with the rom_t size in
	-- bootrom.vhd AND the ORG in tools/bootldr_64k.asm -- three places, and
	-- nothing checks that they agree.
	--
	-- Widened to make room for the loader's beep codes: it had 11 bytes free.
	-- NOTE this shadows READS of 0xFF800..0xFFFFF while ROM_EN is set, so the
	-- loader cannot inspect what it just wrote there -- see the reset-vector
	-- check in bootldr_64k.asm, which was reading the boot ROM's own vector
	-- and passing unconditionally.
	in_overlay <= '1' WHEN (ROM_EN = '1' AND IOM = '0'
	                        AND maddr_l(19 DOWNTO 11) = "111111111")
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
	--
	-- 256 since the bus clock became selectable (cpuclk.vhd): the count has to
	-- be safe at the FASTEST step, and 128 clocks at 16.667 MHz is 7.7 us --
	-- 1.6x the worst legitimate access, where it was designed with 2.6x. 256 is
	-- 15.4 us there. At 5 MHz it is 51 us, which costs nothing: this is a
	-- deadlock breaker for a wedged controller, not a timeout anything waits on
	-- in normal operation.
	READY <=  '1' WHEN (T >= 256 AND MEMADDR AND IOM = '0')
      ELSE '1' WHEN (MEMADDR AND IOM = '0' AND RAM_READY = '1')
      ELSE '1' WHEN (T >= 3 AND (NOT MEMADDR OR IOM = '1'))
      ELSE '0';


	--MEMADDR <= TRUE WHEN (ADDR > x"09FFF" AND ADDR < x"A0000") OR (ADDR > x"DFFFF" AND ADDR < x"F0000") ELSE FALSE;

	-- BIOS area (0xF0000..0xFFFFF) is now PSRAM as well, so treat it as memory.
	-- The EGA window is a memory cycle too, when EGA is on. It cannot go in
	-- memmap.vhd because it depends on the MODE and not only on the address:
	-- the same 0xA0000 is unclaimed in CGA modes, and claiming it there would
	-- send every access to the T >= 128 backstop -- 15 us apiece.
	-- The address decode is now registered (memaddr_q, above). EGA_CLAIM stays
	-- combinational: it depends on the video MODE as well as the address, so it
	-- is not known at the ALE edge, and it is a far shorter path than the range
	-- decode that used to be here.
	MEMADDR <= memaddr_q OR (EGA_CLAIM = '1');



END;