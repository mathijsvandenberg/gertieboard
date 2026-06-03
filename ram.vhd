--------------------------------------------------------------------------------
-- ram.vhd  --  QPI (Quad SPI) version
--
-- 1 MB system-RAM for the 8088, served from an ESP-PSRAM64H over QSPI.
-- Address ranges handled:
--     0x00000-0x9FFFF  -- 640 KB conventional memory
--     0xE0000-0xEFFFF  -- 64 KB extra (drop the second clause if not needed)
--
-- Bus side:
--   RD / WR are ACTIVE LOW MEMORY strobes (gate with NOT IOM at top level).
--   READY is active HIGH: low = insert wait state, high = transfer complete.
--
-- PSRAM side (QPI mode 0):
--   Power-up + reset sequence (all sent in SPI mode):
--     0x66 (Reset Enable)  ->  0x99 (Reset)  ->  0x35 (Enter QPI)
--   Steady-state transactions are QPI:
--     Read:  0xEB + 24-bit address + 6 dummy cycles + 1 byte data  (16 SCK cycles)
--     Write: 0x38 + 24-bit address + 1 byte data                   (10 SCK cycles)
--
--   In QPI mode every SCK cycle carries 4 bits across SIO[3:0].
--   In SPI mode (init only) SIO(0) carries the bit, SIO[3:1] are high-Z.
--
-- Recommended clocking (CLK_RAM):
--   * 95.4 MHz   = 4.77 MHz x 20   (SCK = 47.7 MHz, 0 read wait states)  <-- pick
--   * 100 MHz with CPU = /21        (4.76 MHz CPU, also 0 wait states)
--   * 47.7 MHz   = 4.77 MHz x 10   (SCK = 23.85 MHz, ~2 read wait states)
--   Datasheet limit is SCK <= 133 MHz, so even 133 MHz CLK_RAM is legal
--   (subject to your FPGA / board routing being able to hit it).
--
-- Assumption: a board-level reset of the FPGA is accompanied by power-cycling
-- the PSRAM (typical for hobbyist boards where both share a 3.3V rail).  If
-- the PSRAM might be left in QPI mode while the FPGA resets, you'll need an
-- extra 0xF5 (Exit QPI) sent in QPI format before the SPI init runs; the
-- straightforward way is just to power-cycle.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY RAM IS
  PORT(
        -- CPU bus side
        CLK_RAM     : IN    std_logic;
        RESET       : IN    std_logic;
        DATAIN      : IN    std_logic_vector(7  DOWNTO 0);
        ADDR        : IN    std_logic_vector(19 DOWNTO 0);
        RD          : IN    std_logic;                          -- /MEMR  (active LOW)
        WR          : IN    std_logic;                          -- /MEMW  (active LOW)
        DATAOUT     : INOUT std_logic_vector(7  DOWNTO 0);      -- 'Z' when not driving
        READY       : OUT   std_logic;                          -- active HIGH

        -- PSRAM side
        RAM_SCK     : OUT   std_logic;
        RAM_CS      : OUT   std_logic;
        RAM_SIO     : INOUT std_logic_vector(3 DOWNTO 0));
END RAM;


