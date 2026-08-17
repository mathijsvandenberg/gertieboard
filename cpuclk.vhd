--------------------------------------------------------------------------------
-- cpuclk.vhd  --  the programmable CPU / bus clock, and I/O port 0xE5
--
-- The machine's speed used to be a line in pll.vhd. Changing it meant editing
-- the PLL, rebuilding, reprogramming, and then remembering which of the three
-- artefacts on the bench was which -- an hour was once spent testing 8.333 MHz
-- in the belief it was 6.25 (see tools/mkfpga.sh). With the D70108HCZ-16 parts
-- there is a whole ladder to walk, so the ladder is in hardware now and the
-- step is a register the CPU can write.
--
--     OUT 0xE5, AL   AL(2:0) = step, clamped to MAX_IDX. Nothing else is used.
--     IN  AL, 0xE5   bit 7   = 0  -> speed control exists in this bitstream
--                              (an absent one reads open-bus 0xFF, bit 7 = 1)
--                    bits 6:4 = MAX_IDX, the fastest step this bitstream allows
--                    bits 2:0 = the step in force now
--
-- RESET restores DEF_IDX, for ctrl_reg's reason: a step the board cannot run is
-- otherwise unrecoverable, because the code that would write a slower one can no
-- longer be fetched. The reset button and Ctrl+Alt+Del both get you back.
--
-- ---------------------------------------------------------------------------
--  The ladder
-- ---------------------------------------------------------------------------
-- The clock is a counter off the PLL's 100 MHz c0, held high for HI cycles and
-- low for LO cycles:
--
--   idx  hi  lo  f_cpu      period   duty   note
--    0   10  10  5.000 MHz  200 ns   50 %   what this board ran at for years
--    1    8   8  6.250      160 ns   50 %
--    2    6   8  7.143      140 ns   43 %
--    3    6   6  8.333      120 ns   50 %   DEFAULT -- the speed before this file
--    4    4   6 10.000      100 ns   40 %   the P2120's turbo speed
--    5    4   4 12.500       80 ns   50 %
--    6    2   4 16.667       60 ns   33 %   the -16 parts' rated ceiling
--    7    2   2 25.000       40 ns   50 %   past the rating; only if MAX_IDX allows
--
-- The one property that has to hold at every step is that BOTH EDGES LAND ON
-- c3's 20 ns GRID. Rising edges keep this clock integer-related to c3 -- the
-- constraint that killed the 8 MHz attempt (a c3 edge 5 ns from a bus-clock
-- edge, -3.28 ns of slack, nothing able to absorb it) -- and it means the
-- crossings to the 50 MHz side are analysed at a 20 ns requirement whatever the
-- step is. Falling edges matter for a reason found on hardware and written up
-- against HI_TAB/LO_TAB below: with 50 % duty every ODD step died, including
-- one SLOWER than a step that works.
--
-- 50/9 = 5.556 MHz is not on the ladder. It fits the grid perfectly well
-- (80/100 ns) and could be added: it was excluded because the host link used to
-- be an integer divide of the bus clock and 5.556 had no good divisor. The UART
-- runs on its own fixed clock now, so that reason has expired -- the step is
-- missing only because renumbering the ladder costs more than it is worth.
--
-- ---------------------------------------------------------------------------
--  Changing step without producing a runt
-- ---------------------------------------------------------------------------
-- This clock feeds the entire bus AND the CPU pin, so a short pulse during a
-- change is not a glitch, it is a crash. A new divisor is therefore adopted
-- only at the instant the clock is about to go HIGH, i.e. on a period boundary,
-- and both halves of every period use the same value. The shortest half-period
-- the design can ever emit is 2 x 10 ns, whatever is written and whenever.
--
-- The step register runs on the generated clock (it has to see an I/O cycle);
-- the divider runs on 100 MHz. The three-stage synchroniser between them
-- adopts a value only after seeing it twice, so the one-sample skew while three
-- bits change cannot be mistaken for a step of its own.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;

