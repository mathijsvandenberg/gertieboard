--------------------------------------------------------------------------------
-- sdram_mem.vhd  --  conventional memory in the DE0-Nano's SDRAM
--
-- Drop-in for psram_ctrl: same CPU-side interface (ADDR/RD/WR/DATAIN/DATAOUT/
-- READY), same address ownership, same cache. What changes is what is on the
-- other side -- the DE0-Nano's IS42S16160G instead of a QPI PSRAM.
--
-- WHY. The PSRAM is a hand-soldered SOIC-8 on the top board and it has cost a
-- week: a cold power-on left it not in QPI, so every read returned nothing and
-- the machine stopped on POST 02 before it had executed twenty instructions.
-- Four separate design fixes -- init clock rate, data-versus-clock edge, chip
-- select at power-up, PLL lock gating -- moved the failure count in the wrong
-- direction, and a reflow did not change it either.
--
-- The SDRAM has none of that history. It is factory-mounted, it already carries
-- the EGA bit planes through Keen 4 at full frame rate, EGAVFY verifies all
-- 65536 offsets of it, and since the I/O constraints went in it is the only
-- external interface on this board whose timing is actually checked.
--
-- It is also simply better memory:
--
--                       PSRAM (QPI)        SDRAM
--     width              4 bits serial      16 bits parallel
--     clock              12.5 MHz SCK       50 MHz
--     16-byte line       ~46 SCK = 3.7 us   8 words = ~2.1 us
--     capacity           8 MB               32 MB
--
-- ---------------------------------------------------------------------------
-- WHERE IT LIVES
--
-- ega_mem owns SDRAM words 0..0x1FFFF -- four 64 KB planes, interleaved two to
-- a word. Conventional memory starts above that:
--
--     sdram word = SDRAM_BASE + (cpu byte address / 2)
--
-- with the byte picked out of the 16-bit word by address bit 0. 640 KB is
-- 320 K words in a 16 M-word part, so the two regions are nowhere near meeting;
-- SDRAM_BASE is the only thing that keeps them apart and it is checked below.
--
-- ---------------------------------------------------------------------------
-- THE CACHE IS psram_ctrl's, DELIBERATELY UNCHANGED
--
-- Four lines of 16 bytes, fully associative, round-robin, write-through with
-- invalidate. That geometry was not chosen here -- it was measured on this
-- machine and this software, including the discovery that eight lines cost
-- timing margin the design could not spare while gaining nothing ramspeed could
-- see. Copying a tuned answer is cheaper than re-deriving it, and if it is ever
-- retuned both files should move together.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  work.memmap.ALL;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;

ENTITY sdram_mem IS
  PORT(
        CLK_RAM : IN    std_logic;                           -- c3, 50 MHz
        RESET   : IN    std_logic;
        -- CPU side
        DATAIN  : IN    std_logic_vector(7  DOWNTO 0);
        ADDR    : IN    std_logic_vector(19 DOWNTO 0);
        RD      : IN    std_logic;                           -- /MEMR, active LOW
        WR      : IN    std_logic;                           -- /MEMW, active LOW
        DATAOUT : INOUT std_logic_vector(7  DOWNTO 0);
        READY   : OUT   std_logic;
        -- SDRAM client (arbiter port 2)
        SD_REQ  : OUT   std_logic;
        SD_LOCK : OUT   std_logic;
        SD_WE   : OUT   std_logic;
        SD_ADDR : OUT   std_logic_vector(23 DOWNTO 0);
        SD_DIN  : OUT   std_logic_vector(15 DOWNTO 0);
        SD_BE   : OUT   std_logic_vector(1 DOWNTO 0);
        SD_DOUT : IN    std_logic_vector(15 DOWNTO 0);
        SD_ACK  : IN    std_logic);
END sdram_mem;

