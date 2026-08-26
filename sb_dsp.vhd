--------------------------------------------------------------------------------
-- sb_dsp.vhd  --  Sound Blaster DSP, 8-bit mono digitised audio
--
-- Reports DSP version 2.01, and means it. Everything a game does after reading
-- that version works: direct DAC, single-cycle DMA, auto-init DMA, the time
-- constant, speaker on/off, pause and continue. Nothing here advertises a
-- capability it does not have -- a card claiming 3.xx gets asked for stereo and
-- a mixer, and a game that asks and is answered with silence is worse off than
-- one that never asked.
--
-- I/O MAP  (base 0x220, so A220 I5 D1 as the real card and every game's
--           SET BLASTER line expects)
-- --------------------------------------------------------------------------
--   2x6  W   RESET     write 1 then 0; the DSP answers 0xAA at 2xA
--   2xA  R   READ       the byte the DSP is returning
--   2xC  W   COMMAND    command, then its parameter bytes
--        R   WSTATUS    bit 7 = write buffer full. Always 0 here: this DSP
--                       consumes a byte in one bus cycle, so it is never busy
--   2xE  R   RSTATUS    bit 7 = a byte is waiting at 2xA.
--                       READING THIS ALSO ACKNOWLEDGES THE 8-BIT IRQ, which is
--                       how every SB interrupt handler ends and is not optional
--
-- COMMANDS
--   0x10 v      direct DAC write
--   0x14 lo hi  single-cycle 8-bit DMA output, length-1
--   0x1C        auto-init 8-bit DMA output, length from 0x48
--   0x40 tc     time constant: rate = 1000000 / (256 - tc)
--   0x48 lo hi  block length-1 for auto-init
--   0xD0        pause DMA          0xD4  continue
--   0xD1        speaker on         0xD3  speaker off
--   0xE0 v      identify: returns NOT v
--   0xE1        version: returns 0x02, 0x01
--
-- WHERE THE SAMPLE CLOCK COMES FROM, AND WHY NOT FROM CLK
--
--   CLK is the CPU bus clock and this machine changes it -- there is a speed
--   ladder and the user moves along it. A sample rate divided from that would
--   move with it, so a game would play back at the wrong pitch at 10 MHz and a
--   different wrong pitch at 8.33.
--
--   CLK48 is a crystal and does not move. It also divides exactly: the time
--   constant defines rate = 1000000 / (256 - tc), so the divisor is
--
--       48000000 / rate  =  48 * (256 - tc)
--
--   which is an integer for every time constant, needs one 14-bit counter, and
--   is built from shifts. No rounding error at any rate the DSP can be asked
--   for, at 11025, 22050 or anything else.
--
-- HOW THE SAMPLE REACHES THE SPEAKER
--
--   There is no resampler and no FIFO. dac_hold keeps the last byte the DMA
--   delivered and the 48 kHz PCM tap samples whatever is in it -- a zero-order
--   hold, which is what the real hardware does between conversions and part of
--   why it sounds like it does. The output stage mixes the held value into the
--   OPL2's PCM stream, so FM and digitised audio arrive as one signal.
--
-- CLOCK CROSSING
--
--   Two, both handled as the rest of this design handles them, and deliberately
--   not by hoping an 8-bit value crossing unsynchronised will not tear:
--
--     smp_tgl  CLK48 -> CLK   a toggle, three flops, edge detected. The sample
--                             clock asking the CLK domain for the next byte.
--     dac_hold CLK   -> CLK48 the sample byte, single stage, QUALIFIED by
--                             dac_tgl through three flops. The byte is stable
--                             for tens of microseconds before the toggle
--                             arrives, so this is a multi-cycle path and not a
--                             race -- the same argument usb_host makes for its
--                             command registers, and sound for the same reason.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;
USE  IEEE.NUMERIC_STD.ALL;

ENTITY sb_dsp IS
  GENERIC(
        IO_BASE : std_logic_vector(15 DOWNTO 0) := x"0220");
  PORT(
        CLK        : IN    std_logic;                    -- CPU bus clock
        RESET      : IN    std_logic;
        ADDR       : IN    std_logic_vector(15 DOWNTO 0);
        RD         : IN    std_logic;                    -- active LOW
        WR         : IN    std_logic;                    -- active LOW
        DATAIN     : IN    std_logic_vector(7 DOWNTO 0);
        DATAOUT    : INOUT std_logic_vector(7 DOWNTO 0); -- 'Z' when not addressed

        -- 8237 channel 1
        DRQ        : OUT   std_logic;                    -- active HIGH
        DACK       : IN    std_logic;                    -- active HIGH
        IOW        : IN    std_logic := '1';             -- 8237 /IOW, active LOW
        TC         : IN    std_logic;
        DMA_DIN    : IN    std_logic_vector(7 DOWNTO 0); -- byte <- memory

        IRQ        : OUT   std_logic;                    -- -> 8259 IR5

        -- audio, 48 MHz domain. PCM_IN is the OPL2; PCM is the sum.
        CLK48      : IN    std_logic := '0';
        PCM_IN     : IN    std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
        PCM_STB_IN : IN    std_logic := '0';
        PCM        : OUT   std_logic_vector(15 DOWNTO 0);
        PCM_STB    : OUT   std_logic);
