--------------------------------------------------------------------------------
-- timer8253.vhd
--
-- Intel 8253 PIT, simplified for IBM 5160 (XT) use.
--   - I/O ports 0x40 (counter 0), 0x41 (counter 1), 0x42 (counter 2), 0x43 (ctrl)
--   - Read path with counter-latch command support (so diagnostic ROMs work)
--   - Modes 2 (rate gen) and 3 (square wave) — covers the XT BIOS use cases
--   - RW modes: 01 (LSB), 10 (MSB), 11 (LSB then MSB)
--   - CR=0 is treated as 65536, per real 8253
--
-- RD / WR are ACTIVE LOW (gated /IOR /IOW from the 8088: low during the I/O
-- strobe, high otherwise). They're inverted internally to rd_act / wr_act.
-- CLK is the bus/system clock; the counters decrement once per CLK edge. On
-- a real XT the PIT runs at 1.193 MHz — divide CLK externally for accurate
-- timing.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY timer8253 IS
  PORT(
        -- Common
        CLK         : IN  std_logic;
        DATA        : IN  std_logic_vector(7 DOWNTO 0);   -- CPU -> PIT
        DATA_OUT    : OUT std_logic_vector(7 DOWNTO 0);   -- PIT -> CPU, 'Z' when not addressed
        ADDR        : IN  std_logic_vector(15 DOWNTO 0);

        RD          : IN  std_logic;                      -- active LOW I/O read
        WR          : IN  std_logic;                      -- active LOW I/O write
        G0          : IN  std_logic;
        G1          : IN  std_logic;
        G2          : IN  std_logic;

        OUT0        : OUT std_logic;
        OUT1        : OUT std_logic;
        OUT2        : OUT std_logic);
END timer8253;


ARCHITECTURE behavior OF timer8253 IS

  -- Count Elements (live counters)
  SIGNAL CE0, CE1, CE2 : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');

  -- Count Registers (the value most recently programmed)
  SIGNAL CR0, CR1, CR2 : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');

  -- Output Latches (snapshot of CE taken by the latch command)
  SIGNAL OL0, OL1, OL2 : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL L0,  L1,  L2  : std_logic := '0';   -- '1' = OL holds frozen value

  -- Mode  (control-word bits D3..D1)
  SIGNAL MODE0, MODE1, MODE2 : std_logic_vector(2 DOWNTO 0) := "011";

  -- RW    (control-word bits D5..D4)  01=LSB  10=MSB  11=LSB then MSB
  SIGNAL RW0, RW1, RW2 : std_logic_vector(1 DOWNTO 0) := "11";

  -- Byte-sequence toggles for writes / reads ('0' = next is LSB)
  SIGNAL WTOG0, WTOG1, WTOG2 : std_logic := '0';
  SIGNAL RTOG0, RTOG1, RTOG2 : std_logic := '0';

  -- Reload pending (set when CR finishes loading; copied into CE next clock)
  SIGNAL NEW0, NEW1, NEW2 : std_logic := '0';

  -- Output state per counter
  SIGNAL O0, O1, O2 : std_logic := '0';

  -- Edge detection for WR / RD strobes
  SIGNAL WR_PREV, RD_PREV : std_logic := '0';

  -- Active-HIGH internal versions of the active-low RD / WR inputs.
  -- Using these everywhere internally keeps the rest of the logic readable.
  SIGNAL rd_act, wr_act : std_logic;

  ----------------------------------------------------------------------------
  -- Helper: returns the "effective" reload value (0 means 65536 on the 8253)
  -- Implemented as a function so the three counters share the same logic.
  ----------------------------------------------------------------------------
  FUNCTION reload_of(cr : std_logic_vector(15 DOWNTO 0))
                     RETURN std_logic_vector IS
  BEGIN
    IF cr = x"0000" THEN
      RETURN x"FFFF";   -- 65536 cycles when reloaded + decremented once
    ELSE
      RETURN cr - 1;
    END IF;
  END FUNCTION;

