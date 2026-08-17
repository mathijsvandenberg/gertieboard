--------------------------------------------------------------------------------
-- sdram_ctrl.vhd  --  the DE0-Nano's 32 MB SDRAM
--
-- ISSI IS42S16160B: four banks, 8192 rows, 512 columns, 16 bits wide. That is
-- 256 Mbit = 32 MB, and it has been sitting unused on the board since day one --
-- docs/hardware.md listed it as "no, main memory is the top board's PSRAM".
--
-- It is here because the EGA planes do not fit in M9K. Mode 0Dh needs a second
-- display page at offset 0x2000 (King's Quest saves the area under its text
-- windows there) and Keen 4 needs a 640-pixel logical line; both want 16 KB per
-- plane against the 8 KB that fits on-chip, and four 16 KB planes would need 64
-- M9K blocks when only 42 could ever be freed. Here it is 64 KB out of 32 MB.
--
-- ---------------------------------------------------------------------------
-- DELIBERATELY SIMPLE
--
-- One access at a time: ACTIVATE, then READ or WRITE with auto-precharge, then
-- back to idle. No open-row tracking, no bank interleaving, no bursts. Those
-- are worth real bandwidth and they are also where SDRAM controllers go wrong,
-- so they are not in the first version -- and this design does not need them:
--
--     a scanline of mode 0Dh is 40 bytes x 4 planes = 80 words
--     at ~10 clocks each that is ~16 us, against 63.5 us per doubled scanline
--
-- so even the worst case fetches a whole line in a quarter of the time it has.
-- If that ever stops being true the answer is a full-page burst, not a rewrite.
--
-- ---------------------------------------------------------------------------
-- REFRESH IS NOT OPTIONAL AND MUST NOT BE STARVED
--
-- 8192 rows in 64 ms is one refresh every 7.8 us, which is 390 clocks at 50 MHz.
-- The counter runs regardless of what else is happening and sets a pending flag;
-- the idle state serves refresh BEFORE it serves a request. A controller that
-- lets a busy master crowd refresh out looks perfect on a logic analyser and
-- corrupts memory minutes later, in a pattern that reads as anything but a
-- memory fault. It is the single easiest thing to get wrong here.
--
-- ---------------------------------------------------------------------------
-- DRAM_CLK
--
-- Driven from the INVERTED controller clock, so the part latches on its rising
-- edge while this design changes its outputs on ours -- half a clock of setup
-- and half of hold, for free, with no PLL phase tap. At 50 MHz on a -7 part
-- that is a comfortable margin. If it ever needs tightening, the proper fix is
-- a phase-shifted PLL output rather than moving logic around.
--
-- Wiring (top level): CLK <- n_c3 (50 MHz). Everything else is the SDRAM's own
-- dedicated pins, which are not shared with the GPIO headers the top board uses.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;
USE  IEEE.NUMERIC_STD.ALL;

ENTITY sdram_ctrl IS
  GENERIC (
        CLK_HZ    : integer := 50_000_000);
  PORT(
        CLK       : IN    std_logic;
        RESET     : IN    std_logic;                      -- active HIGH

        -- Client side. Raise REQ with the address and hold it until ACK.
        REQ       : IN    std_logic;
        WE        : IN    std_logic;                      -- '1' = write
        ADDR      : IN    std_logic_vector(23 DOWNTO 0);  -- WORD address
        DIN       : IN    std_logic_vector(15 DOWNTO 0);
        BE        : IN    std_logic_vector(1 DOWNTO 0);   -- byte enables, write
        DOUT      : OUT   std_logic_vector(15 DOWNTO 0);
        ACK       : OUT   std_logic;                      -- one clock, data valid
        BUSY      : OUT   std_logic;
        INIT_DONE : OUT   std_logic;
        -- Which state the machine is in, so a stall can be READ rather than
        -- reasoned about. Everything about this file looked correct on paper
        -- while init was not completing on the board.
        DBG_STATE : OUT   std_logic_vector(3 DOWNTO 0);

        -- The chip
        DRAM_ADDR : OUT   std_logic_vector(12 DOWNTO 0);
        DRAM_BA   : OUT   std_logic_vector(1 DOWNTO 0);
        DRAM_DQ   : INOUT std_logic_vector(15 DOWNTO 0);
        DRAM_DQM  : OUT   std_logic_vector(1 DOWNTO 0);
        DRAM_CLK  : OUT   std_logic;
        DRAM_CKE  : OUT   std_logic;
        DRAM_CS_N : OUT   std_logic;
        DRAM_RAS_N: OUT   std_logic;
        DRAM_CAS_N: OUT   std_logic;
        DRAM_WE_N : OUT   std_logic);
