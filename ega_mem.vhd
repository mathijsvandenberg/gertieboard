--------------------------------------------------------------------------------
-- ega_mem.vhd  --  the EGA bit planes, in SDRAM, behind a scanline buffer
--
-- Four planes of 64 KB -- a 256 KB EGA, the largest the card was ever built as.
-- They used to be four M9K arrays of 8 KB, which is all that fits on-chip, and
-- 8 KB is not enough for the software that exists:
--
--   King's Quest keeps the area under its text windows at plane offset 0x2000
--   and clears 8000 bytes there -- read straight out of its own EGA driver.
--   Keen 4 programs a 640-pixel logical line, which is 16000 bytes a page.
--
-- THE PLANE IS THE WINDOW. The CPU sees 0xA0000..0xAFFFF, sixteen address bits,
-- and a plane holds exactly that: 64 KB, no fold. An earlier version carried
-- fourteen bits and gave 16 KB, which is enough for ONE page and no more -- and
-- one page is not what this software uses. Keen 4's Galaxy engine keeps three,
-- at 0, 16640 and 33280, and flips between them every frame; folded to 16 KB
-- they land at 0, 256 and 512 and each is drawn over the other two. That was
-- the repeated menu entries and the repeated status box on screen, and the
-- flicker was the flip.
--
-- Four 64 KB planes would need 256 M9K blocks and the part has 42, so they live
-- in the DE0-Nano's SDRAM instead, where 256 KB is nothing. This module is what
-- makes that invisible to the rest of the design.
--
-- ---------------------------------------------------------------------------
-- THE SCANLINE BUFFER IS THE WHOLE IDEA
--
-- A raster cannot wait. If the display fetched pixels from SDRAM directly then
-- every CPU access, every refresh and every row activation would be a chance to
-- miss a deadline that arrives 25 million times a second.
--
-- So it does not. One CGA row -- 40 offsets, four planes each -- is fetched into
-- an on-chip buffer while the PREVIOUS row is being displayed, and the display
-- reads only from that buffer. A doubled scanline is 63.5 us and the fetch is
-- 80 words at about 10 clocks each, so it takes 16 us: a quarter of the time it
-- has, with the CPU competing for the same memory throughout.
--
-- The buffer is 128 x 32 bits, which is ONE M9K block. The planes it replaces
-- were 32. That is the arithmetic that makes this worth doing at all.
--
-- ---------------------------------------------------------------------------
-- LAYOUT
--
-- Interleaved, so one pixel offset is two consecutive SDRAM words and a row is
-- one unbroken run:
--
--     word (offset*2 + 0) = plane 1 : plane 0     (green : blue)
--     word (offset*2 + 1) = plane 3 : plane 2     (intensity : red)
--
-- A CPU access touches both words; so does a scan fetch. Consecutive offsets
-- stay inside one SDRAM row, so a whole scanline activates at most twice.
--
-- ---------------------------------------------------------------------------
-- THE PREFETCH WINS
--
-- Arbitration is not a fairness question. A CPU cycle that waits is slower
-- software; a scanline that arrives late is a visible tear. The prefetch is
-- served first, always, and the CPU takes what is left -- which is three
-- quarters of the time even in the worst case.
--
-- ---------------------------------------------------------------------------
-- THREE CLOCKS
--
--   CLK_CPU (c0)  the CPU port, because that is the only clock that sees a bus
--                 cycle
--   CLK_VGA (c1)  the scan port, because that is the pixel clock
--   CLK_MEM (c3)  everything touching the SDRAM
--
-- Both crossings carry an EVENT, so both are toggles through two flops rather
-- than levels: a toggle needs no agreement between the two sides about how long
-- to hold anything.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;
USE  IEEE.NUMERIC_STD.ALL;

