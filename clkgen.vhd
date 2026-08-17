LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY clkgen IS
  PORT(
        -- Common
        CLK                : IN std_logic;
        RESET              : IN std_logic;
        -- "main memory exists": psram_ctrl's INIT_DONE, via mem_hybrid.
        MEM_READY          : IN std_logic;
        RST_OUT            : OUT std_logic);
	  		  	
   END clkgen;
	
ARCHITECTURE behavior OF clkgen IS

SIGNAL CNT : INTEGER RANGE 0 TO 16 := 0;

-- SETTLING TIME AFTER MAIN MEMORY REPORTS READY.
--
-- MEM_READY says "the initialisation sequence has finished", which is not the
-- same claim as "the next access will work". Until now RST_OUT dropped on the
-- clock immediately after mr_sync went high, so the CPU's very first fetch
-- raced the first cycle the controller had ever run for real.
--
-- The failure that motivates this: on a cold boot the loader's memory probe
-- reports ~28 of 256 bytes wrong, CLUSTERED IN THE FIRST HALF of the block and
-- reading back 00 -- early writes lost, later ones fine. That is the shape of
-- memory that is not quite awake yet, not of memory that is broken.
--
-- 8192 bus clocks is about 1 ms at the 8.333 MHz boot step. Invisible: the
-- FPGA spends the best part of a second configuring from EPCS before any of
-- this runs. Deliberately generous rather than minimal -- if it turns out to
-- be the fix, the interesting number is which value stops working, and that
-- is a later experiment.
CONSTANT SETTLE_N : INTEGER := 8192;
SIGNAL SETTLE : INTEGER RANGE 0 TO SETTLE_N := 0;

-- MEM_READY crosses from c3 (50 MHz) into this c0 domain. It is a level that
-- rises once and stays, so two flops are enough and metastability cannot do
-- worse than delay the release of reset by one clock.
SIGNAL mr_sync : std_logic_vector(1 DOWNTO 0) := "00";

BEGIN
	-- THE CPU IS HELD UNTIL MAIN MEMORY ANSWERS.
	--
	-- The ten-clock stretch alone is about 1.6 us, while psram_ctrl spends
	-- ~200 us on its QPI init sequence before a single access can succeed. The
	-- CPU therefore used to start running long before its memory existed. That
	-- was survivable only by accident: the boot loader's stack and trampoline
	-- happened to sit in low RAM, which was M9K and available immediately. The
	-- moment conventional memory became uniformly PSRAM the loader stopped
	-- working, because it was setting up a stack in memory that was not there
	-- yet.
	--
	-- Waiting on READY would not have covered it either: busdecode's T >= 128
	-- backstop fires after ~20 us and releases the CPU with undriven bus data,
	-- ten times over, before init has finished. A backstop is for a wedged
	-- controller, not for a controller that has not started.
	PROCESS (RESET,CLK)
	BEGIN
		IF (rising_edge(CLK)) THEN
			mr_sync <= mr_sync(0) & MEM_READY;
			IF (RESET = '0') THEN
				CNT <= 0;
				SETTLE <= 0;
				RST_OUT <= '1';
			ELSIF (CNT < 10) THEN
				RST_OUT <= '1';
				CNT <= CNT + 1;
			ELSIF (mr_sync(1) = '0') THEN
				RST_OUT <= '1';          -- memory is not up yet
				SETTLE <= 0;             -- and has not started settling either
			ELSIF (SETTLE < SETTLE_N) THEN
				RST_OUT <= '1';          -- up, but give it a moment before the
				SETTLE <= SETTLE + 1;    -- first fetch races the first access
			ELSE
				RST_OUT <= '0';
			END IF;
		END IF;
	END PROCESS;
END;	
	