END sdram_ctrl;

ARCHITECTURE behavior OF sdram_ctrl IS

  -- Timing, in clocks at CLK_HZ. Rounded UP, and never to zero.
  CONSTANT T_INIT : integer := CLK_HZ / 10000;   -- 100 us power-on pause
  CONSTANT T_REF  : integer := CLK_HZ / 128000;  -- 7.8 us between refreshes
  CONSTANT T_RCD  : integer := 2;                -- activate -> read/write, 20 ns
  CONSTANT T_RP   : integer := 2;                -- precharge, 20 ns
  CONSTANT T_RFC  : integer := 4;                -- refresh cycle, 60-70 ns
  -- Auto-refreshes in the POWER-UP sequence. This was 2, and 2 is not a
  -- number any datasheet for this part gives: vendors specify either "a
  -- minimum of two" (Micron's MT48LC wording) or "8 auto-refresh cycles"
  -- (ISSI, which is what is actually fitted here -- IS42S16160B). 8 satisfies
  -- both readings, so it is the number that is correct whichever part ends up
  -- on the board.
  --
  -- It costs nothing worth counting: 8 x T_RFC = 32 clocks = 640 ns, ONCE, at
  -- power-on, inside a 100 us pause that already precedes it.
  --
  -- Not raised beyond 8 despite the temptation. Extra refreshes past the spec
  -- do not buy robustness against a marginal power-up -- what would is a
  -- longer T_INIT, letting the rails settle further before the first command,
  -- and that is a separate change with a separate justification.
  CONSTANT INIT_REF : integer := 8;
  CONSTANT T_MRD  : integer := 2;                -- mode register set
  CONSTANT CAS_LAT: integer := 2;

  -- Mode register: burst length 1, sequential, CAS latency 2, single writes.
  -- A(2:0)=000 BL1, A3=0 sequential, A(6:4)=010 CL2, A9=0 burst read AND write.
  CONSTANT MODE_REG : std_logic_vector(12 DOWNTO 0) := "0000000100000";

  -- Commands, as {CS, RAS, CAS, WE}
  SUBTYPE cmd_t IS std_logic_vector(3 DOWNTO 0);
  CONSTANT CMD_NOP    : cmd_t := "0111";
  CONSTANT CMD_ACT    : cmd_t := "0011";
  CONSTANT CMD_READ   : cmd_t := "0101";
  CONSTANT CMD_WRITE  : cmd_t := "0100";
  CONSTANT CMD_PRE    : cmd_t := "0010";
  CONSTANT CMD_REF    : cmd_t := "0001";
  CONSTANT CMD_MRS    : cmd_t := "0000";
  CONSTANT CMD_INHIB  : cmd_t := "1111";

  TYPE state_t IS (S_RESET, S_INIT_WAIT, S_INIT_PRE, S_INIT_REF, S_INIT_MRS,
                   S_IDLE, S_ACT, S_RW, S_READ_WAIT, S_DONE, S_REFRESH);
  SIGNAL st : state_t := S_RESET;

  SIGNAL cmd    : cmd_t := CMD_INHIB;
  SIGNAL tmr    : integer RANGE 0 TO T_INIT := 0;
  SIGNAL refcnt : integer RANGE 0 TO T_REF  := 0;
  SIGNAL ref_due: std_logic := '0';
  -- Auto-refreshes done so far in init. The range must reach INIT_REF, not
  -- stop one below it: the count is compared BEFORE the increment, so the
  -- signal really does take the value INIT_REF before the state advances.
  -- Left at "RANGE 0 TO 7" with INIT_REF = 8 this would wrap to 0 in three
  -- bits, the compare would never be satisfied, init would never finish and
  -- MEM_READY would never assert -- a machine that hangs before the CPU is
  -- even released, from a constant that looked like a comment change.
  SIGNAL initn  : integer RANGE 0 TO INIT_REF := 0;

  SIGNAL a_row  : std_logic_vector(12 DOWNTO 0);
  SIGNAL a_col  : std_logic_vector(8 DOWNTO 0);
  SIGNAL a_bank : std_logic_vector(1 DOWNTO 0);

  SIGNAL dq_out : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL dq_oe  : std_logic := '0';
  SIGNAL rd_reg : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ack_i  : std_logic := '0';
  SIGNAL init_i : std_logic := '0';
  -- A client holds REQ until it sees ACK, so REQ is STILL HIGH when the state
  -- machine returns to idle. Without this the same access would start again
  -- immediately, for ever. Rearmed only when REQ actually goes low.
  SIGNAL armed  : std_logic := '1';