ENTITY ega_mem IS
  PORT(
        CLK_CPU   : IN  std_logic;
        CLK_VGA   : IN  std_logic;
        CLK_MEM   : IN  std_logic;
        RESET     : IN  std_logic;

        -- CPU port. Raise REQ and hold it; READY goes high for one CPU clock
        -- when the access is finished and RDATA is valid.
        CPU_REQ   : IN  std_logic;
        CPU_WE    : IN  std_logic;
        CPU_OFFS  : IN  std_logic_vector(15 DOWNTO 0);   -- byte offset in a plane
        CPU_WDATA : IN  std_logic_vector(31 DOWNTO 0);   -- p3:p2:p1:p0
        CPU_WMASK : IN  std_logic_vector(3 DOWNTO 0);    -- which planes to write
        CPU_RDATA : OUT std_logic_vector(31 DOWNTO 0);
        CPU_READY : OUT std_logic;

        -- Scan port. ROW_GO swaps the halves AND asks for the next row in one
        -- event: what was fetched during the last row becomes visible, and the
        -- row after this one starts filling. COL is 0..39.
        --
        -- The swap happens HERE, on the row boundary, and NOT when the fill
        -- finishes -- a fill completes 16 us into a 63.5 us row, and swapping
        -- there would change the picture half way down a character row.
        ROW_GO    : IN  std_logic;
        ROW_OFFS  : IN  std_logic_vector(15 DOWNTO 0);
        COL       : IN  std_logic_vector(5 DOWNTO 0);
        SCAN_DATA : OUT std_logic_vector(31 DOWNTO 0);

        -- SDRAM client
        SD_REQ    : OUT std_logic;
        SD_LOCK   : OUT std_logic;   -- '1' while a two-word pair is in progress
        SD_WE     : OUT std_logic;
        SD_ADDR   : OUT std_logic_vector(23 DOWNTO 0);
        SD_DIN    : OUT std_logic_vector(15 DOWNTO 0);
        SD_BE     : OUT std_logic_vector(1 DOWNTO 0);
        SD_DOUT   : IN  std_logic_vector(15 DOWNTO 0);
        SD_ACK    : IN  std_logic);
END ega_mem;