ARCHITECTURE behavior OF sdram_mem IS

  -- First SDRAM word of conventional memory. ega_mem uses 0..0x1FFFF, so this
  -- must stay at or above 0x20000; the assert below is the only thing enforcing
  -- it, because the two modules have no other reason to know about each other.
  CONSTANT SDRAM_BASE : std_logic_vector(23 DOWNTO 0) := x"020000";

  CONSTANT LINE_BYTES : integer := 16;
  CONSTANT NLINES     : integer := 4;
  CONSTANT LINE_WORDS : integer := LINE_BYTES / 2;

  TYPE line_t  IS ARRAY(0 TO LINE_BYTES-1) OF std_logic_vector(7 DOWNTO 0);
  TYPE lines_t IS ARRAY(0 TO NLINES-1)     OF line_t;
  TYPE tags_t  IS ARRAY(0 TO NLINES-1)     OF std_logic_vector(15 DOWNTO 0);

  SIGNAL cache : lines_t;
  SIGNAL tag   : tags_t;
  SIGNAL valid : std_logic_vector(NLINES-1 DOWNTO 0) := (OTHERS => '0');

  SIGNAL victim   : integer RANGE 0 TO NLINES-1 := 0;
  SIGNAL fill_sel : integer RANGE 0 TO NLINES-1 := 0;
  SIGNAL fill_idx : integer RANGE 0 TO LINE_WORDS := 0;   -- in WORDS, not bytes
  SIGNAL req_off  : integer RANGE 0 TO LINE_BYTES-1 := 0;
  SIGNAL tag_pend : std_logic := '0';

  SIGNAL cur_tag    : std_logic_vector(15 DOWNTO 0);
  SIGNAL hit_vec    : std_logic_vector(NLINES-1 DOWNTO 0);
  SIGNAL hit        : std_logic;
  SIGNAL cache_byte : std_logic_vector(7 DOWNTO 0);

  SIGNAL lu_addr : std_logic_vector(19 DOWNTO 0) := (OTHERS => '1');
  SIGNAL lu_data : std_logic_vector(7  DOWNTO 0) := (OTHERS => '0');
  SIGNAL lu_hit  : std_logic := '0';
  SIGNAL lu_ok   : std_logic;

  SIGNAL is_ram    : std_logic;
  SIGNAL is_ram_q  : std_logic := '0';  -- registered, for the READY path only
  SIGNAL lu_ok_r   : std_logic := '0';  -- registered cache-hit test
  SIGNAL cpu_rd_op : std_logic;
  SIGNAL cpu_wr_op : std_logic;
  SIGNAL cpu_op    : std_logic;
  SIGNAL rd_hit    : std_logic;

  TYPE st_t IS (S_IDLE, S_RD_REQ, S_RD_W, S_WR_W, S_FINISH);
  SIGNAL state : st_t := S_IDLE;

  SIGNAL read_data : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ready_int : std_logic := '1';

  SIGNAL fill_base : std_logic_vector(23 DOWNTO 0) := (OTHERS => '0');
  SIGNAL sd_req_i  : std_logic := '0';
  SIGNAL sd_we_i   : std_logic := '0';
  SIGNAL sd_a_i    : std_logic_vector(23 DOWNTO 0) := (OTHERS => '0');
  SIGNAL sd_d_i    : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL sd_be_i   : std_logic_vector(1 DOWNTO 0)  := "11";

