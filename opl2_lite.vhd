--------------------------------------------------------------------------------
-- opl2_lite.vhd  --  AdLib front end at I/O 0x388/0x389, played as square waves
--
-- This answers the AdLib detection protocol honestly and turns what a game
-- writes to the OPL2 into something audible on the one-bit buzzer. It is NOT an
-- FM synthesiser: there are no operators, no envelopes and no modulation. Each
-- of the nine channels contributes a square wave at the pitch the game asked
-- for, and the nine are summed and rendered by PWM.
--
-- Why this, and why in this order:
--
--   A Sound Blaster is an AdLib plus a DAC, and the two halves make very
--   different promises. Announcing a Sound Blaster commits this board to
--   servicing DMA channel 1 and an interrupt -- a game sets up a transfer and
--   waits for a completion IRQ, and if it never comes the game hangs. The
--   AdLib half promises nothing: register writes, no DMA, no interrupts, and
--   nothing that can wedge the machine if it is imperfect. It is also the half
--   that carries the music in everything of this era.
--
--   Detection-only would have been worse than silence. A game would find the
--   card, select it, and write its music into a void -- trading no music for
--   music that is missing, which is a harder fault to see.
--
-- What is deliberately not here, and what it costs:
--
--   no envelopes      notes start and stop at full volume and do not decay,
--                     so anything relying on a fast decay sounds sustained
--   no operators      the timbre is a square wave, not the patch the game chose
--   no rhythm mode    register 0xBD is ignored, so percussion on channels 6-8
--                     is silent
--   no per-note level the total-level registers (0x40-0x55) are ignored, so
--                     every channel is equally loud
--
-- None of those can hang anything; they only affect how it sounds. The register
-- decode and the per-channel state below are the same front end a real OPL2
-- core would sit behind later, so this is a foundation rather than a detour.
--
-- ---------------------------------------------------------------------------
-- DETECTION -- the part that has to be exactly right
--
-- Every AdLib-aware program uses the same sequence, and it is built entirely on
-- the two timers, not on anything that makes sound:
--
--   write reg 4 = 0x60    stop and mask both timers
--   write reg 4 = 0x80    reset the status flags
--   read  0x388           status1: (status1 AND 0xE0) must be 0x00
--   write reg 2 = 0xFF    timer 1 preset -- one tick from overflow
--   write reg 4 = 0x21    start timer 1, mask timer 2
--   ...wait at least 80 us...
--   read  0x388           status2: (status2 AND 0xE0) must be 0xC0
--
-- So the timers must keep real time (80 us and 320 us per tick), the status
-- flags must set on overflow and clear on the reset command, and bits 4..0 must
-- read back as zero. Get those right and the card is found; get the sound wrong
-- and it is merely disappointing.
--
-- ---------------------------------------------------------------------------
-- PITCH
--
-- The OPL2's own model is a phase accumulator, so this uses it directly rather
-- than dividing anything. The chip's output frequency is
--
--     f = FNum * 49716 / 2^(20-Block)
--
-- which is exactly what a 20-bit accumulator ticked at 49716 Hz and incremented
-- by (FNum << Block) produces, with bit 19 as the square wave. No division, no
-- multiplier, and the increment is the register value shifted -- which is why
-- the arithmetic below looks too simple to be doing anything.
--
-- CLK_HZ is a generic and the dividers come from it, in the style of
-- fdc8272's BAUD_DIV, so this module does not care which clock it is wired to.
-- At 5 MHz the sample divider truncates to 100, giving 50000 Hz instead of
-- 49716 -- 0.57% sharp, about a tenth of a semitone, and constant across all
-- notes so nothing is out of tune with itself.
--
-- ---------------------------------------------------------------------------
-- OUTPUT
--
-- The buzzer is one bit, so nine square waves are summed to a 0..9 value and
-- rendered as PWM against a 4-bit counter. At 5 MHz that carrier is 312 kHz --
-- far above anything a piezo can follow, so it hears the average.
--
-- SND is left for the top level to combine with the PC speaker rather than
-- doing it here: when nothing is keyed on the sum is zero and SND sits at '0',
-- so a plain OR with the existing speaker path is transparent in both
-- directions and the speaker keeps working exactly as it did.
--
-- Wiring (top level):
--   CLK     <- n_c0, the peripheral clock the other I/O modules use
--   RD/WR   <- n_io_rd / n_io_wr, active low, I/O strobes only
--   ADDR    <- n_io_addr        DATA -> n_cpu_wdata
--   DATAOUT -> n_periph_rdata, the shared tri-state read bus
--   SND     -> OR'd into BUZ alongside (n_speaker_data AND n_out2)
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;
USE  IEEE.NUMERIC_STD.ALL;