ARCHITECTURE behavior OF ega_mem IS

  -- The planes start at SDRAM word 0. Nothing else is in there.
  CONSTANT EGA_BASE : unsigned(23 DOWNTO 0) := (OTHERS => '0');

  -- 128 entries of 32 bits: two halves of 64, of which 40 are used. One M9K.
  TYPE lbuf_t IS ARRAY (0 TO 127) OF std_logic_vector(31 DOWNTO 0);
  SIGNAL lbuf : lbuf_t;
  ATTRIBUTE ramstyle : STRING;
  ATTRIBUTE ramstyle OF lbuf : SIGNAL IS "M9K";

  -- Which half the display is reading. The prefetch fills the other one --
  -- and that "other one" is CARRIED WITH THE ROW EVENT rather than tracked
  -- separately. See the note at the crossing below; this was two independent
  -- flip-flops in two clock domains before, kept opposite only by both being
  -- flipped on the same event, which is not a mechanism.
  SIGNAL disp_half : std_logic := '0';
  SIGNAL fill_tgt  : std_logic := '0';

  -- c1 -> c3
  SIGNAL row_tog   : std_logic := '0';
  SIGNAL row_s     : std_logic_vector(2 DOWNTO 0) := "000";
  SIGNAL row_addr  : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');

  -- c0 -> c3
  SIGNAL cpu_tog   : std_logic := '0';
  SIGNAL cpu_s     : std_logic_vector(2 DOWNTO 0) := "000";
  SIGNAL cpu_prev  : std_logic := '0';

  -- c3 -> c0
  SIGNAL dn_tog    : std_logic := '0';
  SIGNAL dn_s      : std_logic_vector(2 DOWNTO 0) := "000";

  TYPE st_t IS (M_IDLE,
                M_PF_LO, M_PF_LO_W, M_PF_HI, M_PF_HI_W,
                M_CP_LO, M_CP_LO_W, M_CP_HI, M_CP_HI_W);
  SIGNAL st : st_t := M_IDLE;

  SIGNAL pf_pend  : std_logic := '0';
  SIGNAL cp_pend  : std_logic := '0';
  SIGNAL pf_col   : unsigned(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL pf_base  : unsigned(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL pf_half  : std_logic := '1';
  SIGNAL pf_run   : std_logic := '0';   -- a row fetch is part way through
  -- The CPU's request, CAPTURED WHEN IT ARRIVES. See the note at the capture.
  SIGNAL cp_offs  : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL cp_wdata : std_logic_vector(31 DOWNTO 0) := (OTHERS => '0');
  SIGNAL cp_wmask : std_logic_vector(3 DOWNTO 0)  := (OTHERS => '0');
  SIGNAL cp_we    : std_logic := '0';
  SIGNAL word_lo  : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');

  SIGNAL sd_req_i : std_logic := '0';
  SIGNAL sd_we_i  : std_logic := '0';
  SIGNAL sd_a_i   : unsigned(23 DOWNTO 0) := (OTHERS => '0');
  SIGNAL sd_d_i   : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL sd_be_i  : std_logic_vector(1 DOWNTO 0) := "11";

  SIGNAL rd32     : std_logic_vector(31 DOWNTO 0) := (OTHERS => '0');
  SIGNAL wr_addr  : unsigned(6 DOWNTO 0);
  SIGNAL wr_data  : std_logic_vector(31 DOWNTO 0);
  SIGNAL wr_en    : std_logic := '0';

BEGIN

  -- High from the first word of a pair until the second is acknowledged, so the
  -- arbiter cannot let the other master in between the two halves of a pixel.
  SD_LOCK <= '1' WHEN (st = M_PF_LO OR st = M_PF_LO_W OR st = M_PF_HI OR
                       st = M_CP_LO OR st = M_CP_LO_W OR st = M_CP_HI)
             ELSE '0';
  SD_REQ  <= sd_req_i;
  SD_WE   <= sd_we_i;
  SD_ADDR <= std_logic_vector(sd_a_i);
  SD_DIN  <= sd_d_i;
  SD_BE   <= sd_be_i;
  CPU_RDATA <= rd32;

  ----------------------------------------------------------------------------
  -- Scan side (c1): read the displayed half, and raise a toggle when a new
  -- row is wanted.
  ----------------------------------------------------------------------------
  PROCESS (CLK_VGA)
  BEGIN
    IF rising_edge(CLK_VGA) THEN
      SCAN_DATA <= lbuf(to_integer(unsigned(disp_half & COL)));

      IF ROW_GO = '1' THEN
        disp_half <= NOT disp_half;      -- show what the last row fetched
        -- The half just vacated is the one to fill, and it is sent ACROSS with
        -- the request instead of being recomputed on the far side. Two copies
        -- of one fact is how they came to disagree.
        fill_tgt  <= disp_half;
        row_addr  <= ROW_OFFS;
        row_tog   <= NOT row_tog;
      END IF;
    END IF;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- CPU side (c0): a toggle out, a toggle back.
  ----------------------------------------------------------------------------
  PROCESS (CLK_CPU)
  BEGIN
    IF rising_edge(CLK_CPU) THEN
      dn_s     <= dn_s(1 DOWNTO 0) & dn_tog;
      cpu_prev <= CPU_REQ;
      CPU_READY <= '0';

      IF RESET = '1' THEN
        cpu_tog <= '0';
      ELSE
        IF CPU_REQ = '1' AND cpu_prev = '0' THEN
          cpu_tog <= NOT cpu_tog;        -- one request per rising edge of REQ
        END IF;
        IF dn_s(2) /= dn_s(1) THEN
          CPU_READY <= '1';
        END IF;
      END IF;
    END IF;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- The line buffer's write port (c3), driven by the prefetch only.
  ----------------------------------------------------------------------------
  PROCESS (CLK_MEM)
  BEGIN
    IF rising_edge(CLK_MEM) THEN
      IF wr_en = '1' THEN
        lbuf(to_integer(wr_addr)) <= wr_data;
      END IF;
    END IF;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- Memory side (c3): the arbiter and both access sequences.
  ----------------------------------------------------------------------------
  PROCESS (CLK_MEM)
    -- Set inside the CASE, consumed after it. See the note where the pending
    -- flags are updated -- this exists so a request cannot be dispatched and
    -- erased in the same clock.
    VARIABLE take_pf : std_logic;
    VARIABLE take_cp : std_logic;
  BEGIN
    IF rising_edge(CLK_MEM) THEN
      row_s <= row_s(1 DOWNTO 0) & row_tog;
      cpu_s <= cpu_s(1 DOWNTO 0) & cpu_tog;

      take_pf := '0';
      take_cp := '0';
      wr_en   <= '0';

      IF RESET = '1' THEN
        st       <= M_IDLE;
        sd_req_i <= '0';
        pf_pend  <= '0';
        cp_pend  <= '0';
        pf_run   <= '0';
      ELSE
        -- The address and target half travel with the request; the PENDING
        -- FLAGS THEMSELVES are updated after the state machine below, not here.
        IF row_s(2) /= row_s(1) THEN
          pf_base <= unsigned(row_addr);
          pf_half <= fill_tgt;       -- whichever half the scan side vacated
        END IF;

        CASE st IS

          WHEN M_IDLE =>
            sd_req_i <= '0';
            IF pf_pend = '1' THEN
              -- THE PREFETCH WINS. A late CPU cycle is slow software; a late
              -- scanline is on the screen. But winning means going FIRST, not
              -- going alone -- see M_PF_HI_W.
              take_pf := '1';
              pf_col  <= (OTHERS => '0');
              pf_run  <= '1';
              st      <= M_PF_LO;
            ELSIF cp_pend = '1' THEN
              take_cp := '1';
              st      <= M_CP_LO;
            END IF;

          ------------------------------------------------------------------
          -- Prefetch: 40 offsets, two words each, into the idle half.
          ------------------------------------------------------------------
          WHEN M_PF_LO =>
            -- offset*2, as a concatenation: "* 2" in numeric_std returns a
            -- result twice the operand width, which is not what a shift means.
            sd_a_i   <= EGA_BASE + resize((resize(pf_base, 16) + resize(pf_col, 16)) & '0', 24);
            sd_we_i  <= '0';
            sd_req_i <= '1';
            st       <= M_PF_LO_W;

          WHEN M_PF_LO_W =>
            IF SD_ACK = '1' THEN
              word_lo  <= SD_DOUT;
              sd_req_i <= '0';
              st       <= M_PF_HI;
            END IF;

          WHEN M_PF_HI =>
            sd_a_i   <= EGA_BASE + resize((resize(pf_base, 16) + resize(pf_col, 16)) & '0', 24) + 1;
            sd_we_i  <= '0';
            sd_req_i <= '1';
            st       <= M_PF_HI_W;

          WHEN M_PF_HI_W =>
            IF SD_ACK = '1' THEN
              sd_req_i <= '0';
              wr_addr  <= unsigned(pf_half & std_logic_vector(pf_col(5 DOWNTO 0)));
              wr_data  <= SD_DOUT & word_lo;
              wr_en    <= '1';
              IF pf_col = 39 THEN
                pf_run <= '0';
                st     <= M_IDLE;
              ELSE
                pf_col <= pf_col + 1;
                ------------------------------------------------------------
                -- LET THE CPU IN, BETWEEN COLUMNS.
                --
                -- A row fetch is 40 columns and about 16 us. Holding the
                -- memory for all of it starves any CPU access that arrives
                -- during a row -- and busdecode's T >= 128 backstop gives up
                -- at 15.4 us, so the processor was released BEFORE the access
                -- it was waiting for had been served. It then moved on and
                -- changed the address and data the request was still pointing
                -- at. One write lost per row: at roughly 4.9 us a write, every
                -- thirteenth one, which is exactly the period EGAVFY measured.
                --
                -- Each column is a locked pair, so yielding between columns
                -- costs the prefetch nothing it cannot afford: it has 63.5 us
                -- to spend 16 in.
                ------------------------------------------------------------
                IF cp_pend = '1' THEN
                  take_cp := '1';
                  st      <= M_CP_LO;
                ELSE
                  st <= M_PF_LO;
                END IF;
              END IF;
            END IF;

          ------------------------------------------------------------------
          -- CPU: the same two words, read or write.
          ------------------------------------------------------------------
          WHEN M_CP_LO =>
            sd_a_i   <= EGA_BASE + resize(unsigned(cp_offs) & '0', 24);
            sd_we_i  <= cp_we;
            sd_d_i   <= cp_wdata(15 DOWNTO 0);
            sd_be_i  <= cp_wmask(1 DOWNTO 0);    -- planes 1:0 are this word
            sd_req_i <= '1';
            st       <= M_CP_LO_W;

          WHEN M_CP_LO_W =>
            IF SD_ACK = '1' THEN
              rd32(15 DOWNTO 0) <= SD_DOUT;
              sd_req_i          <= '0';
              st                <= M_CP_HI;
            END IF;

          WHEN M_CP_HI =>
            sd_a_i   <= EGA_BASE + resize(unsigned(cp_offs) & '0', 24) + 1;
            sd_we_i  <= cp_we;
            sd_d_i   <= cp_wdata(31 DOWNTO 16);
            sd_be_i  <= cp_wmask(3 DOWNTO 2);    -- planes 3:2
            sd_req_i <= '1';
            st       <= M_CP_HI_W;

          WHEN M_CP_HI_W =>
            IF SD_ACK = '1' THEN
              rd32(31 DOWNTO 16) <= SD_DOUT;
              sd_req_i           <= '0';
              sd_be_i            <= "11";
              dn_tog             <= NOT dn_tog;
              -- Back to the row fetch if one was interrupted.
              IF pf_run = '1' THEN
                st <= M_PF_LO;
              ELSE
                st <= M_IDLE;
              END IF;
            END IF;

        END CASE;

        ------------------------------------------------------------------
        -- THE PENDING FLAGS, LAST, AND SET BEATS CLEAR.
        --
        -- These used to be raised BEFORE the state machine and cleared inside
        -- it. Both assign the same signal in the same clock and the later one
        -- wins, so a request that arrived in the exact clock the machine
        -- dispatched the previous one was ERASED -- the old one was served and
        -- the new one vanished without trace.
        --
        -- For the CPU that meant a write with no acknowledgement: busdecode's
        -- T >= 128 backstop released the processor 15 us later and the write
        -- was simply gone. Rare when writes are spaced, common under a tight
        -- REP STOSB -- which is exactly how the symptom presented, as a
        -- verifier that failed on its first pass and passed on every one after
        -- it, because the second pass only had to rewrite what the first had
        -- dropped.
        --
        -- For the prefetch it meant a whole scanline never fetched, showing
        -- the row before it instead.
        ------------------------------------------------------------------
        IF row_s(2) /= row_s(1) THEN
          pf_pend <= '1';
        ELSIF take_pf = '1' THEN
          pf_pend <= '0';
        END IF;

        -- CAPTURE THE REQUEST WITH THE FLAG. The address, data and mask used
        -- to be read live from the ports when the access was finally served,
        -- which is only safe if the CPU is still waiting -- and it is not,
        -- once the backstop has released it. Taking a copy here makes the
        -- request self-contained no matter how long it waits.
        IF cpu_s(2) /= cpu_s(1) THEN
          cp_pend  <= '1';
          cp_offs  <= CPU_OFFS;
          cp_wdata <= CPU_WDATA;
          cp_wmask <= CPU_WMASK;
          cp_we    <= CPU_WE;
        ELSIF take_cp = '1' THEN
          cp_pend <= '0';
        END IF;
      END IF;
    END IF;
  END PROCESS;

END behavior;
