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
-- The dividers used to be constants folded out of the CLK_HZ generic, in the
-- style of fdc8272's BAUD_DIV. The bus clock is selectable at run time now, so
-- they are INPUTS driven from cpuclk's table and they change with the step;
-- CLK_HZ only supplies their defaults, for a standalone instance.
-- At 10 MHz the sample divider truncates to 201, giving 49751 Hz against the
-- ideal 49716 -- +1.2 cents, and constant across all notes so nothing is out
-- of tune with itself. (At the old 5 MHz it truncated to 100 and came out
-- +9.8 cents, so doubling the clock made the pitch eight times more accurate
-- for free: a bigger divisor quantises more finely.) The quantisation is worst
-- at the bottom of the ladder and best at the top, and it is CONSTANT within a
-- step, so a step change transposes nothing -- it only re-tunes by a cent or
-- two, which is why the ladder is free to move under a playing note.
--
-- The timers land exactly at 10 MHz: 10e6/12500 = 800 and 10e6/3125 = 3200,
-- both whole numbers, so 80 us and 320 us are exact rather than rounded. At
-- 8.333 and 16.667 MHz they truncate by 0.05 %, far inside what the detection
-- protocol's "wait at least 80 us" can notice.
--
-- ---------------------------------------------------------------------------
-- OUTPUT
--
-- The buzzer is one bit, so nine square waves are summed to a 0..9 value and
-- rendered as PWM against a 4-bit counter. At 10 MHz that carrier is 625 kHz --
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
        CLK_HZ  : integer := 10_000_000);
  PORT(
        CLK     : IN    std_logic;
        DATA    : IN    std_logic_vector(7 DOWNTO 0);   -- CPU -> device
        ADDR    : IN    std_logic_vector(15 DOWNTO 0);  -- I/O address
        RD      : IN    std_logic;                      -- active LOW I/O read
        WR      : IN    std_logic;                      -- active LOW I/O write
        DATAOUT : INOUT std_logic_vector(7 DOWNTO 0);   -- 'Z' when not addressed
        SND     : OUT   std_logic;                      -- PWM, mix into BUZ

        -- Sample rate and the two timer periods, in CLK cycles. These used to
        -- be constants folded out of CLK_HZ; the bus clock is now selectable at
        -- run time (cpuclk.vhd), so they arrive from cpuclk's table instead and
        -- follow the step. Leave them open and CLK_HZ still sets them, which is
        -- what makes the module usable on its own.
        --   SAMPLE_DIV = CLK_HZ / 49716   the OPL2 sample clock
        --   T1_DIV     = CLK_HZ / 12500   timer 1, 80 us per tick
        --   T2_DIV     = CLK_HZ / 3125    timer 2, 320 us per tick
        SAMPLE_DIV : IN integer RANGE 1 TO 1023 := CLK_HZ / 49716;
        T1_DIV     : IN integer RANGE 1 TO 8191 := CLK_HZ / 12500;
        T2_DIV     : IN integer RANGE 1 TO 8191 := CLK_HZ / 3125;

        -- ---- PCM tap, for USB audio -----------------------------------------
        -- A SECOND rendering of the same nine channels, at exactly 48 kHz, for
        -- streaming to a USB Audio Class device. The PWM buzzer above is
        -- untouched by all of this and keeps working with CLK48 tied low.
        --
        -- Why a second bank of phase accumulators instead of resampling the
        -- one that already exists: the existing one runs on CLK, the CPU bus
        -- clock, which is 5 to 10 MHz and CHANGES AT RUN TIME (cpuclk's speed
        -- ladder). Nothing derived from it can hold a stable sample rate, and
        -- a USB frame is a hard 1 ms. Running this bank from CLK48 makes the
        -- sample clock and the frame clock the same crystal, so 48 samples per
        -- frame is exact forever -- no drift, no rate feedback, no FIFO slowly
        -- filling over an evening. It costs nine 20-bit accumulators.
        CLK48      : IN  std_logic := '0';
        PCM        : OUT std_logic_vector(15 DOWNTO 0);  -- signed, CLK48 domain
        PCM_STB    : OUT std_logic);                     -- one CLK48 tick, 48 kHz
END opl2_lite;

