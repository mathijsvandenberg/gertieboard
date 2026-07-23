--------------------------------------------------------------------------------
-- psram_ctrl.vhd  --  QPI PSRAM controller, RUNTIME-TUNABLE, for the hybrid map
--
-- Owns conventional RAM only:  0x08000 .. 0x9FFFF  (M9K owns low + BIOS).
--
-- Same proven QPI sequence as before (0x66/0x99/0x35 init, 0xEB read with 6
-- dummy, 0x38 write), but the read-capture timing is now set at RUNTIME from the
-- CTRL input, so you can find the correct values for the REAL c3 clock domain on
-- the bench without recompiling:
--
--   CTRL(2 DOWNTO 0) = SCK_DIV : SCK half-period in CLK_RAM cycles.
--                                0 or 1 -> SCK = CLK_RAM/2 (25 MHz @ c3=50).
--                                2 -> 12.5 MHz, 4 -> 6.25 MHz, ... (wider eye).
--   CTRL(6 DOWNTO 3) = RD_LAT  : read latency. Data nibbles captured at cycles
--                                (14+RD_LAT),(15+RD_LAT); read runs 16+RD_LAT.
--   CTRL(7)          = reserved.
--
-- Capture is DIRECT off RAM_SIO, sampled at the settled END of the SCK-high
-- phase. Slowing SCK (SCK_DIV >= 2) widens the data eye and is the robust way to
-- get reliable reads independent of PLL phase; RD_LAT then fixes byte alignment.
-- Recommended bring-up: SCK_DIV=4, sweep RD_LAT 0..4 until a memory test passes,
-- then reduce SCK_DIV as far as it stays reliable.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;

ENTITY psram_ctrl IS
  PORT(
        CLK_RAM : IN    std_logic;
        RESET   : IN    std_logic;
        DATAIN  : IN    std_logic_vector(7  DOWNTO 0);
        ADDR    : IN    std_logic_vector(19 DOWNTO 0);
        RD      : IN    std_logic;                          -- /MEMR (active LOW)
        WR      : IN    std_logic;                          -- /MEMW (active LOW)
        DATAOUT : INOUT std_logic_vector(7  DOWNTO 0);
        READY   : OUT   std_logic;
        CTRL    : IN    std_logic_vector(7  DOWNTO 0);       -- runtime tuning
        RAM_SCK : OUT   std_logic;
        RAM_CS  : OUT   std_logic;
        RAM_SIO : INOUT std_logic_vector(3 DOWNTO 0));
END psram_ctrl;

ARCHITECTURE behavior OF psram_ctrl IS

  CONSTANT POWERUP_TICKS  : integer := 40000;
  CONSTANT GAP_TICKS      : integer := 32;
  CONSTANT RST_WAIT_TICKS : integer := 10000;

  SIGNAL is_ram    : std_logic;
  SIGNAL cpu_rd_op : std_logic;
  SIGNAL cpu_wr_op : std_logic;
  SIGNAL cpu_op    : std_logic;

  -- runtime tuning (decoded from CTRL)
  SIGNAL sck_div : integer RANGE 1 TO 7  := 1;
  SIGNAL rd_lat  : integer RANGE 0 TO 15 := 0;
  SIGNAL half_cnt: integer RANGE 0 TO 7  := 0;

  TYPE state_t IS (
    S_POWERUP, S_EXIT_INIT, S_EXIT_LO, S_EXIT_HI,
    S_SPI_INIT, S_SPI_LO, S_SPI_HI, S_INIT_GAP, S_INIT_WAIT,
    S_IDLE, S_QPI_LO, S_QPI_HI, S_FINISH );
  SIGNAL state : state_t := S_POWERUP;

  SIGNAL init_step : integer range 0 TO 3 := 1;
  SIGNAL nib_cnt   : integer range 0 TO 3 := 0;   -- QPI-exit nibble counter

  SIGNAL out_sr    : std_logic_vector(39 DOWNTO 0) := (OTHERS => '0');
  SIGNAL in_sr     : std_logic_vector(7  DOWNTO 0) := (OTHERS => '0');
  SIGNAL bit_cnt   : integer range 0 TO 15 := 0;
  SIGNAL cycle_cnt : integer range 0 TO 31 := 0;
  SIGNAL delay_cnt : integer range 0 TO 65535 := 0;
  SIGNAL is_read_op: std_logic := '0';
  SIGNAL read_data : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ready_int : std_logic := '0';

  SIGNAL sio_oe  : std_logic_vector(3 DOWNTO 0);
  SIGNAL sio_out : std_logic_vector(3 DOWNTO 0);