END sb_dsp;

ARCHITECTURE behavior OF sb_dsp IS

  -- ---- bus decode -----------------------------------------------------------
  SIGNAL io_hit  : std_logic;
  SIGNAL io_reg  : std_logic_vector(3 DOWNTO 0);
  SIGNAL wr_prev : std_logic := '1';
  SIGNAL wr_rise : std_logic;
  SIGNAL rd_prev : std_logic := '1';
  SIGNAL rd_done : std_logic;      -- END of the read strobe, not the start
  SIGNAL dma_lat : std_logic_vector(7 DOWNTO 0) := x"80";
  SIGNAL iow_p   : std_logic := '1';

  -- ---- DSP command machine --------------------------------------------------
  SIGNAL cmd     : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL pcnt    : integer RANGE 0 TO 2 := 0;      -- parameter bytes still due
  SIGNAL p1      : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');

  SIGNAL rst_arm : std_logic := '0';               -- a 1 was written to 2x6

  -- Two deep, because 0xE1 returns two bytes and a game reads them one at a
  -- time. rd_n says how many are still waiting.
  SIGNAL rd_a    : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL rd_b    : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL rd_n    : integer RANGE 0 TO 2 := 0;

  -- ---- playback state -------------------------------------------------------
  SIGNAL tconst  : unsigned(7 DOWNTO 0) := x"A6";  -- ~11 kHz until told otherwise
  SIGNAL blk_len : unsigned(15 DOWNTO 0) := (OTHERS => '0');   -- from 0x48
  SIGNAL remain  : unsigned(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL playing : std_logic := '0';
  SIGNAL paused  : std_logic := '0';
  SIGNAL autoin  : std_logic := '0';
  SIGNAL spk_on  : std_logic := '0';
  SIGNAL irq_r   : std_logic := '0';

  SIGNAL drq_r   : std_logic := '0';
  SIGNAL dack_p  : std_logic := '0';
  SIGNAL dac_hold: std_logic_vector(7 DOWNTO 0) := x"80";  -- unsigned, mid-scale
  SIGNAL dac_tgl : std_logic := '0';

  -- ---- sample clock, CLK48 --------------------------------------------------
  SIGNAL div     : unsigned(13 DOWNTO 0) := (OTHERS => '0');
  SIGNAL div_top : unsigned(13 DOWNTO 0);
  SIGNAL smp_tgl : std_logic := '0';
  SIGNAL smp_s   : std_logic_vector(2 DOWNTO 0) := "000";
  SIGNAL smp_p   : std_logic := '0';

  SIGNAL dac_s   : std_logic_vector(2 DOWNTO 0) := "000";
  SIGNAL dac_q   : std_logic_vector(7 DOWNTO 0) := x"80";
  SIGNAL dac_sgn : signed(15 DOWNTO 0) := (OTHERS => '0');

BEGIN

  io_hit  <= '1' WHEN ADDR(15 DOWNTO 4) = IO_BASE(15 DOWNTO 4) ELSE '0';
  io_reg  <= ADDR(3 DOWNTO 0);
  wr_rise <= '1' WHEN (wr_prev = '1' AND WR = '0') ELSE '0';
  -- CONSUME A BUFFERED BYTE AT THE END OF THE READ, NOT THE BEGINNING.
  --
  -- This was the falling edge of RD, which is when the CPU STARTS a read. The
  -- V20 latches read data at the end of the cycle, so advancing the buffer
  -- there meant the byte had already been replaced by the next one before the
  -- CPU sampled it: GET VERSION returned 01 01 instead of 02 01, and reported
  -- a DSP 1.1 that has never existed.
  --
  -- dma8237 records the same rule for writes -- latch on the RISING edge of
  -- the strobe, when the data has been stable throughout the cycle. It applies
  -- just as much to a side effect on a read.
  rd_done <= '1' WHEN (rd_prev = '0' AND RD = '1') ELSE '0';

  DRQ <= drq_r;
  IRQ <= irq_r;

  -- 48 * (256 - tconst), as shifts: 32x + 16x.
  div_top <= (resize(256 - tconst, 14) sll 5) + (resize(256 - tconst, 14) sll 4);

  -- ==========================================================================
  --  CPU side: registers, the command machine, and the DMA handshake
  -- ==========================================================================
  BUS_P : PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      wr_prev <= WR;
      rd_prev <= RD;
      dack_p  <= DACK;

      -- ---- sample clock request, from CLK48 --------------------------------
      smp_s <= smp_s(1 DOWNTO 0) & smp_tgl;
      smp_p <= smp_s(2);

      -- A sample is due. Ask the 8237 for the next byte, unless there is
      -- nothing to play or the game has paused us.
      IF (smp_s(2) /= smp_p) AND playing = '1' AND paused = '0' THEN
        drq_r <= '1';
      END IF;

      -- ---- the 8237 handed a byte over -------------------------------------
      -- TIMED BY /IOW, which is the signal that exists to say exactly this.
      --
      -- DACK is not the right reference and two attempts at using it failed
      -- for the same reason: it is asserted in D_HOLD and stays asserted after
      -- the memory strobe has released, so anything keyed to it samples a bus
      -- nobody is driving. The 8237 deasserts /IOW on the cycle RAM_READY
      -- arrives -- data valid throughout the strobe, taken at its end, which
      -- is the ordinary contract for every device on this bus.
      --
      -- It was generated all along and wired to OPEN in the top level.
      iow_p <= IOW;
      IF DACK = '1' AND IOW = '0' THEN
        dma_lat <= DMA_DIN;
      END IF;
      IF DACK = '1' AND iow_p = '0' AND IOW = '1' THEN
        dac_hold <= dma_lat;
        dac_tgl  <= NOT dac_tgl;
        drq_r    <= '0';

        IF TC = '1' OR remain = 0 THEN
          irq_r <= '1';                    -- buffer done: interrupt the CPU
          IF autoin = '1' THEN
            remain <= blk_len;             -- round again, no CPU involvement
          ELSE
            playing <= '0';
          END IF;
        ELSE
          remain <= remain - 1;
        END IF;
      END IF;

      -- ---- CPU writes ------------------------------------------------------
      IF io_hit = '1' AND wr_rise = '1' THEN
        CASE io_reg IS

          WHEN x"6" =>                     -- RESET
            IF DATAIN(0) = '1' THEN
              rst_arm <= '1';
            ELSIF rst_arm = '1' THEN
              -- The 1-then-0 sequence completed. Answer 0xAA and drop
              -- everything a previous program left running: a reset is the one
              -- thing a game does when it has lost track of the card, and it
              -- has to be able to trust the state afterwards.
              rst_arm <= '0';
              rd_a    <= x"AA";
              rd_n    <= 1;
              pcnt    <= 0;
              playing <= '0';
              paused  <= '0';
              autoin  <= '0';
              drq_r   <= '0';
              irq_r   <= '0';
              dac_hold<= x"80";
            END IF;

          WHEN x"C" =>                     -- COMMAND / parameter
            IF pcnt /= 0 THEN
              -- a parameter for the command already in cmd
              IF pcnt = 2 THEN
                p1   <= DATAIN;
                pcnt <= 1;
              ELSE
                pcnt <= 0;
                CASE cmd IS
                  WHEN x"10" =>            -- direct DAC
                    dac_hold <= DATAIN;
                    dac_tgl  <= NOT dac_tgl;
                  WHEN x"14" =>            -- single-cycle DMA, p1 = lo
                    remain  <= unsigned(DATAIN & p1);
                    blk_len <= unsigned(DATAIN & p1);
                    autoin  <= '0';
                    paused  <= '0';
                    playing <= '1';
                  WHEN x"48" =>            -- block length for auto-init
                    blk_len <= unsigned(DATAIN & p1);
                  WHEN x"40" =>            -- time constant
                    tconst <= unsigned(p1);
                  WHEN x"E0" =>            -- identify
                    rd_a <= NOT p1;
                    rd_n <= 1;
                  WHEN OTHERS => NULL;
                END CASE;
              END IF;
            ELSE
              cmd <= DATAIN;
              CASE DATAIN IS
                WHEN x"10" => pcnt <= 1;
                WHEN x"14" => pcnt <= 2;
                WHEN x"48" => pcnt <= 2;
                WHEN x"40" => pcnt <= 1;
                WHEN x"E0" => pcnt <= 1;

                WHEN x"1C" =>              -- auto-init DMA output
                  remain  <= blk_len;
                  autoin  <= '1';
                  paused  <= '0';
                  playing <= '1';

                WHEN x"D0" => paused  <= '1';
                WHEN x"D4" => paused  <= '0';
                WHEN x"D1" => spk_on  <= '1';
                WHEN x"D3" => spk_on  <= '0';

                WHEN x"E1" =>              -- version: 2.01
                  rd_a <= x"02";
                  rd_b <= x"01";
                  rd_n <= 2;

                WHEN OTHERS => NULL;       -- unknown: swallow, do not hang
              END CASE;
            END IF;

          WHEN OTHERS => NULL;
        END CASE;
      END IF;

      -- ---- CPU reads -------------------------------------------------------
      IF io_hit = '1' AND rd_done = '1' THEN
        IF io_reg = x"A" THEN
          IF rd_n = 2 THEN
            rd_a <= rd_b;
            rd_n <= 1;
          ELSIF rd_n = 1 THEN
            rd_n <= 0;
          END IF;
        ELSIF io_reg = x"E" THEN
          -- Reading the status port acknowledges the 8-bit interrupt. Every SB
          -- handler ends this way, and a card that does not clear here leaves
          -- IR5 asserted and the machine in an interrupt storm.
          irq_r <= '0';
        END IF;
      END IF;

      IF RESET = '1' THEN
        pcnt <= 0; rd_n <= 0; playing <= '0'; paused <= '0'; autoin <= '0';
        drq_r <= '0'; irq_r <= '0'; spk_on <= '0'; rst_arm <= '0';
        dac_hold <= x"80"; tconst <= x"A6";
      END IF;
    END IF;
  END PROCESS;

  -- Shared tri-state read bus: drive only when addressed and only during a read
  -- 2xF is not a Sound Blaster register. It reads back the last byte the DMA
  -- actually delivered, because "the transfer completed" and "the right bytes
  -- arrived" are different claims and nothing else in this path distinguishes
  -- them. A tool can compare what it reads here against the buffer it queued.
  DATAOUT <= dac_hold                              WHEN (io_hit='1' AND RD='0' AND io_reg=x"F") ELSE
             rd_a                                  WHEN (io_hit='1' AND RD='0' AND io_reg=x"A") ELSE
             x"00"                                 WHEN (io_hit='1' AND RD='0' AND io_reg=x"C") ELSE
             (7 => '1', OTHERS => '0')             WHEN (io_hit='1' AND RD='0' AND io_reg=x"E"
                                                         AND rd_n /= 0) ELSE
             x"7F"                                 WHEN (io_hit='1' AND RD='0' AND io_reg=x"E") ELSE
             (OTHERS => 'Z');

  -- ==========================================================================
  --  48 MHz side: the sample clock, and the mix
  -- ==========================================================================
  AUD_P : PROCESS (CLK48)
  BEGIN
    IF rising_edge(CLK48) THEN
      -- Free-running divider. It keeps counting when nothing is playing, which
      -- costs nothing and means the first sample after a start is on time
      -- rather than up to one period late.
      IF div >= div_top THEN
        div     <= (OTHERS => '0');
        smp_tgl <= NOT smp_tgl;
      ELSE
        div <= div + 1;
      END IF;

      -- dac_hold, qualified by its toggle: the byte has been stable for tens of
      -- microseconds by the time three flops have passed the toggle across.
      dac_s <= dac_s(1 DOWNTO 0) & dac_tgl;
      IF dac_s(2) /= dac_s(1) THEN
        dac_q <= dac_hold;
      END IF;

      -- 8-bit unsigned, mid-scale 0x80, to signed 16-bit. Silence is 0x80 and
      -- must come out as zero, or a stopped DAC would sit at half full scale
      -- and add a step to everything the OPL2 plays.
      IF spk_on = '1' THEN
        dac_sgn <= resize(signed(unsigned(dac_q) - 128) & "00000000", 16);
      ELSE
        dac_sgn <= (OTHERS => '0');
      END IF;

      PCM_STB <= PCM_STB_IN;
      IF PCM_STB_IN = '1' THEN
        -- Sum with saturation. FM at full tilt plus a loud sample overflows a
        -- 16-bit signed sum, and an overflow wraps -- which is not a loud
        -- noise, it is the loudest possible noise, with the sign inverted.
        IF    (signed(PCM_IN) > 0) AND (dac_sgn > 0) AND
              (signed(PCM_IN) + dac_sgn < 0) THEN
          PCM <= x"7FFF";
        ELSIF (signed(PCM_IN) < 0) AND (dac_sgn < 0) AND
              (signed(PCM_IN) + dac_sgn > 0) THEN
          PCM <= x"8000";
        ELSE
          PCM <= std_logic_vector(signed(PCM_IN) + dac_sgn);
        END IF;
      END IF;
    END IF;
  END PROCESS;

END behavior;