ENTITY cpuclk IS
  GENERIC (
        -- The fastest step this bitstream will accept. The SDC constrains the
        -- design at exactly this step, so it is also the promise the timing
        -- report is checking: raise it only together with gertieboard.sdc, and
        -- only as far as the fitter will actually close.
        MAX_IDX : integer RANGE 0 TO 7 := 6;
        -- The step after every reset.
        DEF_IDX : integer RANGE 0 TO 7 := 3);
  PORT(
        CLK100   : IN    std_logic;                       -- pll1 c0, 100 MHz
        RESET_N  : IN    std_logic;                       -- RAW reset, active LOW
        -- I/O interface, on the generated clock
        ADDR     : IN    std_logic_vector(15 DOWNTO 0);
        DATA     : IN    std_logic_vector(7 DOWNTO 0);
        RD       : IN    std_logic;                       -- active-low I/O read
        WR       : IN    std_logic;                       -- active-low I/O write
        DATAOUT  : INOUT std_logic_vector(7 DOWNTO 0);
        -- the clock itself
        CLK_CPU  : OUT   std_logic;   -- internal bus clock, on c3's 20 ns grid
        -- The same clock delayed half a 100 MHz period (5 ns), for the CPU pin
        -- ONLY. See the note at its process. Drive CPU_CLK from this, never
        -- from CLK_CPU, or the 5 ns of READY aperture goes away silently.
        CLK_CPU_PAD : OUT std_logic;
        -- everything downstream that is tuned in clocks and has to stay tuned
        -- in seconds. See the tables below.
        OPL_SMP  : OUT   integer RANGE 1 TO 1023;
        OPL_T1   : OUT   integer RANGE 1 TO 8191;
        OPL_T2   : OUT   integer RANGE 1 TO 8191);
END cpuclk;

ARCHITECTURE behavior OF cpuclk IS

  TYPE tab_t IS ARRAY(0 TO 7) OF integer;

  -- 100 MHz cycles the clock is HIGH and LOW.  f_cpu = 100e6 / (hi + lo).
  --
  -- These are not equal at every step, and that is the whole point. The first
  -- version of this file insisted on a 50 % duty cycle, which forces the
  -- FALLING edge to hi*10 ns -- off c3's 20 ns grid whenever that is odd. On
  -- hardware the odd steps died: 7.143 MHz could not execute a two-byte loop
  -- with interrupts off, at a LOWER clock and lower current draw than the
  -- 8.333 MHz the same machine runs all day. Nothing about speed or power
  -- explains that; the edge alignment does.
  --
  -- 50 % was self-imposed and wrong. An 8088/V20 is built around an 8284, which
  -- delivers a 33 % duty cycle -- so the odd steps are split to put BOTH edges
  -- on the 20 ns grid instead, and the duty falls out of that:
  --
  --   idx  hi  lo  period    f_cpu      duty   rise    fall
  --    0   10  10  200 ns    5.000 MHz  50 %   0/200   100   both on grid
  --    1    8   8  160 ns    6.250      50 %   0/160    80   both on grid
  --    2    6   8  140 ns    7.143      43 %   0/140    60   both on grid
  --    3    6   6  120 ns    8.333      50 %   0/120    60   both on grid
  --    4    4   6  100 ns   10.000      40 %   0/100    40   both on grid
  --    5    4   4   80 ns   12.500      50 %   0/80     40   both on grid
  --    6    2   4   60 ns   16.667      33 %   0/60     20   both on grid
  --    7    2   2   40 ns   25.000      50 %   0/40     20   both on grid
  --
  -- The even steps are unchanged, waveform for waveform, so this cannot disturb
  -- anything that already works. 16.667 MHz lands on 20 ns high, which is what
  -- an 8284 gives a 16 MHz part -- the objection that ruled out dividing 50 MHz
  -- directly turns out to have been an objection to the CORRECT waveform.
  CONSTANT HI_TAB : tab_t := (10, 8, 6, 6, 4, 4, 2, 2);
  CONSTANT LO_TAB : tab_t := (10, 8, 8, 6, 6, 4, 4, 2);

  -- There is deliberately NO baud table here any more. The host link used to be
  -- an integer divide of the bus clock, so it had to be re-derived per step and
  -- was +4.2 % at the step the machine boots at. fdc8272 now clocks its UART
  -- from c3 instead, where 50e6/50 = 1,000,000 exactly at every step -- so the
  -- link is no longer a function of the speed at all, and a table that made it
  -- one would only be a second place for the truth to live.
  -- opl2_lite: sample clock (49716 Hz) and the two detection timers (80 us and
  -- 320 us). CLK_HZ/49716, CLK_HZ/12500, CLK_HZ/3125, truncated exactly as the
  -- module's own constants were.
  CONSTANT SMP_TAB : tab_t := (100, 125, 143, 167, 201, 251, 335, 502);
  CONSTANT T1_TAB  : tab_t := (400, 500, 571, 666, 800, 1000, 1333, 2000);
  CONSTANT T2_TAB  : tab_t := (1600, 2000, 2285, 2666, 3200, 4000, 5333, 8000);

  CONSTANT DEF_SLV : std_logic_vector(2 DOWNTO 0) :=
      CONV_STD_LOGIC_VECTOR(DEF_IDX, 3);
  CONSTANT MAX_SLV : std_logic_vector(2 DOWNTO 0) :=
      CONV_STD_LOGIC_VECTOR(MAX_IDX, 3);

  -- ---- generated-clock domain ----
  SIGNAL idx_q  : std_logic_vector(2 DOWNTO 0) := DEF_SLV;
  SIGNAL rstn_c : std_logic_vector(1 DOWNTO 0) := "00";

  -- ---- 100 MHz domain ----
  SIGNAL rstn_s : std_logic_vector(1 DOWNTO 0) := "00";
  SIGNAL idx_s1, idx_s2, idx_s3 : std_logic_vector(2 DOWNTO 0) := DEF_SLV;
  SIGNAL idx_ok   : std_logic_vector(2 DOWNTO 0) := DEF_SLV;
  SIGNAL hi_sel : integer RANGE 2 TO 10 := HI_TAB(DEF_IDX);
  SIGNAL lo_sel : integer RANGE 2 TO 10 := LO_TAB(DEF_IDX);
  SIGNAL hi_r   : integer RANGE 2 TO 10 := HI_TAB(DEF_IDX);
  SIGNAL lo_r   : integer RANGE 2 TO 10 := LO_TAB(DEF_IDX);
  SIGNAL cnt    : integer RANGE 0 TO 10 := HI_TAB(DEF_IDX);
  SIGNAL clk_q  : std_logic := '0';
  SIGNAL clk_pad : std_logic := '0';   -- clk_q delayed 5 ns, for the CPU pin

