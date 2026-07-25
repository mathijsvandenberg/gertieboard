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
--
-- READS ARE CACHED: a miss burst-fills a 16-byte aligned line and later
-- accesses to that line complete with no wait states at all (see the cache
-- notes further down). Writes are unchanged -- write-through, plus an
-- invalidate of any cached copy. Because a line fill takes far longer than a
-- single-byte read, busdecode's READY backstop had to be raised from 10 to 64
-- CPU clocks; do not put it back.
--
-- tCEM WARNING: the burst holds CS low for ~46 SCK cycles, so SCK_DIV must stay
-- <= 2 (3.7 us) to remain inside the PSRAM's ~8 us max CS-low refresh limit.
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
  -- widened for burst fills: 14 dummy/overhead + 2*LINE_BYTES + RD_LAT
  SIGNAL cycle_cnt : integer range 0 TO 127 := 0;
  SIGNAL delay_cnt : integer range 0 TO 65535 := 0;
  SIGNAL is_read_op: std_logic := '0';
  SIGNAL read_data : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ready_int : std_logic := '0';

  SIGNAL sio_oe  : std_logic_vector(3 DOWNTO 0);
  SIGNAL sio_out : std_logic_vector(3 DOWNTO 0);

  ----------------------------------------------------------------------------
  -- Read cache with burst fill
  --
  -- A single-byte 0xEB read costs 16 SCK cycles, almost all of it command +
  -- address + dummy overhead; once the chip is streaming, each FURTHER
  -- sequential byte costs only 2 more. So on a miss we keep clocking and fill a
  -- whole aligned line, then serve the next accesses to that line with zero
  -- wait states. 8088 instruction fetch is overwhelmingly sequential, so this
  -- turns ~16 SCK/byte into (16+2*15)/16 = 2.9 SCK/byte.
  --
  -- 4 lines, fully associative, round-robin replacement. Four lines matter: the
  -- CPU interleaves code fetch with data access, and a single line would be
  -- evicted by every operand read, making things WORSE than no cache.
  --
  -- Lines are 16-byte ALIGNED, so a burst can never cross the PSRAM's 1024-byte
  -- page boundary. Note tCEM (max CS-low time, ~8 us) bounds the burst: 46 SCK
  -- cycles is 3.7 us at SCK_DIV=2 and 1.8 us at SCK_DIV=1, both fine, but do
  -- NOT combine this line length with SCK_DIV >= 4.
  --
  -- Coherency: writes stay write-through and simply invalidate any cached copy
  -- of the affected line. DMA writes arrive on the same port, so they are
  -- covered too.
  ----------------------------------------------------------------------------
  CONSTANT LINE_BYTES : integer := 16;
  CONSTANT NLINES     : integer := 4;

  TYPE line_t  IS ARRAY(0 TO LINE_BYTES-1) OF std_logic_vector(7 DOWNTO 0);
  TYPE lines_t IS ARRAY(0 TO NLINES-1)     OF line_t;
  TYPE tags_t  IS ARRAY(0 TO NLINES-1)     OF std_logic_vector(15 DOWNTO 0);

  SIGNAL cache  : lines_t;
  SIGNAL tag    : tags_t;
  SIGNAL valid  : std_logic_vector(NLINES-1 DOWNTO 0) := (OTHERS => '0');

  SIGNAL victim   : integer RANGE 0 TO NLINES-1 := 0;   -- round-robin pointer
  SIGNAL fill_sel : integer RANGE 0 TO NLINES-1 := 0;   -- line being filled
  SIGNAL fill_idx : integer RANGE 0 TO LINE_BYTES := 0; -- bytes captured
  SIGNAL nib_hi   : std_logic := '0';                   -- high nibble pending
  SIGNAL nib_tmp  : std_logic_vector(3 DOWNTO 0) := (OTHERS => '0');
  -- byte offset the CPU actually asked for, latched when the fill starts, so
  -- read_data can present it the moment the fill ends (the lookup pipeline may
  -- not have caught up yet on that exact cycle)
  SIGNAL req_off  : integer RANGE 0 TO LINE_BYTES-1 := 0;

  SIGNAL cur_tag    : std_logic_vector(15 DOWNTO 0);
  SIGNAL hit_vec    : std_logic_vector(NLINES-1 DOWNTO 0);
  SIGNAL hit        : std_logic;
  SIGNAL hit_sel    : integer RANGE 0 TO NLINES-1;
  SIGNAL cache_byte : std_logic_vector(7 DOWNTO 0);
  SIGNAL rd_hit     : std_logic;

  -- Lookup pipeline.
  --
  -- Driving DATAOUT straight out of the tag compare + 64:1 byte mux put a long
  -- combinational chain onto the shared peripheral data bus (it showed up as the
  -- worst-case path, tag -> fdc sector-buffer datain, and cost ~3 ns of slack).
  -- So the lookup is registered instead. That is free in CPU terms: the address
  -- is stable from T1 and the 8088 does not latch data until T3/T4, hundreds of
  -- ns later, whereas this pipeline is one 50 MHz cycle (20 ns).
  --
  -- lu_addr records which address the registered result belongs to, and the
  -- result is only ever used when it still matches the address on the bus. That
  -- makes a stale pipeline entry impossible to serve -- worst case the guard
  -- fails, the access is treated as a miss for one cycle, and READY simply stays
  -- low a little longer.
  SIGNAL lu_addr : std_logic_vector(19 DOWNTO 0) := (OTHERS => '1');
  SIGNAL lu_data : std_logic_vector(7  DOWNTO 0) := (OTHERS => '0');
  SIGNAL lu_hit  : std_logic := '0';
  SIGNAL lu_ok   : std_logic;