ENTITY opl2_lite IS
  GENERIC(
        CLK_HZ  : integer := 5_000_000);
  PORT(
        CLK     : IN    std_logic;
        DATA    : IN    std_logic_vector(7 DOWNTO 0);   -- CPU -> device
        ADDR    : IN    std_logic_vector(15 DOWNTO 0);  -- I/O address
        RD      : IN    std_logic;                      -- active LOW I/O read
        WR      : IN    std_logic;                      -- active LOW I/O write
        DATAOUT : INOUT std_logic_vector(7 DOWNTO 0);   -- 'Z' when not addressed
        SND     : OUT   std_logic);                     -- PWM, mix into BUZ
END opl2_lite;

ARCHITECTURE behavior OF opl2_lite IS

  -- Sample rate and the two timer periods, all derived from the wired clock.
  CONSTANT SAMPLE_DIV : integer := CLK_HZ / 49716;   -- OPL2 sample clock
  CONSTANT T1_DIV     : integer := CLK_HZ / 12500;   -- timer 1: 80 us per tick
  CONSTANT T2_DIV     : integer := CLK_HZ / 3125;    -- timer 2: 320 us per tick

  TYPE fnum_t  IS ARRAY(0 TO 8) OF unsigned(9 DOWNTO 0);
  TYPE blk_t   IS ARRAY(0 TO 8) OF unsigned(2 DOWNTO 0);
  TYPE phase_t IS ARRAY(0 TO 8) OF unsigned(19 DOWNTO 0);

  SIGNAL fnum   : fnum_t  := (OTHERS => (OTHERS => '0'));
  SIGNAL blk    : blk_t   := (OTHERS => (OTHERS => '0'));
  SIGNAL keyon  : std_logic_vector(8 DOWNTO 0) := (OTHERS => '0');
  SIGNAL phase  : phase_t := (OTHERS => (OTHERS => '0'));

  -- The address latch written through 0x388; data at 0x389 lands in this reg.
  SIGNAL reg_idx : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');

  -- Timers. Both count UP from their preset and overflow past 0xFF, which is
  -- why a preset of 0xFF expires in a single tick -- the detection relies on it.
  SIGNAL t1_preset, t2_preset : unsigned(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL t1_cnt,    t2_cnt    : unsigned(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL t1_run,    t2_run    : std_logic := '0';
  SIGNAL t1_mask,   t2_mask   : std_logic := '0';
  SIGNAL t1_flag,   t2_flag   : std_logic := '0';
  SIGNAL t1_pre : integer RANGE 0 TO T1_DIV-1 := 0;
  SIGNAL t2_pre : integer RANGE 0 TO T2_DIV-1 := 0;

  SIGNAL smp_pre : integer RANGE 0 TO SAMPLE_DIV-1 := 0;

  SIGNAL wr_act, wr_prev : std_logic := '0';

  SIGNAL status  : std_logic_vector(7 DOWNTO 0);
  SIGNAL sel_rd  : std_logic;

  SIGNAL mix     : unsigned(3 DOWNTO 0) := (OTHERS => '0');
  SIGNAL pwm_cnt : unsigned(3 DOWNTO 0) := (OTHERS => '0');

BEGIN

  wr_act <= NOT WR;

  ----------------------------------------------------------------------------
  -- Status register, read at 0x388.
  --   bit 7 = either unmasked timer has expired
  --   bit 6 = timer 1 expired      bit 5 = timer 2 expired
  --   bits 4..0 read as zero on an OPL2, so the byte is never 0xFF and
  --   "is anything there?" is answerable at all -- which is the whole reason
  --   an absent device reading as open-bus 0xFF causes trouble elsewhere.
  ----------------------------------------------------------------------------
  status(7)          <= t1_flag OR t2_flag;
  status(6)          <= t1_flag;
  status(5)          <= t2_flag;
  status(4 DOWNTO 0) <= "00000";

  sel_rd  <= '1' WHEN (RD = '0' AND ADDR = x"0388") ELSE '0';
  DATAOUT <= status WHEN sel_rd = '1' ELSE "ZZZZZZZZ";

  ----------------------------------------------------------------------------
  -- Everything synchronous.
  --
  -- ORDER MATTERS in one place: the timer ticks come first and the register
  -- writes last, so that a status-reset command arriving in the same clock as
  -- an overflow wins. VHDL gives the last assignment to a signal, and having
  -- the reset lose would leave a flag set that software believes it cleared.
  ----------------------------------------------------------------------------
  PROCESS (CLK)
    VARIABLE wr_rise : std_logic;
    VARIABLE idx     : integer RANGE 0 TO 255;
    VARIABLE ch      : integer RANGE 0 TO 8;
    VARIABLE s       : integer RANGE 0 TO 9;
  BEGIN
    IF rising_edge(CLK) THEN
      wr_prev <= wr_act;
      wr_rise := wr_act AND NOT wr_prev;

      ----------------------------------------------------------------------
      -- timer 1 -- 80 us per tick
      ----------------------------------------------------------------------
      IF t1_run = '1' THEN
        IF t1_pre = T1_DIV-1 THEN
          t1_pre <= 0;
          IF t1_cnt = x"FF" THEN
            t1_cnt <= t1_preset;
            IF t1_mask = '0' THEN
              t1_flag <= '1';
            END IF;
          ELSE
            t1_cnt <= t1_cnt + 1;
          END IF;
        ELSE
          t1_pre <= t1_pre + 1;
        END IF;
      ELSE
        t1_pre <= 0;
      END IF;

      ----------------------------------------------------------------------
      -- timer 2 -- 320 us per tick
      ----------------------------------------------------------------------
      IF t2_run = '1' THEN
        IF t2_pre = T2_DIV-1 THEN
          t2_pre <= 0;
          IF t2_cnt = x"FF" THEN
            t2_cnt <= t2_preset;
            IF t2_mask = '0' THEN
              t2_flag <= '1';
            END IF;
          ELSE
            t2_cnt <= t2_cnt + 1;
          END IF;
        ELSE
          t2_pre <= t2_pre + 1;
        END IF;
      ELSE
        t2_pre <= 0;
      END IF;

      ----------------------------------------------------------------------
      -- one sample: advance every keyed-on channel, then sum the square waves
      --
      -- The increment is the register value shifted by the block, which is
      -- the OPL2's own definition of pitch -- see the header. A channel that
      -- is not keyed on is held at phase zero rather than left running, so it
      -- contributes nothing to the sum and restarts cleanly on the next note.
      ----------------------------------------------------------------------
      IF smp_pre = SAMPLE_DIV-1 THEN
        smp_pre <= 0;
        s := 0;
        FOR i IN 0 TO 8 LOOP
          IF keyon(i) = '1' THEN
            phase(i) <= phase(i)
                        + shift_left(resize(fnum(i), 20), to_integer(blk(i)));
            IF phase(i)(19) = '1' THEN
              s := s + 1;
            END IF;
          ELSE
            phase(i) <= (OTHERS => '0');
          END IF;
        END LOOP;
        mix <= to_unsigned(s, 4);
      ELSE
        smp_pre <= smp_pre + 1;
      END IF;

      ----------------------------------------------------------------------
      -- register writes -- last, see the note above
      ----------------------------------------------------------------------
      IF wr_rise = '1' THEN
        IF ADDR = x"0388" THEN
          reg_idx <= DATA;                      -- address latch
        ELSIF ADDR = x"0389" THEN
          idx := to_integer(unsigned(reg_idx));
          IF idx = 2 THEN
            t1_preset <= unsigned(DATA);
          ELSIF idx = 3 THEN
            t2_preset <= unsigned(DATA);
          ELSIF idx = 4 THEN
            IF DATA(7) = '1' THEN
              t1_flag <= '0';                   -- IRQ reset: clears both flags
              t2_flag <= '0';                   -- and nothing else applies
            ELSE
              t1_run  <= DATA(0);
              t2_run  <= DATA(1);
              t2_mask <= DATA(5);
              t1_mask <= DATA(6);
              -- Starting a stopped timer loads its preset. Writing the control
              -- word again while it runs must NOT reload, or a program that
              -- re-masks mid-count would restart the count instead.
              IF DATA(0) = '1' AND t1_run = '0' THEN
                t1_cnt <= t1_preset;
              END IF;
              IF DATA(1) = '1' AND t2_run = '0' THEN
                t2_cnt <= t2_preset;
              END IF;
            END IF;
          ELSIF idx >= 16#A0# AND idx <= 16#A8# THEN
            ch := idx - 16#A0#;
            fnum(ch)(7 DOWNTO 0) <= unsigned(DATA);
          ELSIF idx >= 16#B0# AND idx <= 16#B8# THEN
            ch := idx - 16#B0#;
            fnum(ch)(9 DOWNTO 8) <= unsigned(DATA(1 DOWNTO 0));
            blk(ch)              <= unsigned(DATA(4 DOWNTO 2));
            keyon(ch)            <= DATA(5);
          END IF;
          -- every other register is accepted and ignored: the operator and
          -- waveform settings have no meaning without an FM core, and a game
          -- writing them must not stall
        END IF;
      END IF;

      pwm_cnt <= pwm_cnt + 1;
    END IF;
  END PROCESS;

  -- PWM the 0..9 mix. Silence is mix = 0, which holds SND at '0' and leaves
  -- the top-level OR with the PC speaker completely transparent.
  SND <= '1' WHEN pwm_cnt < mix ELSE '0';

END behavior;
