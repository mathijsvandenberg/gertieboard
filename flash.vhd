--------------------------------------------------------------------------------
-- flash.vhd  --  SPI controller for the on-board serial flash (IS25LP016D,
--                16 Mbit / 2 MByte), the fixed-disk backing store.
--
-- This replaces the original bit-banged interface, where port 0x98 drove SCK,
-- CS and MOSI one bit at a time: a single byte cost 16 I/O writes plus 8 reads,
-- so a 512-byte disk sector would have needed ~12000 bus cycles. Now the CPU
-- hands over a whole byte and the hardware clocks it out.
--
-- I/O map (the old bit-bang meaning of 0x98 is gone; nothing used it):
--
--   0x98  W  transmit byte -- writing STARTS an 8-bit exchange
--         R  the byte received during the last exchange
--   0x99  R  status, bit 7 = BUSY (exchange in progress), other bits 0
--   0x9A  W  bit 0 = /CS level:  0 = assert (chip selected), 1 = release
--
-- Usage is the ordinary SPI pattern -- assert /CS, exchange bytes (send 0xFF
-- when you only want to receive), release /CS. For example a JEDEC ID read:
--
--      OUT 0x9A,0     ; /CS low
--      OUT 0x98,0x9F  ; command    -> wait BUSY
--      OUT 0x98,0xFF  ; -> mfr     -> wait BUSY, IN 0x98
--      OUT 0x98,0xFF  ; -> type    ...
--      OUT 0x98,0xFF  ; -> capacity
--      OUT 0x9A,1     ; /CS high
--
-- SPI mode 0: SCK idles low, MOSI is presented while SCK is low, and MISO is
-- sampled at the end of the SCK-high phase. CLK here is the 10 MHz CPU bus clock
-- and one SCK period takes two CLK cycles, giving SCK = 5 MHz (1.6 us per
-- byte). That is far below what the IS25LP016D can do (133 MHz), but it is
-- still faster than the CPU can feed it, and keeping the register interface in
-- the CPU's own clock domain avoids any clock crossing. If sector throughput
-- ever matters, the fix is a sector-buffer burst mode clocked from c3, not a
-- faster version of this byte path.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY flash IS
  PORT(
        -- Common
		  CLK					  : IN std_logic;
        DATAIN            : IN std_logic_vector(7 DOWNTO 0);
		  ADDR              : IN std_logic_vector(15 DOWNTO 0);
		  RD                : IN std_logic;
        WR                : IN std_logic;
		  FL_DI			 	  : IN std_logic;
		  DATAOUT           : OUT std_logic_vector(7 DOWNTO 0);
	  	  FL_SCK				  : OUT std_logic;
		  FL_CS				  : OUT std_logic;
		  FL_DO  	        : OUT std_logic);
   END flash;

ARCHITECTURE behavior OF flash IS

  SIGNAL cs_n    : std_logic := '1';                       -- released at power-up
  SIGNAL sh_out  : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL sh_in   : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL rx_data : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL bitcnt  : integer RANGE 0 TO 8 := 0;
  SIGNAL phase   : std_logic := '0';   -- '0' = SCK low half, '1' = SCK high half
  SIGNAL busy    : std_logic := '0';
  SIGNAL sck_r   : std_logic := '0';
  SIGNAL wr_prev : std_logic := '1';

BEGIN

  FL_SCK <= sck_r;
  FL_CS  <= cs_n;
  -- MOSI always presents the current MSB; sh_out only shifts while SCK is low,
  -- so the line is stable across every rising edge.
  FL_DO  <= sh_out(7);

  PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN

      -- Commands are taken on the FALLING edge of the write strobe: that is a
      -- one-shot (a level test would re-trigger on every clock the strobe is
      -- low) and DATAIN is still driven at that point in the bus cycle.
      IF (wr_prev = '1' AND WR = '0') THEN
        IF ADDR = x"0098" AND busy = '0' THEN
          sh_out <= DATAIN;
          sh_in  <= (OTHERS => '0');
          bitcnt <= 8;
          phase  <= '0';
          sck_r  <= '0';
          busy   <= '1';
        ELSIF ADDR = x"009A" THEN
          cs_n <= DATAIN(0);
        END IF;
      END IF;
      wr_prev <= WR;

      IF busy = '1' THEN
        IF phase = '0' THEN
          -- MOSI is already valid; raise SCK so the flash samples it.
          sck_r <= '1';
          phase <= '1';
        ELSE
          -- End of the high phase: MISO has settled, so capture it, drop SCK
          -- and advance to the next bit.
          sck_r  <= '0';
          phase  <= '0';
          sh_in  <= sh_in(6 DOWNTO 0) & FL_DI;
          sh_out <= sh_out(6 DOWNTO 0) & '0';
          IF bitcnt = 1 THEN
            rx_data <= sh_in(6 DOWNTO 0) & FL_DI;   -- the completed byte
            busy    <= '0';
            bitcnt  <= 0;
          ELSE
            bitcnt <= bitcnt - 1;
          END IF;
        END IF;
      END IF;

    END IF;
  END PROCESS;

  -- Read-back is gated on RD.  (The original drove the bus whenever the address
  -- matched, write cycles included.)
  DATAOUT <= rx_data            WHEN (RD = '0' AND ADDR = x"0098") ELSE
             (busy & "0000000") WHEN (RD = '0' AND ADDR = x"0099") ELSE
             "ZZZZZZZZ";

END;