BEGIN

  ------------------------------------------------------------------------------
  -- The divider, on 100 MHz.
  ------------------------------------------------------------------------------
  -- RESET_N is the RAW reset, not clkgen's RST_OUT, for the same reason
  -- mem_hybrid takes the raw one: clkgen is clocked BY this output, so gating
  -- the clock generator with the reset that clkgen produces is a loop with no
  -- way in. It is a button in another domain either way, so it is synchronised
  -- here and nowhere else.
  PROCESS (CLK100)
  BEGIN
    IF rising_edge(CLK100) THEN
      rstn_s <= rstn_s(0) & RESET_N;

      -- three stages, then adopt only a value seen twice. idx_s1 may be
      -- metastable and is never compared; idx_s2/idx_s3 are clean. While the
      -- three bits of a new step land in different samples the pair disagrees,
      -- so the intermediate combination -- which could be a FASTER step than
      -- either the old or the new one -- never reaches the counter.
      idx_s1 <= idx_q;
      idx_s2 <= idx_s1;
      idx_s3 <= idx_s2;
      IF idx_s3 = idx_s2 THEN
        idx_ok <= idx_s3;
      END IF;

      IF cnt <= 1 THEN
        clk_q <= NOT clk_q;
        IF clk_q = '0' THEN
          -- about to go high: a whole period starts here, so this is the one
          -- place a new step may be taken. Both halves then come from the same
          -- pair, so a period is never half of one step and half of another.
          hi_r <= hi_sel;
          lo_r <= lo_sel;
          cnt  <= hi_sel;
        ELSE
          cnt <= lo_r;
        END IF;
      ELSE
        cnt <= cnt - 1;
      END IF;
    END IF;
  END PROCESS;

  -- RESET does NOT stop this clock, it only forces the step back to the
  -- default within one period. Two reasons, and both are bugs if you get it
  -- wrong: a V20 needs a running clock THROUGHOUT reset to finish its internal
  -- reset sequence, and the step register below is clocked by this net -- stop
  -- it and the register never sees the reset that is supposed to clear it.
  hi_sel <= HI_TAB(DEF_IDX) WHEN rstn_s(1) = '0'
       ELSE HI_TAB(CONV_INTEGER(idx_ok));
  lo_sel <= LO_TAB(DEF_IDX) WHEN rstn_s(1) = '0'
       ELSE LO_TAB(CONV_INTEGER(idx_ok));

  CLK_CPU <= clk_q;

  ------------------------------------------------------------------------------
  -- THE CPU'S OWN COPY OF THE CLOCK, DELIBERATELY 5 ns LATE.
  --
  -- clk_q toggles on the RISING edge of CLK100, so re-registering it on the
  -- FALLING edge produces the same waveform delayed by exactly half a 100 MHz
  -- period. Not approximately: the delay is a clock edge, so it is the same at
  -- every speed step, every corner and every build, which is the whole point.
  --
  -- WHY. READY has to be valid by CLK-fall AT THE CPU plus tSRYLK, and holding
  -- the CPU's clock back hands that time straight to READY. The SDC already
  -- does this with a 2.5 ns min-delay on the pad -- this is the same lever,
  -- an order of magnitude larger, and in the fabric where it can be guaranteed
  -- rather than at a pad where the fitter could only ever promise ~2.7 ns.
  --
  -- The board said it needed this before the analysis could. With the pad at
  -- maximum drive the machine would not fetch its BIOS at all; a FINGER on
  -- CPU_CLK -- tens of picofarads, a few hundred ps -- got it to boot. Dropping
  -- the pad to 4 mA bought 0.225 ns and left it "barely booting, no keyboard".
  -- The requirement is nanoseconds, and only a clock edge supplies those.
  --
  -- It costs nothing on the other side. Read data must be valid tSDK before the
  -- same edge, so moving that edge LATER helps data setup too; the budget there
  -- has ~29 ns spare in any case. Only the CPU's own outputs shift, and they
  -- shift together with the clock they are referenced to.
  --
  -- The INTERNAL bus clock is untouched: peripherals still run on clk_q, which
  -- keeps every edge on c3's 20 ns grid. Only the pin moves off it, and nothing
  -- inside the FPGA is clocked by the pin.
  ------------------------------------------------------------------------------
  PROCESS (CLK100)
  BEGIN
    IF falling_edge(CLK100) THEN
      clk_pad <= clk_q;
    END IF;
  END PROCESS;

  CLK_CPU_PAD <= clk_pad;

  ------------------------------------------------------------------------------
  -- The step register, on the clock it controls. Same shape as ctrl_reg: watch
  -- the address bus and the active-low write strobe, and let the last sample
  -- while WR is low win -- write data is stable for the whole of it.
  ------------------------------------------------------------------------------
  PROCESS (clk_q)
  BEGIN
    IF rising_edge(clk_q) THEN
      rstn_c <= rstn_c(0) & RESET_N;
      IF rstn_c(1) = '0' THEN
        idx_q <= DEF_SLV;
      ELSIF (WR = '0' AND ADDR = x"00E5") THEN
        -- Clamp rather than ignore. A step this bitstream was not built and
        -- timed for is the one write that cannot be diagnosed afterwards, so
        -- asking for it gets you the fastest one that WAS timed, and the
        -- read-back says so.
        IF CONV_INTEGER(DATA(2 DOWNTO 0)) > MAX_IDX THEN
          idx_q <= MAX_SLV;
        ELSE
          idx_q <= DATA(2 DOWNTO 0);
        END IF;
      END IF;
    END IF;
  END PROCESS;

  DATAOUT <= ('0' & MAX_SLV & '0' & idx_q)
                 WHEN (RD = '0' AND ADDR = x"00E5") ELSE "ZZZZZZZZ";

  ------------------------------------------------------------------------------
  -- Everything that is counted in bus clocks but has to come out in seconds.
  -- These are combinational off the register, and the modules that use them
  -- run on the same clock, so there is no crossing here at all.
  ------------------------------------------------------------------------------
  OPL_SMP  <= SMP_TAB(CONV_INTEGER(idx_q));
  OPL_T1   <= T1_TAB(CONV_INTEGER(idx_q));
  OPL_T2   <= T2_TAB(CONV_INTEGER(idx_q));

END behavior;
