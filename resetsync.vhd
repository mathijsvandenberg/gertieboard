--------------------------------------------------------------------------------
-- resetsync.vhd  --  turn a mechanical button into one clean reset
--
-- The reset button used to arrive as a raw pin in a combinational term:
--
--     n_reset <= RESET AND NOT n_cad_rst AND n_pll_locked;
--
-- and that signal was then sampled by clkgen on the CPU clock AND used as
-- n_mem_rst by the memory controller on c3. Two clock domains, one
-- asynchronous input, no synchroniser anywhere.
--
-- WHY THAT IS WORSE THAN IT LOOKS. A mechanical contact bounces for a few
-- milliseconds, so a single press is tens of edges. Every one of them is
-- sampled by two different clocks, and a transition close to an edge can
-- leave a flip-flop metastable -- which means THE TWO DOMAINS CAN DISAGREE
-- ABOUT WHETHER A RESET HAPPENED. The CPU restarts while the memory
-- controller does not, or the reverse, and what the machine does next depends
-- on which. That is an excellent match for a reset button that "often" gives
-- a POST code rather than a boot, and it explains why it is intermittent
-- rather than repeatable.
--
-- Bounce on RELEASE is the nastier half. Bounce while pressing just restarts a
-- reset that is already happening; bounce as the contact opens can drop a
-- reset pulse into a machine that has already started running.
--
-- WHAT THIS DOES
--   * three flops to bring the pin into c3 before anything looks at it
--   * a debounce: the level must hold steady for DEBOUNCE_MS before it counts
--   * a stretch: any accepted press produces at least HOLD_MS of reset, so a
--     stab at the button is the same as leaning on it
--
-- The output is a clean, slow, single-transition level. It is still sampled by
-- clkgen on another clock, and that is fine: the hazard was never a level
-- crossing domains, it was a level that changed tens of times per press.
--
-- Timing is deliberately generous. Reset happens once and costs nothing, and
-- every fault this board has had in this area came from something being too
-- short rather than too long.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;
USE  IEEE.NUMERIC_STD.ALL;

ENTITY resetsync IS
  GENERIC(
        CLK_HZ      : integer := 50_000_000;
        DEBOUNCE_MS : integer := 20;      -- contact must be steady this long
        HOLD_MS     : integer := 200);    -- and reset lasts at least this long
  PORT(
        CLK      : IN  std_logic;         -- c3, fixed 50 MHz, not the ladder
        LOCKED   : IN  std_logic;         -- pll1 locked
        BTN_N    : IN  std_logic;         -- the button pin, active LOW
        CAD_RST  : IN  std_logic;         -- Ctrl+Alt+Del, active high
        RESET_N  : OUT std_logic);        -- clean, active low
END resetsync;

ARCHITECTURE rtl OF resetsync IS

  -- COUNTED IN MILLISECONDS, not in clocks. 200 ms at 50 MHz is ten million,
  -- which is a 24-bit down-counter and a 24-bit "/= 0" sitting in a design
  -- whose tightest path is already the CPU READY aperture. A prescaler to
  -- 1 ms and two byte-wide counters do the same job in a third of the
  -- registers and with comparators narrow enough to place anywhere.
  CONSTANT TICK_N : integer := CLK_HZ / 1000;

  -- THREE flops, not two. The extra one costs nothing and this input is a bare
  -- pin with a human on the end of it -- the one place in the design where the
  -- source is genuinely asynchronous to everything.
  SIGNAL sync    : std_logic_vector(2 DOWNTO 0) := "111";
  SIGNAL stable  : std_logic := '1';                       -- debounced level
  SIGNAL presc   : integer RANGE 0 TO TICK_N-1 := 0;
  SIGNAL tick    : std_logic := '0';                       -- one CLK per ms
  SIGNAL deb_cnt : integer RANGE 0 TO DEBOUNCE_MS := 0;

  -- Starts at full, so a design that has only just come out of configuration
  -- holds reset rather than releasing it while the counters are still zero.
  SIGNAL hold    : integer RANGE 0 TO HOLD_MS := HOLD_MS;

BEGIN

  RESET_N <= '0' WHEN (hold /= 0) OR (LOCKED = '0') ELSE '1';

  PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      sync <= sync(1 DOWNTO 0) & BTN_N;

      tick <= '0';
      IF presc = TICK_N-1 THEN
        presc <= 0;
        tick  <= '1';
      ELSE
        presc <= presc + 1;
      END IF;

      -- ---- debounce ----
      -- The counter restarts every time the input disagrees with the level we
      -- have accepted, so bounce keeps it pinned near zero and the accepted
      -- level only moves after the contact has been quiet for the whole
      -- window. That is what makes tens of edges into one.
      IF sync(2) = stable THEN
        deb_cnt <= 0;
      ELSIF tick = '1' THEN
        IF deb_cnt = DEBOUNCE_MS-1 THEN
          deb_cnt <= 0;
          stable  <= sync(2);
        ELSE
          deb_cnt <= deb_cnt + 1;
        END IF;
      END IF;

      -- ---- stretch ----
      -- Reload while any reason to be in reset is true, count down when none
      -- is. So reset is asserted for as long as the button is held AND for
      -- HOLD_MS after it is let go, and a brief press is indistinguishable
      -- from a long one.
      IF (stable = '0') OR (CAD_RST = '1') OR (LOCKED = '0') THEN
        hold <= HOLD_MS;
      ELSIF (hold /= 0) AND (tick = '1') THEN
        hold <= hold - 1;
      END IF;
    END IF;
  END PROCESS;

END rtl;