BEGIN

  ----------------------------------------------------------------------------
  -- Cache lookup (combinational)
  ----------------------------------------------------------------------------
  cur_tag <= ADDR(19 DOWNTO 4);

  tag_cmp : FOR i IN 0 TO NLINES-1 GENERATE
    hit_vec(i) <= valid(i) WHEN tag(i) = cur_tag ELSE '0';
  END GENERATE;

  -- Tags are unique, so at most one bit of hit_vec is set.
  hit_enc : PROCESS (hit_vec)
    VARIABLE h : std_logic;
    VARIABLE s : integer RANGE 0 TO NLINES-1;
  BEGIN
    h := '0'; s := 0;
    FOR i IN 0 TO NLINES-1 LOOP
      IF hit_vec(i) = '1' THEN h := '1'; s := i; END IF;
    END LOOP;
    hit     <= h;
    hit_sel <= s;
  END PROCESS;

  cache_byte <= cache(hit_sel)(conv_integer(ADDR(3 DOWNTO 0)));

  -- registered lookup + "belongs to the current address" guard
  lookup : PROCESS (CLK_RAM)
  BEGIN
    IF falling_edge(CLK_RAM) THEN
      lu_addr <= ADDR;
      lu_data <= cache_byte;
      lu_hit  <= hit;
    END IF;
  END PROCESS;

  lu_ok  <= '1' WHEN (lu_hit = '1' AND lu_addr = ADDR) ELSE '0';
  rd_hit <= cpu_rd_op AND lu_ok;

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

  -- On a hit the byte comes straight out of the cache; read_data is only the
  -- fallback for the cycle in which a fill completes.
  DATAOUT <= lu_data   WHEN (cpu_rd_op = '1' AND lu_ok = '1') ELSE
             read_data WHEN  cpu_rd_op = '1'                  ELSE "ZZZZZZZZ";

  -- A read hit must NOT pull READY low, otherwise we would insert wait states
  -- on exactly the accesses the cache is meant to make free. Writes and read
  -- misses still stall until the FSM has run.
  READY   <= '0' WHEN (cpu_op = '1' AND state = S_IDLE AND rd_hit = '0')
             ELSE ready_int;

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
      valid      <= (OTHERS => '0');   -- cache starts empty
      victim     <= 0;
      fill_sel   <= 0;
      fill_idx   <= 0;
      nib_hi     <= '0';

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
          IF cpu_rd_op = '1' AND hit = '0' THEN
            -- read MISS: burst-fill the whole aligned line. The address sent is
            -- the LINE BASE (low 4 bits zeroed), not the requested byte.
            out_sr     <= x"EB" & "0000" & ADDR(19 DOWNTO 4) & "0000" & x"00";
            cycle_cnt  <= 0; is_read_op <= '1'; RAM_CS <= '0';
            fill_sel      <= victim;
            fill_idx      <= 0;
            nib_hi        <= '0';
            req_off       <= conv_integer(ADDR(3 DOWNTO 0));
            valid(victim) <= '0';                 -- stale while being refilled
            tag(victim)   <= ADDR(19 DOWNTO 4);
            ready_int  <= '0'; state <= S_QPI_LO;
          ELSIF cpu_wr_op = '1' THEN
            out_sr     <= x"38" & "0000" & ADDR & DATAIN;
            cycle_cnt  <= 0; is_read_op <= '0'; RAM_CS <= '0';
            -- write-through: drop any cached copy so we can never serve stale
            -- data (this also covers DMA, which writes through this same port)
            FOR i IN 0 TO NLINES-1 LOOP
              IF valid(i) = '1' AND tag(i) = ADDR(19 DOWNTO 4) THEN
                valid(i) <= '0';
              END IF;
            END LOOP;
            ready_int  <= '0'; state <= S_QPI_LO;
          ELSE
            ready_int <= '1';
          END IF;

        -- SCK low phase: hold for sck_div CLK_RAM cycles
        WHEN S_QPI_LO =>
          RAM_SCK <= '0';
          IF half_cnt >= sck_div - 1 THEN
            half_cnt <= 0;
            IF (is_read_op = '1' AND fill_idx >= LINE_BYTES) OR
               (is_read_op = '0' AND cycle_cnt >= 10) THEN
              IF is_read_op = '1' THEN
                -- line complete: publish it. valid and ready_int are set on the
                -- same edge, so by the time the CPU sees READY the lookup hits.
                valid(fill_sel) <= '1';
                IF victim = NLINES-1 THEN victim <= 0;
                ELSE                      victim <= victim + 1; END IF;
              END IF;
              -- (read_data was set during the fill, at fill_idx = req_off)
              IF is_read_op = '0' THEN read_data <= in_sr; END IF;
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
            -- Burst capture: from cycle (14+RD_LAT) the chip streams nibbles.
            -- Pair them into bytes and write straight into the line.
            IF is_read_op = '1' AND cycle_cnt >= 14 + rd_lat
                                AND fill_idx < LINE_BYTES THEN
              in_sr <= in_sr(3 DOWNTO 0) & RAM_SIO;
              IF nib_hi = '0' THEN
                nib_tmp <= RAM_SIO;
                nib_hi  <= '1';
              ELSE
                cache(fill_sel)(fill_idx) <= nib_tmp & RAM_SIO;
                -- also hand the requested byte straight to the CPU path
                IF fill_idx = req_off THEN
                  read_data <= nib_tmp & RAM_SIO;
                END IF;
                nib_hi   <= '0';
                fill_idx <= fill_idx + 1;
              END IF;
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