BEGIN

  -- The two SDRAM regions must not overlap, and nothing else says so.
  ASSERT SDRAM_BASE >= x"020000"
    REPORT "sdram_mem: SDRAM_BASE overlaps the EGA planes at words 0..0x1FFFF"
    SEVERITY FAILURE;

  SD_REQ  <= sd_req_i;
  SD_WE   <= sd_we_i;
  SD_ADDR <= sd_a_i;
  SD_DIN  <= sd_d_i;
  SD_BE   <= sd_be_i;

  -- NO LOCK. ega_mem holds the grant across a pair because its two words are
  -- halves of one pixel and an interleaved write would split it. Nothing here
  -- is like that: a line fill is eight INDEPENDENT words and a write is one, so
  -- letting the display in between them costs a few hundred nanoseconds of fill
  -- time and buys the raster its deadline. Locking would hand the CPU 2 us of
  -- uninterruptible memory in a 63.5 us row, for nothing.
  SD_LOCK <= '0';

  ----------------------------------------------------------------------------
  -- Cache lookup, lifted from psram_ctrl including the reasons.
  ----------------------------------------------------------------------------
  cur_tag <= ADDR(19 DOWNTO 4);

  tag_cmp : FOR i IN 0 TO NLINES-1 GENERATE
    hit_vec(i) <= valid(i) WHEN tag(i) = cur_tag ELSE '0';
  END GENERATE;

  hit_or : PROCESS (hit_vec)
    VARIABLE h : std_logic;
  BEGIN
    h := '0';
    FOR i IN 0 TO NLINES-1 LOOP
      h := h OR hit_vec(i);
    END LOOP;
    hit <= h;
  END PROCESS;

  -- One-hot byte select rather than encode-then-index: every line's byte select
  -- depends only on the ADDRESS, so they evaluate in parallel with the tag
  -- compare and only the final OR is in series. Safe because tags are unique.
  byte_mux : PROCESS (hit_vec, cache, ADDR)
    VARIABLE b : std_logic_vector(7 DOWNTO 0);
  BEGIN
    b := (OTHERS => '0');
    FOR i IN 0 TO NLINES-1 LOOP
      IF hit_vec(i) = '1' THEN
        b := b OR cache(i)(conv_integer(ADDR(3 DOWNTO 0)));
      END IF;
    END LOOP;
    cache_byte <= b;
  END PROCESS;

  -- Registered lookup with a "belongs to the address on the bus" guard, so a
  -- stale pipeline entry can never be served: worst case the guard fails, the
  -- access is treated as a miss for one cycle, and READY stays low a bit longer.
  -- RISING EDGE, unlike psram_ctrl, which ran its whole machine on the falling
  -- one because it had to place SPI data half a cycle ahead of an SCK it
  -- generated itself. There is no SCK here: the partner is sdram_arb, which is
  -- rising-edge, as is ega_mem's identical client. A REQ/ACK handshake split
  -- across both edges of the same clock buys nothing and costs a half-cycle of
  -- margin on every ACK, so the whole module runs on the arbiter's edge.
  lookup : PROCESS (CLK_RAM)
  BEGIN
    IF rising_edge(CLK_RAM) THEN
      is_ram_q <= is_ram;          -- see the note by cpu_rd_op
      lu_addr <= ADDR;
      lu_data <= cache_byte;
      lu_hit  <= hit;

      -- THE HIT TEST, REGISTERED. It was a 20-bit equality against the LIVE
      -- address feeding rd_hit, then READY, then CPU_RDY -- the widest piece
      -- of logic on the tightest path in the machine, and the reason the
      -- design's slack swung between +0.1 and -0.6 ns on nothing but fitter
      -- placement.
      --
      -- The comparison does not need to be live. lu_addr IS the address from
      -- one clock ago, so this asks whether the address is still what it was
      -- last clock -- and the address is LATCHED at ALE and holds for the
      -- whole bus cycle. It is therefore true for every clock of that cycle
      -- after the first, and computing it one clock later changes nothing
      -- except which side of a flip-flop the comparator sits on.
      --
      -- RD does not assert until the following T-state, about 100 ns at
      -- 10 MHz against a 20 ns clock here, so the answer is settled several
      -- clocks before anything reads it.
      lu_ok_r <= '0';
      IF (lu_hit = '1' AND lu_addr = ADDR) THEN
        lu_ok_r <= '1';
      END IF;
    END IF;
  END PROCESS;

  lu_ok  <= lu_ok_r;             -- registered above; see the note there
  rd_hit <= cpu_rd_op AND lu_ok;

  -- SAME OWNERSHIP AS THE PSRAM IT REPLACES. Deliberately the same function:
  -- the region is a property of the memory map, not of which chip is behind it,
  -- so switching backing store must not be able to move a boundary as a side
  -- effect. memmap is where that decision lives.
  is_ram    <= owned_by_cpuram(ADDR);
  cpu_rd_op <= is_ram AND (NOT RD);
  cpu_wr_op <= is_ram AND (NOT WR);
  cpu_op    <= cpu_rd_op OR cpu_wr_op;

  DATAOUT <= lu_data   WHEN (cpu_rd_op = '1' AND lu_ok = '1') ELSE
             read_data WHEN  cpu_rd_op = '1'                  ELSE "ZZZZZZZZ";

  READY   <= '0' WHEN (cpu_op = '1' AND state = S_IDLE AND rd_hit = '0')
             ELSE ready_int;

  ----------------------------------------------------------------------------
  -- The SDRAM side.
  ----------------------------------------------------------------------------
  PROCESS (RESET, CLK_RAM)
  BEGIN
    IF RESET = '1' THEN
      state     <= S_IDLE;
      sd_req_i  <= '0';
      sd_we_i   <= '0';
      sd_be_i   <= "11";
      ready_int <= '1';
      valid     <= (OTHERS => '0');      -- cache starts empty
      victim    <= 0;
      fill_sel  <= 0;
      fill_idx  <= 0;
      req_off   <= 0;
      tag_pend  <= '0';
      read_data <= (OTHERS => '0');

    ELSIF rising_edge(CLK_RAM) THEN
      -- Deferred tag write, off the hit-compare path: S_IDLE only raises a bit,
      -- and the write happens here enabled by a REGISTER instead of by the
      -- NLINES-way compare. Nothing needs the tag on that cycle -- the line is
      -- marked invalid in the same breath, and ADDR is held for the whole bus
      -- cycle because READY is low.
      IF tag_pend = '1' THEN
        tag(fill_sel) <= ADDR(19 DOWNTO 4);
      END IF;
      tag_pend <= '0';

      CASE state IS

        WHEN S_IDLE =>
          sd_req_i <= '0';
          IF cpu_rd_op = '1' AND hit = '0' THEN
            -- read MISS: fetch the whole aligned line, LINE_WORDS words of it.
            fill_sel      <= victim;
            fill_idx      <= 0;
            req_off       <= conv_integer(ADDR(3 DOWNTO 0));
            valid(victim) <= '0';                -- stale while being refilled
            tag_pend      <= '1';
            -- line base in WORDS: byte address (ADDR(19:4) & "0000") halved is
            -- ADDR(19:4) & "000", zero-extended to the SDRAM's 24-bit space.
            fill_base     <= SDRAM_BASE + ("00000" & ADDR(19 DOWNTO 4) & "000");
            ready_int     <= '0';
            state         <= S_RD_REQ;
          ELSIF cpu_wr_op = '1' THEN
            -- write-through, and drop any cached copy so stale data can never
            -- be served. DMA writes arrive on this same port, so they are
            -- covered too.
            FOR i IN 0 TO NLINES-1 LOOP
              IF valid(i) = '1' AND tag(i) = ADDR(19 DOWNTO 4) THEN
                valid(i) <= '0';
              END IF;
            END LOOP;
            sd_a_i  <= SDRAM_BASE + ("00000" & ADDR(19 DOWNTO 1));
            sd_d_i  <= DATAIN & DATAIN;          -- the byte lands in either half
            IF ADDR(0) = '0' THEN
              sd_be_i <= "01";                   -- low byte of the word
            ELSE
              sd_be_i <= "10";                   -- high byte
            END IF;
            sd_we_i   <= '1';
            sd_req_i  <= '1';       -- address and REQ land on the same edge
            ready_int <= '0';
            state     <= S_WR_W;
          ELSE
            ready_int <= '1';
          END IF;

        ------------------------------------------------------------------
        -- Line fill: LINE_WORDS reads, two bytes each.
        ------------------------------------------------------------------
        WHEN S_RD_REQ =>
          sd_a_i   <= fill_base + conv_std_logic_vector(fill_idx, 24);
          sd_we_i  <= '0';
          sd_be_i  <= "11";
          sd_req_i <= '1';
          state    <= S_RD_W;

        WHEN S_RD_W =>
          IF SD_ACK = '1' THEN
            sd_req_i <= '0';
            cache(fill_sel)(fill_idx*2)     <= SD_DOUT(7 DOWNTO 0);
            cache(fill_sel)(fill_idx*2 + 1) <= SD_DOUT(15 DOWNTO 8);
            -- hand the requested byte straight to the CPU as it goes past,
            -- rather than making it wait for the rest of the line
            IF req_off = fill_idx*2 THEN
              read_data <= SD_DOUT(7 DOWNTO 0);
            ELSIF req_off = fill_idx*2 + 1 THEN
              read_data <= SD_DOUT(15 DOWNTO 8);
            END IF;
            IF fill_idx = LINE_WORDS-1 THEN
              valid(fill_sel) <= '1';
              IF victim = NLINES-1 THEN victim <= 0;
              ELSE                      victim <= victim + 1; END IF;
              ready_int <= '1';
              state     <= S_FINISH;
            ELSE
              fill_idx <= fill_idx + 1;
              state    <= S_RD_REQ;
            END IF;
          END IF;

        ------------------------------------------------------------------
        -- Write: one word, one byte enabled.
        ------------------------------------------------------------------
        WHEN S_WR_W =>
          IF SD_ACK = '1' THEN
            sd_req_i  <= '0';
            sd_we_i   <= '0';
            sd_be_i   <= "11";
            ready_int <= '1';
            state     <= S_FINISH;
          END IF;

        ------------------------------------------------------------------
        -- Wait for the CPU to let go. NOT bookkeeping -- without it the
        -- machine hangs on the first write. Returning straight to S_IDLE puts
        -- us there with the strobe still asserted (the CPU has not seen READY
        -- yet), so S_IDLE would issue the same write again, and READY's own
        -- "low while an operation is pending in S_IDLE" term would hold READY
        -- down for a write forever -- the CPU waiting for a READY that only
        -- comes when it stops asking. Parking outside S_IDLE keeps READY high
        -- until both strobes have gone, which is what ends the bus cycle.
        ------------------------------------------------------------------
        WHEN S_FINISH =>
          sd_req_i  <= '0';
          ready_int <= '1';
          IF RD = '1' AND WR = '1' THEN
            state <= S_IDLE;
          END IF;

      END CASE;
    END IF;
  END PROCESS;

END behavior;