ARCHITECTURE behavior OF opl2_lite IS

  TYPE fnum_t  IS ARRAY(0 TO 8) OF unsigned(9 DOWNTO 0);
  TYPE blk_t   IS ARRAY(0 TO 8) OF unsigned(2 DOWNTO 0);
  TYPE phase_t IS ARRAY(0 TO 8) OF unsigned(19 DOWNTO 0);

  SIGNAL fnum   : fnum_t  := (OTHERS => (OTHERS => '0'));
  SIGNAL blk    : blk_t   := (OTHERS => (OTHERS => '0'));
  SIGNAL keyon  : std_logic_vector(8 DOWNTO 0) := (OTHERS => '0');
  SIGNAL phase  : phase_t := (OTHERS => (OTHERS => '0'));

  -- ---- PCM tap (CLK48 domain) ------------------------------------------------
  CONSTANT PCM_DIV  : integer := 1000;   -- 48 MHz / 48 kHz, exact
  -- Per-channel amplitude. Nine channels at +/-3000 peak at +/-27000, which
  -- leaves headroom inside a 16-bit sample without needing a saturating adder
  -- -- all nine can be high at once and it still cannot wrap. Fine gain is a
  -- shift in usb_audio, where it can be changed without a rebuild.
  CONSTANT PCM_AMPL : integer := 3000;
  SIGNAL   pcm_pre  : integer RANGE 0 TO PCM_DIV-1 := 0;
  SIGNAL   phase48  : phase_t := (OTHERS => (OTHERS => '0'));
  SIGNAL   pcm_reg  : signed(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL   pcm_st   : std_logic := '0';

  -- The address latch written through 0x388; data at 0x389 lands in this reg.
  SIGNAL reg_idx : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');

  -- Timers. Both count UP from their preset and overflow past 0xFF, which is
  -- why a preset of 0xFF expires in a single tick -- the detection relies on it.
  SIGNAL t1_preset, t2_preset : unsigned(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL t1_cnt,    t2_cnt    : unsigned(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL t1_run,    t2_run    : std_logic := '0';
  SIGNAL t1_mask,   t2_mask   : std_logic := '0';
  SIGNAL t1_flag,   t2_flag   : std_logic := '0';
  -- Sized for the whole speed ladder, not for one clock: the dividers are
  -- inputs now, so these have to hold the SLOWEST step's value (T2_DIV = 8000
  -- at 25 MHz). The comparisons below are >= and not =, for the same reason --
  -- a step change can leave a counter above its new limit, and an equality test
  -- would sail straight past it and hang the timer for a whole wrap.
  SIGNAL t1_pre : integer RANGE 0 TO 8191 := 0;
  SIGNAL t2_pre : integer RANGE 0 TO 8191 := 0;

  SIGNAL smp_pre : integer RANGE 0 TO 1023 := 0;

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
        IF t1_pre >= T1_DIV-1 THEN
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
        IF t2_pre >= T2_DIV-1 THEN
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
      IF smp_pre >= SAMPLE_DIV-1 THEN
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

  ------------------------------------------------------------------------------
  -- PCM tap: the same nine square waves, rendered at exactly 48 kHz for USB.
  --
  -- PITCH. A channel's output frequency is incr / 2^20 * Fs, so rendering at
  -- 48000 instead of the OPL2's native 49716 would play everything 3.45% flat
  -- -- better than half a semitone, which anyone would hear. The increment is
  -- therefore scaled by 49716/48000 = 1.035750 on the way in.
  --
  -- That scaling is four shift-adds, not a multiplier:
  --     1 + 1/32 + 1/256 + 1/2048 + 1/8192 = 1.0357666
  -- which is 0.0016% sharp, about 0.0003 of a semitone. There are 132 unused
  -- 9-bit multipliers on this part and nine of them would have done it exactly,
  -- but they are worth more to a future SBC encoder than to an error three
  -- orders of magnitude below audible.
  --
  -- CLOCK CROSSING. fnum, blk and keyon are written in the CLK domain and read
  -- here, with no synchroniser. That is deliberate and it is safe for a reason
  -- specific to this circuit: these values feed an INCREMENT, and the phase
  -- accumulator integrates it. A bit caught mid-update perturbs one sample's
  -- increment by a few parts in 2^20 and the phase carries on from wherever it
  -- got to -- there is no discontinuity in the output, so no click. It is the
  -- one place in this design where a metastable read cannot produce an audible
  -- or logical fault, and paying for a 126-bit handshake would buy nothing.
  -- (fnum is already written in two halves, 0xA0 then 0xB0, so even a
  -- single-domain reader sees torn values during a note change.)
  ------------------------------------------------------------------------------
  PCMGEN : PROCESS (CLK48)
    VARIABLE inc : unsigned(19 DOWNTO 0);
    VARIABLE acc : integer RANGE -32768 TO 32767;
  BEGIN
    IF rising_edge(CLK48) THEN
      pcm_st <= '0';
      IF pcm_pre = PCM_DIV-1 THEN
        pcm_pre <= 0;
        acc := 0;
        FOR i IN 0 TO 8 LOOP
          IF keyon(i) = '1' THEN
            inc := shift_left(resize(fnum(i), 20), to_integer(blk(i)));
            phase48(i) <= phase48(i) + inc
                          + shift_right(inc,  5) + shift_right(inc,  8)
                          + shift_right(inc, 11) + shift_right(inc, 13);
            -- Bipolar, unlike the PWM path: a DAC wants a signal centred on
            -- zero, and summing +/-A per channel gives that for free. The
            -- buzzer counts only the HIGH channels because PWM has no negative
            -- half to work with.
            IF phase48(i)(19) = '1' THEN
              acc := acc + PCM_AMPL;
            ELSE
              acc := acc - PCM_AMPL;
            END IF;
          ELSE
            phase48(i) <= (OTHERS => '0');
          END IF;
        END LOOP;
        pcm_reg <= to_signed(acc, 16);
        pcm_st  <= '1';
      ELSE
        pcm_pre <= pcm_pre + 1;
      END IF;
    END IF;
  END PROCESS;

  PCM     <= std_logic_vector(pcm_reg);
  PCM_STB <= pcm_st;

END behavior;