BEGIN

  OUT0 <= O0;
  OUT1 <= O1;
  OUT2 <= O2;

  -- Invert the active-low bus strobes to active-high internal signals.
  rd_act <= not RD;
  wr_act <= not WR;

  ----------------------------------------------------------------------------
  -- Main synchronous process
  ----------------------------------------------------------------------------
  PROCESS (CLK)
    VARIABLE wr_rise : std_logic;
    VARIABLE rd_fall : std_logic;
  BEGIN
    IF rising_edge(CLK) THEN

      WR_PREV <= wr_act;
      RD_PREV <= rd_act;
      wr_rise := wr_act and not WR_PREV;
      rd_fall := (not rd_act) and RD_PREV;

      ------------------------------------------------------------------
      -- COUNTER 0  (gate G0 — in the XT, G0 is tied high)
      ------------------------------------------------------------------
      IF NEW0 = '1' THEN
        CE0  <= reload_of(CR0);
        NEW0 <= '0';
        O0   <= '0';                         -- mode 2/3 start with OUT low
      ELSIF G0 = '1' THEN
        IF CE0 = x"0000" THEN
          CE0 <= reload_of(CR0);
        ELSE
          CE0 <= CE0 - 1;
        END IF;

        -- Mode 3: square wave (high first half, low second half).
        -- CR0 = 0x0000 is the 8253's 65536 divisor -- exactly what the XT BIOS
        -- loads for the 18.2 Hz tick. Its half-period is 32768, i.e. O0 = the
        -- count MSB. This case MUST be handled here, not excluded, or OUT0 never
        -- toggles, no edge reaches IR0, and INTERRUPT LEVEL 0 fails.
        IF (MODE0 = "011" OR MODE0 = "111") THEN
          IF CR0 = x"0000" THEN
            O0 <= CE0(15);
          ELSIF CE0 > ("0" & CR0(15 DOWNTO 1)) THEN
            O0 <= '1';
          ELSE
            O0 <= '0';
          END IF;
        -- Mode 2: rate generator (low for one tick at terminal count)
        ELSIF (MODE0 = "010" OR MODE0 = "110") THEN
          IF CE0 = x"0001" THEN
            O0 <= '0';
          ELSE
            O0 <= '1';
          END IF;
        -- Mode 0: interrupt on terminal count. OUT starts low (set on the count
        -- load above), latches HIGH the moment the count reaches zero, and holds
        -- there until a new count is written. A diagnostic's interrupt-level test
        -- uses exactly this: the single low->high edge at TC is the interrupt.
        ELSIF (MODE0 = "000") THEN
          IF CE0 = x"0000" THEN
            O0 <= '1';
          END IF;
        END IF;
      END IF;

      ------------------------------------------------------------------
      -- COUNTER 1  (memory refresh on real XT)
      ------------------------------------------------------------------
      IF NEW1 = '1' THEN
        CE1  <= reload_of(CR1);
        NEW1 <= '0';
        O1   <= '0';
      ELSIF G1 = '1' THEN
        IF CE1 = x"0000" THEN
          CE1 <= reload_of(CR1);
        ELSE
          CE1 <= CE1 - 1;
        END IF;
        IF (MODE1 = "011" OR MODE1 = "111") THEN
          IF CR1 = x"0000" THEN O1 <= CE1(15);
          ELSIF CE1 > ("0" & CR1(15 DOWNTO 1)) THEN O1 <= '1'; ELSE O1 <= '0'; END IF;
        ELSIF (MODE1 = "010" OR MODE1 = "110") THEN
          IF CE1 = x"0001" THEN O1 <= '0'; ELSE O1 <= '1'; END IF;
        ELSIF (MODE1 = "000") THEN
          IF CE1 = x"0000" THEN O1 <= '1'; END IF;
        END IF;
      END IF;

      ------------------------------------------------------------------
      -- COUNTER 2  (speaker)
      ------------------------------------------------------------------
      IF NEW2 = '1' THEN
        CE2  <= reload_of(CR2);
        NEW2 <= '0';
        O2   <= '0';
      ELSIF G2 = '1' THEN
        IF CE2 = x"0000" THEN
          CE2 <= reload_of(CR2);
        ELSE
          CE2 <= CE2 - 1;
        END IF;
        IF (MODE2 = "011" OR MODE2 = "111") THEN
          IF CR2 = x"0000" THEN O2 <= CE2(15);
          ELSIF CE2 > ("0" & CR2(15 DOWNTO 1)) THEN O2 <= '1'; ELSE O2 <= '0'; END IF;
        ELSIF (MODE2 = "010" OR MODE2 = "110") THEN
          IF CE2 = x"0001" THEN O2 <= '0'; ELSE O2 <= '1'; END IF;
        ELSIF (MODE2 = "000") THEN
          IF CE2 = x"0000" THEN O2 <= '1'; END IF;
        END IF;
      END IF;

      ------------------------------------------------------------------
      -- WRITES (latched on rising edge of wr_act = end of /IOW pulse)
      ------------------------------------------------------------------
      IF wr_rise = '1' THEN

        IF ADDR = x"0043" THEN
          ----------------------------------------------------------
          -- Control-word port
          ----------------------------------------------------------
          IF DATA(5 DOWNTO 4) = "00" THEN
            -- Counter Latch Command
            CASE DATA(7 DOWNTO 6) IS
              WHEN "00" =>
                IF L0 = '0' THEN
                  OL0 <= CE0;  L0 <= '1';  RTOG0 <= '0';
                END IF;
              WHEN "01" =>
                IF L1 = '0' THEN
                  OL1 <= CE1;  L1 <= '1';  RTOG1 <= '0';
                END IF;
              WHEN "10" =>
                IF L2 = '0' THEN
                  OL2 <= CE2;  L2 <= '1';  RTOG2 <= '0';
                END IF;
              WHEN OTHERS => NULL;
            END CASE;
          ELSE
            -- Mode / RW programming
            CASE DATA(7 DOWNTO 6) IS
              WHEN "00" =>
                RW0   <= DATA(5 DOWNTO 4);
                MODE0 <= DATA(3 DOWNTO 1);
                WTOG0 <= '0';   RTOG0 <= '0';   L0 <= '0';
                O0    <= '0';
              WHEN "01" =>
                RW1   <= DATA(5 DOWNTO 4);
                MODE1 <= DATA(3 DOWNTO 1);
                WTOG1 <= '0';   RTOG1 <= '0';   L1 <= '0';
                O1    <= '0';
              WHEN "10" =>
                RW2   <= DATA(5 DOWNTO 4);
                MODE2 <= DATA(3 DOWNTO 1);
                WTOG2 <= '0';   RTOG2 <= '0';   L2 <= '0';
                O2    <= '0';
              WHEN OTHERS => NULL;
            END CASE;
          END IF;

        ELSIF ADDR = x"0040" THEN
          ----------------------------------------------------------
          -- Counter 0 data port
          ----------------------------------------------------------
          CASE RW0 IS
            WHEN "01" =>
              CR0  <= x"00" & DATA;       NEW0 <= '1';
            WHEN "10" =>
              CR0  <= DATA & x"00";       NEW0 <= '1';
            WHEN "11" =>
              IF WTOG0 = '0' THEN
                CR0(7 DOWNTO 0)  <= DATA; WTOG0 <= '1';
              ELSE
                CR0(15 DOWNTO 8) <= DATA; WTOG0 <= '0'; NEW0 <= '1';
              END IF;
            WHEN OTHERS => NULL;
          END CASE;

        ELSIF ADDR = x"0041" THEN
          CASE RW1 IS
            WHEN "01" =>
              CR1  <= x"00" & DATA;       NEW1 <= '1';
            WHEN "10" =>
              CR1  <= DATA & x"00";       NEW1 <= '1';
            WHEN "11" =>
              IF WTOG1 = '0' THEN
                CR1(7 DOWNTO 0)  <= DATA; WTOG1 <= '1';
              ELSE
                CR1(15 DOWNTO 8) <= DATA; WTOG1 <= '0'; NEW1 <= '1';
              END IF;
            WHEN OTHERS => NULL;
          END CASE;

        ELSIF ADDR = x"0042" THEN
          CASE RW2 IS
            WHEN "01" =>
              CR2  <= x"00" & DATA;       NEW2 <= '1';
            WHEN "10" =>
              CR2  <= DATA & x"00";       NEW2 <= '1';
            WHEN "11" =>
              IF WTOG2 = '0' THEN
                CR2(7 DOWNTO 0)  <= DATA; WTOG2 <= '1';
              ELSE
                CR2(15 DOWNTO 8) <= DATA; WTOG2 <= '0'; NEW2 <= '1';
              END IF;
            WHEN OTHERS => NULL;
          END CASE;
        END IF;

      END IF;  -- wr_rise

      ------------------------------------------------------------------
      -- READ STATE ADVANCE (after rd_act falls = end of /IOR pulse,
      -- by which time the CPU has already sampled the data)
      ------------------------------------------------------------------
      IF rd_fall = '1' THEN
        IF ADDR = x"0040" THEN
          IF RW0 = "11" THEN
            IF RTOG0 = '0' THEN
              RTOG0 <= '1';
            ELSE
              RTOG0 <= '0';   L0 <= '0';   -- both bytes done, drop latch
            END IF;
          ELSE
            L0 <= '0';                     -- single-byte read clears latch
          END IF;
        ELSIF ADDR = x"0041" THEN
          IF RW1 = "11" THEN
            IF RTOG1 = '0' THEN
              RTOG1 <= '1';
            ELSE
              RTOG1 <= '0';   L1 <= '0';
            END IF;
          ELSE
            L1 <= '0';
          END IF;
        ELSIF ADDR = x"0042" THEN
          IF RW2 = "11" THEN
            IF RTOG2 = '0' THEN
              RTOG2 <= '1';
            ELSE
              RTOG2 <= '0';   L2 <= '0';
            END IF;
          ELSE
            L2 <= '0';
          END IF;
        END IF;
      END IF;

    END IF;  -- rising_edge(CLK)
  END PROCESS;

  ----------------------------------------------------------------------------
  -- Combinational read-data mux
  --   - Source = OL if latched, otherwise live CE
  --   - Byte  = per RW mode and current read toggle
  --   - DATA_OUT is high-Z when not addressed for read
  ----------------------------------------------------------------------------
  PROCESS (rd_act, ADDR, RW0, RW1, RW2, L0, L1, L2,
           RTOG0, RTOG1, RTOG2, CE0, CE1, CE2, OL0, OL1, OL2)
    VARIABLE src     : std_logic_vector(15 DOWNTO 0);
    VARIABLE rw      : std_logic_vector(1 DOWNTO 0);
    VARIABLE tg      : std_logic;
    VARIABLE hit     : std_logic;
  BEGIN
    hit := '0';
    src := (OTHERS => '0');
    rw  := "00";
    tg  := '0';

    IF rd_act = '1' THEN
      IF    ADDR = x"0040" THEN
        IF L0 = '1' THEN src := OL0; ELSE src := CE0; END IF;
        rw := RW0;  tg := RTOG0;  hit := '1';
      ELSIF ADDR = x"0041" THEN
        IF L1 = '1' THEN src := OL1; ELSE src := CE1; END IF;
        rw := RW1;  tg := RTOG1;  hit := '1';
      ELSIF ADDR = x"0042" THEN
        IF L2 = '1' THEN src := OL2; ELSE src := CE2; END IF;
        rw := RW2;  tg := RTOG2;  hit := '1';
      END IF;
    END IF;

    IF hit = '1' THEN
      CASE rw IS
        WHEN "01" => DATA_OUT <= src(7  DOWNTO 0);
        WHEN "10" => DATA_OUT <= src(15 DOWNTO 8);
        WHEN "11" =>
          IF tg = '0' THEN
            DATA_OUT <= src(7  DOWNTO 0);
          ELSE
            DATA_OUT <= src(15 DOWNTO 8);
          END IF;
        WHEN OTHERS => DATA_OUT <= (OTHERS => 'Z');
      END CASE;
    ELSE
      DATA_OUT <= (OTHERS => 'Z');
    END IF;
  END PROCESS;

END;