ARCHITECTURE behavior OF RAM IS

  ----------------------------------------------------------------------------
  -- Tunables (sized for CLK_RAM = 95.4 MHz)
  ----------------------------------------------------------------------------
  CONSTANT POWERUP_TICKS  : integer := 40000;    -- ~210 us  (>= 150 us)
  CONSTANT GAP_TICKS      : integer := 32;       -- CS high between SPI commands
  CONSTANT RST_WAIT_TICKS : integer := 10000;     -- ~52 us tRST after 0x99

  ----------------------------------------------------------------------------
  -- Address decode (combinational)
  ----------------------------------------------------------------------------
  SIGNAL is_ram    : std_logic;
  SIGNAL cpu_rd_op : std_logic;
  SIGNAL cpu_wr_op : std_logic;
  SIGNAL cpu_op    : std_logic;

  ----------------------------------------------------------------------------
  -- State machine
  ----------------------------------------------------------------------------
  TYPE state_t IS (
    S_POWERUP,     -- waiting for PSRAM to stabilize after reset
    S_SPI_INIT,    -- load the next SPI init command byte (0x66 / 0x99 / 0x35)
    S_SPI_LO,      -- SPI bit phase, SCK low
    S_SPI_HI,      -- SPI bit phase, SCK high (shift)
    S_INIT_GAP,    -- CS high between init commands
    S_INIT_WAIT,   -- tRST settle after 0x99
    S_IDLE,        -- QPI mode, ready for CPU
    S_QPI_LO,      -- QPI nibble phase, SCK low
    S_QPI_HI,      -- QPI nibble phase, SCK high (sample / shift)
    S_FINISH       -- transaction done; READY high, wait for bus idle
  );
  SIGNAL state : state_t := S_POWERUP;

  -- Init progress: 1 = 0x66, 2 = 0x99, 3 = 0x35, 0 = init complete
  SIGNAL init_step : integer range 0 TO 3 := 1;

  ----------------------------------------------------------------------------
  -- Shift registers and counters
  ----------------------------------------------------------------------------
  --   out_sr holds:
  --     SPI init : cmd byte in top 8 bits (bit 39 is MSB sent first)
  --     QPI read : 0xEB & "0000" & ADDR & x"00"        (40 bits)
  --     QPI write: 0x38 & "0000" & ADDR & DATAIN       (40 bits)
  SIGNAL out_sr    : std_logic_vector(39 DOWNTO 0) := (OTHERS => '0');
  SIGNAL in_sr     : std_logic_vector(7  DOWNTO 0) := (OTHERS => '0');
  SIGNAL bit_cnt   : integer range 0 TO 15 := 0;     -- SPI bit countdown
  SIGNAL cycle_cnt : integer range 0 TO 31 := 0;     -- QPI cycle index
  SIGNAL delay_cnt : integer range 0 TO 65535 := 0;

  -- Operation type for the current QPI transaction
  SIGNAL is_read_op : std_logic := '0';

  -- Captured read result + internal ready
  SIGNAL read_data : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ready_int : std_logic := '0';

  ----------------------------------------------------------------------------
  -- SIO output drive (per-bit, so SPI init can drive only SIO(0))
  ----------------------------------------------------------------------------
  SIGNAL sio_oe  : std_logic_vector(3 DOWNTO 0);
  SIGNAL sio_out : std_logic_vector(3 DOWNTO 0);