BEGIN

  -- conventional RAM above the 32 KB M9K low window, PLUS the full 64 KB
  -- F-segment BIOS (0xF0000..0xFFFFF) -- loaded once, then read/executed.
  is_ram    <= '1' WHEN ((ADDR >= x"08000") AND (ADDR < x"A0000"))
                     OR  (ADDR >= x"F0000")
                ELSE '0';

  cpu_rd_op <= is_ram AND (NOT RD);
  cpu_wr_op <= is_ram AND (NOT WR);
  cpu_op    <= cpu_rd_op OR cpu_wr_op;

  -- decode runtime tuning
  sck_div <= 1 WHEN CTRL(2 DOWNTO 0) = "000" ELSE conv_integer(CTRL(2 DOWNTO 0));
  rd_lat  <= conv_integer(CTRL(6 DOWNTO 3));

  DATAOUT <= read_data WHEN cpu_rd_op = '1' ELSE "ZZZZZZZZ";
  READY   <= '0' WHEN (cpu_op = '1' AND state = S_IDLE) ELSE ready_int;

  RAM_SIO(0) <= sio_out(0) WHEN sio_oe(0) = '1' ELSE 'Z';
  RAM_SIO(1) <= sio_out(1) WHEN sio_oe(1) = '1' ELSE 'Z';
  RAM_SIO(2) <= sio_out(2) WHEN sio_oe(2) = '1' ELSE 'Z';
  RAM_SIO(3) <= sio_out(3) WHEN sio_oe(3) = '1' ELSE 'Z';

  sio_drive : PROCESS (state, cycle_cnt, is_read_op, out_sr)
  BEGIN
    sio_oe  <= "0000";
    sio_out <= "0000";
    CASE state IS
      WHEN S_POWERUP =>
        sio_oe  <= "1111"; sio_out <= "0000";
      WHEN S_EXIT_LO | S_EXIT_HI =>
        -- QPI-exit (0xF5) clocked as 4-bit nibbles
        sio_oe  <= "1111"; sio_out <= out_sr(39 DOWNTO 36);
      WHEN S_SPI_INIT | S_SPI_LO | S_SPI_HI =>
        sio_oe     <= "0001"; sio_out(0) <= out_sr(39);
      WHEN S_QPI_LO | S_QPI_HI =>
        IF cycle_cnt < 8 THEN
          sio_oe  <= "1111"; sio_out <= out_sr(39 DOWNTO 36);
        ELSIF is_read_op = '0' AND cycle_cnt < 10 THEN
          sio_oe  <= "1111"; sio_out <= out_sr(39 DOWNTO 36);
        ELSE
          sio_oe  <= "0000";
        END IF;
      WHEN OTHERS => NULL;
    END CASE;
  END PROCESS;

  PROCESS (RESET, CLK_RAM)
  BEGIN
    IF RESET = '1' THEN
      state      <= S_POWERUP;
      init_step  <= 1;
      delay_cnt  <= POWERUP_TICKS;
      RAM_CS     <= '1';
      RAM_SCK    <= '0';
      ready_int  <= '0';
      bit_cnt    <= 0;
      cycle_cnt  <= 0;
      half_cnt   <= 0;
      nib_cnt    <= 0;
      out_sr     <= (OTHERS => '0');
      in_sr      <= (OTHERS => '0');
      read_data  <= (OTHERS => '0');
      is_read_op <= '0';

    ELSIF falling_edge(CLK_RAM) THEN
      CASE state IS

        WHEN S_POWERUP =>
          RAM_CS <= '1'; RAM_SCK <= '0';
          IF delay_cnt = 0 THEN state <= S_EXIT_INIT;
          ELSE delay_cnt <= delay_cnt - 1; END IF;

        -- Mode-agnostic wakeup: send 0xF5 (exit QPI) as a 4-bit QPI command.
        -- If the chip is in QPI it returns to SPI; if already in SPI the 2 bits
        -- form an incomplete command that CS-high aborts -> harmless either way.
        WHEN S_EXIT_INIT =>
          out_sr  <= x"F5" & x"00000000";
          nib_cnt <= 2; RAM_CS <= '0'; RAM_SCK <= '0';
          state   <= S_EXIT_LO;

        WHEN S_EXIT_LO =>
          RAM_SCK <= '0';
          IF nib_cnt = 0 THEN
            RAM_CS <= '1'; init_step <= 1; delay_cnt <= GAP_TICKS;
            state  <= S_INIT_GAP;            -- gap, then SPI reset/enter-QPI
          ELSE
            state <= S_EXIT_HI;
          END IF;

        WHEN S_EXIT_HI =>
          RAM_SCK <= '1';
          out_sr  <= out_sr(35 DOWNTO 0) & x"0";
          nib_cnt <= nib_cnt - 1;
          state   <= S_EXIT_LO;

        WHEN S_SPI_INIT =>
          CASE init_step IS
            WHEN 1      => out_sr <= x"66" & x"00000000";
            WHEN 2      => out_sr <= x"99" & x"00000000";
            WHEN 3      => out_sr <= x"35" & x"00000000";
            WHEN OTHERS => out_sr <= (OTHERS => '0');
          END CASE;
          bit_cnt <= 8; RAM_CS <= '0'; RAM_SCK <= '0'; state <= S_SPI_LO;

        WHEN S_SPI_LO =>
          RAM_SCK <= '0';
          IF bit_cnt = 0 THEN
            CASE init_step IS
              WHEN 1 => init_step <= 2; delay_cnt <= GAP_TICKS;      state <= S_INIT_GAP;
              WHEN 2 => init_step <= 3; delay_cnt <= RST_WAIT_TICKS; state <= S_INIT_WAIT;
              WHEN 3 => init_step <= 0; delay_cnt <= GAP_TICKS;      state <= S_INIT_GAP;
              WHEN OTHERS => state <= S_IDLE;
            END CASE;
          ELSE state <= S_SPI_HI; END IF;

        WHEN S_SPI_HI =>
          RAM_SCK <= '1';
          out_sr  <= out_sr(38 DOWNTO 0) & '0';
          bit_cnt <= bit_cnt - 1;
          state   <= S_SPI_LO;

        WHEN S_INIT_GAP =>
          RAM_CS <= '1'; RAM_SCK <= '0';
          IF delay_cnt = 0 THEN
            IF init_step = 0 THEN state <= S_IDLE; ready_int <= '1';
            ELSE state <= S_SPI_INIT; END IF;
          ELSE delay_cnt <= delay_cnt - 1; END IF;

        WHEN S_INIT_WAIT =>
          RAM_CS <= '1'; RAM_SCK <= '0';
          IF delay_cnt = 0 THEN state <= S_SPI_INIT;
          ELSE delay_cnt <= delay_cnt - 1; END IF;

        WHEN S_IDLE =>
          RAM_CS  <= '1'; RAM_SCK <= '0'; half_cnt <= 0;
          IF cpu_rd_op = '1' THEN
            out_sr     <= x"EB" & "0000" & ADDR & x"00";
            cycle_cnt  <= 0; is_read_op <= '1'; RAM_CS <= '0';
            ready_int  <= '0'; state <= S_QPI_LO;
          ELSIF cpu_wr_op = '1' THEN
            out_sr     <= x"38" & "0000" & ADDR & DATAIN;
            cycle_cnt  <= 0; is_read_op <= '0'; RAM_CS <= '0';
            ready_int  <= '0'; state <= S_QPI_LO;
          ELSE
            ready_int <= '1';
          END IF;

        -- SCK low phase: hold for sck_div CLK_RAM cycles
        WHEN S_QPI_LO =>
          RAM_SCK <= '0';
          IF half_cnt >= sck_div - 1 THEN
            half_cnt <= 0;
            IF (is_read_op = '1' AND cycle_cnt >= 16 + rd_lat) OR
               (is_read_op = '0' AND cycle_cnt >= 10) THEN
              read_data <= in_sr;
              ready_int <= '1';
              state     <= S_FINISH;
            ELSE
              state <= S_QPI_HI;
            END IF;
          ELSE
            half_cnt <= half_cnt + 1;
          END IF;

        -- SCK high phase: hold for sck_div cycles; sample at the settled end
        WHEN S_QPI_HI =>
          RAM_SCK <= '1';
          IF half_cnt >= sck_div - 1 THEN
            half_cnt <= 0;
            IF is_read_op = '1' AND cycle_cnt >= 14 + rd_lat AND cycle_cnt < 16 + rd_lat THEN
              in_sr <= in_sr(3 DOWNTO 0) & RAM_SIO;
            END IF;
            IF cycle_cnt < 8 OR (is_read_op = '0' AND cycle_cnt < 10) THEN
              out_sr <= out_sr(35 DOWNTO 0) & x"0";
            END IF;
            cycle_cnt <= cycle_cnt + 1;
            state     <= S_QPI_LO;
          ELSE
            half_cnt <= half_cnt + 1;
          END IF;

        WHEN S_FINISH =>
          RAM_CS <= '1'; RAM_SCK <= '0'; ready_int <= '1';
          IF RD = '1' AND WR = '1' THEN state <= S_IDLE; END IF;

      END CASE;
    END IF;
  END PROCESS;

END behavior;