BEGIN

  -- The address split. Column low, then bank, then row: consecutive words stay
  -- in one row, so a scanline fetch never leaves the row it started in.
  a_col  <= ADDR(8 DOWNTO 0);
  a_bank <= ADDR(10 DOWNTO 9);
  a_row  <= ADDR(23 DOWNTO 11);

  DRAM_CS_N  <= cmd(3);
  DRAM_RAS_N <= cmd(2);
  DRAM_CAS_N <= cmd(1);
  DRAM_WE_N  <= cmd(0);
  DRAM_CKE   <= '1';
  DRAM_CLK   <= NOT CLK;             -- see the note at the top
  DRAM_BA    <= a_bank;
  DRAM_DQ    <= dq_out WHEN dq_oe = '1' ELSE (OTHERS => 'Z');

  DOUT       <= rd_reg;
  ACK        <= ack_i;
  INIT_DONE  <= init_i;
  BUSY       <= '0' WHEN st = S_IDLE ELSE '1';

  WITH st SELECT DBG_STATE <=
      x"0" WHEN S_RESET,     x"1" WHEN S_INIT_WAIT, x"2" WHEN S_INIT_PRE,
      x"3" WHEN S_INIT_REF,  x"4" WHEN S_INIT_MRS,  x"5" WHEN S_IDLE,
      x"6" WHEN S_ACT,       x"7" WHEN S_RW,        x"8" WHEN S_READ_WAIT,
      x"9" WHEN S_DONE,      x"A" WHEN S_REFRESH,   x"F" WHEN OTHERS;

  PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN

      ----------------------------------------------------------------------
      -- The refresh clock. Free-running, and independent of everything else
      -- in this file on purpose: nothing a client does can slow it down.
      ----------------------------------------------------------------------
      IF refcnt >= T_REF THEN
        refcnt  <= 0;
        ref_due <= '1';
      ELSE
        refcnt <= refcnt + 1;
      END IF;

      cmd      <= CMD_NOP;
      ack_i    <= '0';
      dq_oe    <= '0';
      DRAM_DQM <= "00";

      IF REQ = '0' THEN
        armed <= '1';
      END IF;

      IF RESET = '1' THEN
        st     <= S_RESET;
        tmr    <= 0;
        initn  <= 0;
        init_i <= '0';
        armed  <= '1';
        cmd    <= CMD_INHIB;

      ELSE
        CASE st IS

          ----------------------------------------------------------------
          -- Power-on: hold everything inert for 100 us, then precharge all
          -- banks, issue INIT_REF auto-refreshes, and load the mode register.
          -- The ORDER is the part's, not a preference -- and so is the COUNT,
          -- which this used to get wrong. See INIT_REF.
          ----------------------------------------------------------------
          WHEN S_RESET =>
            cmd <= CMD_INHIB;
            tmr <= T_INIT;
            st  <= S_INIT_WAIT;

          WHEN S_INIT_WAIT =>
            cmd <= CMD_INHIB;
            IF tmr = 0 THEN
              st  <= S_INIT_PRE;
            ELSE
              tmr <= tmr - 1;
            END IF;

          WHEN S_INIT_PRE =>
            cmd       <= CMD_PRE;
            DRAM_ADDR <= (10 => '1', OTHERS => '0');   -- A10 = all banks
            tmr       <= T_RP;
            initn     <= 0;
            st        <= S_INIT_REF;

          WHEN S_INIT_REF =>
            IF tmr /= 0 THEN
              tmr <= tmr - 1;
            ELSIF initn < INIT_REF THEN
              cmd   <= CMD_REF;
              initn <= initn + 1;
              tmr   <= T_RFC;
            ELSE
              cmd       <= CMD_MRS;
              DRAM_ADDR <= MODE_REG;
              tmr       <= T_MRD;
              st        <= S_INIT_MRS;
            END IF;

          WHEN S_INIT_MRS =>
            IF tmr = 0 THEN
              init_i <= '1';
              st     <= S_IDLE;
            ELSE
              tmr <= tmr - 1;
            END IF;

          ----------------------------------------------------------------
          -- Idle. REFRESH FIRST -- see the note at the top of the file.
          ----------------------------------------------------------------
          WHEN S_IDLE =>
            IF ref_due = '1' THEN
              cmd     <= CMD_REF;
              ref_due <= '0';
              tmr     <= T_RFC;
              st      <= S_REFRESH;
            ELSIF REQ = '1' AND armed = '1' THEN
              cmd       <= CMD_ACT;
              DRAM_ADDR <= a_row;
              tmr       <= T_RCD;
              armed     <= '0';
              st        <= S_ACT;
            END IF;

          WHEN S_REFRESH =>
            IF tmr = 0 THEN
              st <= S_IDLE;
            ELSE
              tmr <= tmr - 1;
            END IF;

          ----------------------------------------------------------------
          -- One access: activate, read or write with auto-precharge, done.
          ----------------------------------------------------------------
          WHEN S_ACT =>
            IF tmr = 0 THEN
              st <= S_RW;
            ELSE
              tmr <= tmr - 1;
            END IF;

          WHEN S_RW =>
            -- A10 = 1 selects auto-precharge, so the row closes itself and
            -- there is no open-row state to keep track of anywhere.
            -- 12:11 unused, 10 = auto-precharge, 9 unused, 8:0 = column
            DRAM_ADDR <= "00" & '1' & '0' & a_col;
            IF WE = '1' THEN
              cmd      <= CMD_WRITE;
              dq_out   <= DIN;
              dq_oe    <= '1';
              DRAM_DQM <= NOT BE;        -- DQM high MASKS the byte
              tmr      <= T_RP;
              st       <= S_DONE;
            ELSE
              cmd <= CMD_READ;
              tmr <= CAS_LAT;
              st  <= S_READ_WAIT;
            END IF;

          WHEN S_READ_WAIT =>
            IF tmr = 0 THEN
              rd_reg <= DRAM_DQ;
              ack_i  <= '1';
              tmr    <= T_RP;
              st     <= S_DONE;
            ELSE
              tmr <= tmr - 1;
            END IF;

          WHEN S_DONE =>
            -- tRP after the auto-precharge before anything else may start.
            -- The write's ACK lands here so a client sees one pulse either way.
            IF tmr = 0 THEN
              st <= S_IDLE;
            ELSE
              IF tmr = T_RP AND WE = '1' THEN
                ack_i <= '1';
              END IF;
              tmr <= tmr - 1;
            END IF;

        END CASE;
      END IF;
    END IF;
  END PROCESS;

END behavior;