BEGIN

  ----------------------------------------------------------------------------
  -- Address decode + activity detection
  ----------------------------------------------------------------------------
  is_ram    <= '1' WHEN (ADDR < x"A0000") OR
                        (ADDR >= x"E0000" AND ADDR < x"F0000")
                ELSE '0';
					 

  cpu_rd_op <= is_ram AND (NOT RD);
  cpu_wr_op <= is_ram AND (NOT WR);
  cpu_op    <= cpu_rd_op OR cpu_wr_op;

  ----------------------------------------------------------------------------
  -- DATAOUT drives the bus only on a RAM read, Z otherwise
  ----------------------------------------------------------------------------
  DATAOUT <= read_data WHEN cpu_rd_op = '1' ELSE "ZZZZZZZZ";

  ----------------------------------------------------------------------------
  -- READY: combinational override so the wait state is asserted instantly
  ----------------------------------------------------------------------------
  READY <= '0' WHEN (cpu_op = '1' AND state = S_IDLE) ELSE ready_int;

  ----------------------------------------------------------------------------
  -- SIO tri-state per bit
  ----------------------------------------------------------------------------
  RAM_SIO(0) <= sio_out(0) WHEN sio_oe(0) = '1' ELSE 'Z';
  RAM_SIO(1) <= sio_out(1) WHEN sio_oe(1) = '1' ELSE 'Z';
  RAM_SIO(2) <= sio_out(2) WHEN sio_oe(2) = '1' ELSE 'Z';
  RAM_SIO(3) <= sio_out(3) WHEN sio_oe(3) = '1' ELSE 'Z';

  ----------------------------------------------------------------------------
  -- SIO drive logic (combinational, derived from state + cycle + op type)
  ----------------------------------------------------------------------------
  sio_drive : PROCESS (state, cycle_cnt, is_read_op, out_sr)
  BEGIN
    -- Default: all four lines high-Z
    sio_oe  <= "0000";
    sio_out <= "0000";

    CASE state IS

      WHEN S_POWERUP =>
        -- Datasheet: during the 150 us power-up window, SIO[3:0] must be LOW.
        sio_oe  <= "1111";
        sio_out <= "0000";

      WHEN S_SPI_INIT | S_SPI_LO | S_SPI_HI =>
        -- SPI mode: drive only SIO(0).  Slave's MISO appears on SIO(1).
        sio_oe     <= "0001";
        sio_out(0) <= out_sr(39);

      WHEN S_QPI_LO | S_QPI_HI =>
        IF cycle_cnt < 8 THEN
          -- cmd (cycles 0..1) + 24-bit address (cycles 2..7): we drive
          sio_oe  <= "1111";
          sio_out <= out_sr(39 DOWNTO 36);
        ELSIF is_read_op = '0' AND cycle_cnt < 10 THEN
          -- QPI write data phase (cycles 8..9): we drive
          sio_oe  <= "1111";
          sio_out <= out_sr(39 DOWNTO 36);
        ELSE
          -- Read dummy (8..13) and read data (14..15): slave drives
          sio_oe <= "0000";
        END IF;

      WHEN OTHERS =>
        -- S_INIT_GAP, S_INIT_WAIT, S_IDLE, S_FINISH: high-Z
        NULL;

    END CASE;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- Main state machine
  ----------------------------------------------------------------------------
  PROCESS (RESET, CLK_RAM)
  BEGIN
    IF RESET = '1' THEN
      state      <= S_POWERUP;
      init_step  <= 1;
      delay_cnt  <= POWERUP_TICKS;
      RAM_CS     <= '1';
      RAM_SCK    <= '0';
      ready_int  <= '0';                -- block the CPU until init finishes
      bit_cnt    <= 0;
      cycle_cnt  <= 0;
      out_sr     <= (OTHERS => '0');
      in_sr      <= (OTHERS => '0');
      read_data  <= (OTHERS => '0');
      is_read_op <= '0';

    ELSIF falling_edge(CLK_RAM) THEN
      CASE state IS

        -- ----------------------------------------------------------------
        WHEN S_POWERUP =>
          RAM_CS  <= '1';
          RAM_SCK <= '0';
          IF delay_cnt = 0 THEN
            state     <= S_SPI_INIT;
            init_step <= 1;
          ELSE
            delay_cnt <= delay_cnt - 1;
          END IF;

        -- ----------------------------------------------------------------
        WHEN S_SPI_INIT =>
        -- Load the SPI command for the current init step and start clocking.
          CASE init_step IS
            WHEN 1      => out_sr <= x"66" & x"00000000";   -- Reset Enable
            WHEN 2      => out_sr <= x"99" & x"00000000";   -- Reset
            WHEN 3      => out_sr <= x"35" & x"00000000";   -- Enter QPI
            WHEN OTHERS => out_sr <= (OTHERS => '0');
          END CASE;
          bit_cnt <= 8;
          RAM_CS  <= '0';
          RAM_SCK <= '0';
          state   <= S_SPI_LO;

        -- ----------------------------------------------------------------
        WHEN S_SPI_LO =>
        -- SPI low phase: MOSI bit is presented (sio_out(0) <= out_sr(39))
          RAM_SCK <= '0';
          IF bit_cnt = 0 THEN
            -- All 8 SPI bits sent.  Decide what comes next per init_step.
            CASE init_step IS
              WHEN 1 =>                              -- after 0x66: gap, then 0x99
                init_step <= 2;
                delay_cnt <= GAP_TICKS;
                state     <= S_INIT_GAP;
              WHEN 2 =>                              -- after 0x99: tRST, then 0x35
                init_step <= 3;
                delay_cnt <= RST_WAIT_TICKS;
                state     <= S_INIT_WAIT;
              WHEN 3 =>                              -- after 0x35: brief gap, then S_IDLE
                init_step <= 0;
                delay_cnt <= GAP_TICKS;
                state     <= S_INIT_GAP;
              WHEN OTHERS =>
                state <= S_IDLE;
            END CASE;
          ELSE
            state <= S_SPI_HI;
          END IF;

        -- ----------------------------------------------------------------
        WHEN S_SPI_HI =>
          RAM_SCK <= '1';
          out_sr  <= out_sr(38 DOWNTO 0) & '0';     -- shift left by 1 bit
          bit_cnt <= bit_cnt - 1;
          state   <= S_SPI_LO;

        -- ----------------------------------------------------------------
        WHEN S_INIT_GAP =>
          RAM_CS  <= '1';
          RAM_SCK <= '0';
          IF delay_cnt = 0 THEN
            IF init_step = 0 THEN
              state     <= S_IDLE;
              ready_int <= '1';                     -- PSRAM is ready for ops
            ELSE
              state <= S_SPI_INIT;
            END IF;
          ELSE
            delay_cnt <= delay_cnt - 1;
          END IF;

        -- ----------------------------------------------------------------
        WHEN S_INIT_WAIT =>
          RAM_CS  <= '1';
          RAM_SCK <= '0';
          IF delay_cnt = 0 THEN
            state <= S_SPI_INIT;
          ELSE
            delay_cnt <= delay_cnt - 1;
          END IF;

        -- ----------------------------------------------------------------
        WHEN S_IDLE =>
          RAM_CS  <= '1';
          RAM_SCK <= '0';
          IF cpu_rd_op = '1' THEN
            -- 0xEB Quad Fast Read: 2 + 6 + 6 + 2 = 16 SCK cycles
            out_sr     <= x"EB" & "0000" & ADDR & x"00";
            cycle_cnt  <= 0;
            is_read_op <= '1';
            RAM_CS     <= '0';
            ready_int  <= '0';
            state      <= S_QPI_LO;
          ELSIF cpu_wr_op = '1' THEN
            -- 0x38 Quad Write: 2 + 6 + 0 + 2 = 10 SCK cycles
            out_sr     <= x"38" & "0000" & ADDR & DATAIN;
            cycle_cnt  <= 0;
            is_read_op <= '0';
            RAM_CS     <= '0';
            ready_int  <= '0';
            state      <= S_QPI_LO;
          ELSE
            ready_int <= '1';
          END IF;

        -- ----------------------------------------------------------------
        WHEN S_QPI_LO =>
        -- SCK low half-cycle.  sio_oe / sio_out are driven by the
        -- combinational process based on cycle_cnt.
          RAM_SCK <= '0';
          IF (is_read_op = '1' AND cycle_cnt >= 16) OR
             (is_read_op = '0' AND cycle_cnt >= 10) THEN
            -- All bits clocked; capture read data (irrelevant for writes)
            read_data <= in_sr;
            state     <= S_FINISH;
            ready_int <= '1';
          ELSE
            state <= S_QPI_HI;
          END IF;

        -- ----------------------------------------------------------------
        WHEN S_QPI_HI =>
        -- SCK high half-cycle.  Sample MISO on data cycles, shift on
        -- output cycles, increment cycle count.
          RAM_SCK <= '1';

          -- Sample SIO[3:0] for read data nibbles (cycles 14 and 15)
          IF is_read_op = '1' AND cycle_cnt >= 14 AND cycle_cnt < 16 THEN
            in_sr <= in_sr(3 DOWNTO 0) & RAM_SIO;
          END IF;

          -- Shift out_sr while we are still driving (cmd/addr/write-data)
          IF cycle_cnt < 8 OR (is_read_op = '0' AND cycle_cnt < 10) THEN
            out_sr <= out_sr(35 DOWNTO 0) & x"0";
          END IF;

          cycle_cnt <= cycle_cnt + 1;
          state     <= S_QPI_LO;

        -- ----------------------------------------------------------------
        WHEN S_FINISH =>
        -- Transaction complete.  Hold READY high until the CPU lets the
        -- bus go idle, then return to S_IDLE.
          RAM_CS    <= '1';
          RAM_SCK   <= '0';
          ready_int <= '1';
          IF RD = '1' AND WR = '1' THEN
            state <= S_IDLE;
          END IF;

      END CASE;
    END IF;
  END PROCESS;

END;