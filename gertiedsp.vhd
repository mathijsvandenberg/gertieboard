--------------------------------------------------------------------------------
-- gertiedsp.vhd  --  the GertieDSP: hardware sample playback at I/O 0x300
--
-- See docs/gertiedsp.md. Eight voices, each with a start/end/loop address,
-- a 16.16 phase increment and a volume, mixed in fabric at 48 kHz and summed
-- into the PCM stream the USB audio path already carries.
--
-- WHICH CLOCK THE VOICES RUN ON, AND WHY IT IS THE MEMORY ONE
--
--   The arbiter and the SDRAM run on c3 at 50 MHz; the USB audio path runs on
--   CLK48. The voices could live on either, and the fetch decides it: on CLK48
--   every one of eight voices would need an address and a byte handed across a
--   clock boundary 48,000 times a second, which is eight handshakes to get
--   right. On c3 the fetch is local and only the finished mix crosses -- one
--   16-bit value, once per sample.
--
--   That is only safe because both clocks come from the SAME 50 MHz crystal
--   through two PLLs. The 50:48 ratio is exact and fixed, so a tick generated
--   here by adding 48000 and subtracting 50000000 lands in step with CLK48's
--   own 48 kHz for ever. Two independent crystals would drift and this would
--   have to be a resampler instead.
--
-- DETECTION
--
--   Reads and writes differ on the first three ports. 0x300 reads 'G', 0x301
--   reads 'V', 0x302 reads the voice count. An absent engine reads 0xFF from
--   an open bus or 0x00 from a decoded-but-empty one, and neither spells GV --
--   which matters, because "something answered" is not evidence. The floppy
--   path answers AH=08 for any drive number with carry clear, and BIOSFLASH
--   nearly wrote a BIOS image onto a diskette on the strength of it.
--
-- CLOCK CROSSING
--
--   The registers are written in the bus domain and read at 48 MHz. Multi-byte
--   values would tear if read while being written, so they are written into
--   SHADOWS and copied to the live registers on a per-voice toggle. Writing
--   the HIGH byte of any multi-byte field, or CTL, flips that voice's toggle;
--   the 48 MHz side copies on the synchronised edge, by which time the shadow
--   has been stable for three of its clocks.
--
--   VOL is one byte and cannot tear, so it crosses directly. It is also the
--   register an effect writes most often, and making it wait for a commit
--   would put a tremolo a tick behind everything else.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;
USE  IEEE.NUMERIC_STD.ALL;

ENTITY gertiedsp IS
  GENERIC(
        IO_BASE : std_logic_vector(15 DOWNTO 0) := x"0300";
        NVOICE  : integer := 8);
  PORT(
        CLK        : IN    std_logic;                    -- CPU bus clock
        RESET      : IN    std_logic;
        ADDR       : IN    std_logic_vector(15 DOWNTO 0);
        RD         : IN    std_logic;                    -- active LOW
        WR         : IN    std_logic;                    -- active LOW
        DATAIN     : IN    std_logic_vector(7 DOWNTO 0);
        DATAOUT    : INOUT std_logic_vector(7 DOWNTO 0); -- 'Z' when not addressed

        -- audio, 48 MHz domain. Same pass-through shape as sb_dsp: take the
        -- stream in, add to it, hand it on. No mixer module needed anywhere.
        -- the memory clock, and this module's read-only SDRAM client
        CLKMEM     : IN    std_logic := '0';
        SD_REQ     : OUT   std_logic;
        SD_A       : OUT   std_logic_vector(23 DOWNTO 0);
        SD_ACK     : IN    std_logic := '0';
        SD_D       : IN    std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');

        CLK48      : IN    std_logic := '0';
        PCM_IN     : IN    std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
        PCM_STB_IN : IN    std_logic := '0';
        PCM        : OUT   std_logic_vector(15 DOWNTO 0);
        PCM_STB    : OUT   std_logic);
END gertiedsp;

ARCHITECTURE behavior OF gertiedsp IS

  TYPE u20_arr IS ARRAY(0 TO NVOICE-1) OF unsigned(19 DOWNTO 0);
  TYPE u24_arr IS ARRAY(0 TO NVOICE-1) OF unsigned(23 DOWNTO 0);
  TYPE u32_arr IS ARRAY(0 TO NVOICE-1) OF unsigned(31 DOWNTO 0);
  TYPE u7_arr  IS ARRAY(0 TO NVOICE-1) OF unsigned(6 DOWNTO 0);
  TYPE u3_arr  IS ARRAY(0 TO NVOICE-1) OF std_logic_vector(2 DOWNTO 0);

  -- ---- bus side ------------------------------------------------------------
  SIGNAL io_hit  : std_logic;
  SIGNAL io_reg  : std_logic_vector(3 DOWNTO 0);
  SIGNAL wr_prev : std_logic := '1';
  SIGNAL wr_rise : std_logic;
  SIGNAL vsel    : integer RANGE 0 TO NVOICE-1 := 0;

  -- shadows, written by the CPU
  SIGNAL sh_start : u20_arr := (OTHERS => (OTHERS => '0'));
  SIGNAL sh_endp  : u20_arr := (OTHERS => (OTHERS => '0'));
  SIGNAL sh_loop  : u20_arr := (OTHERS => (OTHERS => '0'));
  SIGNAL sh_step  : u24_arr := (OTHERS => (OTHERS => '0'));
  SIGNAL sh_ctl   : u3_arr  := (OTHERS => (OTHERS => '0'));
  SIGNAL commit   : std_logic_vector(NVOICE-1 DOWNTO 0) := (OTHERS => '0');

  -- volume crosses directly: one byte cannot tear
  SIGNAL v_vol    : u7_arr := (OTHERS => (OTHERS => '0'));

  -- ---- 48 MHz side ---------------------------------------------------------
  SIGNAL lv_start : u20_arr := (OTHERS => (OTHERS => '0'));
  SIGNAL lv_endp  : u20_arr := (OTHERS => (OTHERS => '0'));
  SIGNAL lv_loop  : u20_arr := (OTHERS => (OTHERS => '0'));
  SIGNAL lv_step  : u24_arr := (OTHERS => (OTHERS => '0'));
  SIGNAL lv_run   : std_logic_vector(NVOICE-1 DOWNTO 0) := (OTHERS => '0');
  SIGNAL lv_lp    : std_logic_vector(NVOICE-1 DOWNTO 0) := (OTHERS => '0');
  SIGNAL pos      : u32_arr := (OTHERS => (OTHERS => '0'));  -- 16.16 from start

  SIGNAL cm_s1, cm_s2, cm_s3 : std_logic_vector(NVOICE-1 DOWNTO 0)
                                 := (OTHERS => '0');

  -- 48 kHz from 50 MHz, which does not divide: add 48000 every clock and take
  -- a tick whenever the accumulator passes 50,000,000. Exactly 48000 ticks per
  -- second on average, and in step with CLK48 because both come from the same
  -- crystal.
  CONSTANT NCO_INC : integer := 48000;
  CONSTANT NCO_TOP : integer := 50000000;
  SIGNAL nco     : integer RANGE 0 TO NCO_TOP+NCO_INC := 0;
  SIGNAL tick    : std_logic := '0';

  -- The cached sample byte for each voice, and where it came from. A voice
  -- mixes what it has while the fetch engine goes and gets what it will need.
  TYPE b8_arr IS ARRAY(0 TO NVOICE-1) OF std_logic_vector(7 DOWNTO 0);
  SIGNAL have_byte : b8_arr  := (OTHERS => (OTHERS => '0'));
  SIGNAL have_addr : u20_arr := (OTHERS => (OTHERS => '1'));
  SIGNAL want_addr : u20_arr := (OTHERS => (OTHERS => '0'));

  TYPE fetch_t IS (F_SCAN, F_REQ, F_WAIT);
  SIGNAL fst   : fetch_t := F_SCAN;
  SIGNAL fv    : integer RANGE 0 TO NVOICE-1 := 0;
  SIGNAL sd_rq : std_logic := '0';
  SIGNAL sd_ad : unsigned(23 DOWNTO 0) := (OTHERS => '0');

  -- cpu byte address -> sdram word, the mapping sdram_mem uses. Both must
  -- agree exactly or the voices read a different memory from the one the CPU
  -- wrote the samples into.
  CONSTANT SDRAM_BASE : unsigned(23 DOWNTO 0) := x"020000";

  -- the finished mix, crossing to CLK48
  SIGNAL mix_r   : signed(17 DOWNTO 0) := (OTHERS => '0');
  SIGNAL mix_tgl : std_logic := '0';
  SIGNAL mx_s    : std_logic_vector(2 DOWNTO 0) := "000";

  SIGNAL acc     : signed(17 DOWNTO 0) := (OTHERS => '0');
  SIGNAL mixed   : signed(15 DOWNTO 0) := (OTHERS => '0');

  -- "which voices are still playing", for the CPU to read
  SIGNAL act_s1, act_s2 : std_logic_vector(NVOICE-1 DOWNTO 0)
                            := (OTHERS => '0');

BEGIN

  io_hit  <= '1' WHEN ADDR(15 DOWNTO 4) = IO_BASE(15 DOWNTO 4) ELSE '0';
  io_reg  <= ADDR(3 DOWNTO 0);
  wr_rise <= '1' WHEN (wr_prev = '1' AND WR = '0') ELSE '0';

  -- ==========================================================================
  --  CPU side: shadow registers
  -- ==========================================================================
  BUS_P : PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      wr_prev <= WR;

      IF io_hit = '1' AND wr_rise = '1' THEN
        CASE io_reg IS
          WHEN x"0" =>
            IF to_integer(unsigned(DATAIN(2 DOWNTO 0))) < NVOICE THEN
              vsel <= to_integer(unsigned(DATAIN(2 DOWNTO 0)));
            END IF;

          -- CTL commits. A note is written as a burst -- addresses, step,
          -- volume -- and CTL last, so committing here makes the whole voice
          -- change at once rather than one field at a time.
          WHEN x"1" =>
            sh_ctl(vsel)  <= DATAIN(2 DOWNTO 0);
            commit(vsel)  <= NOT commit(vsel);

          WHEN x"2" => v_vol(vsel) <= unsigned(DATAIN(6 DOWNTO 0));

          WHEN x"3" => sh_start(vsel)( 7 DOWNTO 0)  <= unsigned(DATAIN);
          WHEN x"4" => sh_start(vsel)(15 DOWNTO 8)  <= unsigned(DATAIN);
          WHEN x"5" => sh_start(vsel)(19 DOWNTO 16) <= unsigned(DATAIN(3 DOWNTO 0));

          WHEN x"6" => sh_endp(vsel)( 7 DOWNTO 0)   <= unsigned(DATAIN);
          WHEN x"7" => sh_endp(vsel)(15 DOWNTO 8)   <= unsigned(DATAIN);
          WHEN x"8" => sh_endp(vsel)(19 DOWNTO 16)  <= unsigned(DATAIN(3 DOWNTO 0));

          WHEN x"9" => sh_loop(vsel)( 7 DOWNTO 0)   <= unsigned(DATAIN);
          WHEN x"A" => sh_loop(vsel)(15 DOWNTO 8)   <= unsigned(DATAIN);
          WHEN x"B" => sh_loop(vsel)(19 DOWNTO 16)  <= unsigned(DATAIN(3 DOWNTO 0));

          WHEN x"C" => sh_step(vsel)( 7 DOWNTO 0)   <= unsigned(DATAIN);
          WHEN x"D" => sh_step(vsel)(15 DOWNTO 8)   <= unsigned(DATAIN);
          -- the high byte commits too, so a pitch change mid-note takes
          -- effect without needing CTL rewritten
          WHEN x"E" =>
            sh_step(vsel)(23 DOWNTO 16) <= unsigned(DATAIN);
            commit(vsel) <= NOT commit(vsel);

          WHEN OTHERS => NULL;
        END CASE;
      END IF;

      IF RESET = '1' THEN
        vsel   <= 0;
        commit <= (OTHERS => '0');
        v_vol  <= (OTHERS => (OTHERS => '0'));
        sh_ctl <= (OTHERS => (OTHERS => '0'));
      END IF;
    END IF;
  END PROCESS;

  -- Shared tri-state read bus: only when addressed and only during a read.
  DATAOUT <= x"47"                                   -- 'G'
                WHEN (io_hit='1' AND RD='0' AND io_reg=x"0") ELSE
             x"56"                                   -- 'V'
                WHEN (io_hit='1' AND RD='0' AND io_reg=x"1") ELSE
             std_logic_vector(to_unsigned(NVOICE, 8))
                WHEN (io_hit='1' AND RD='0' AND io_reg=x"2") ELSE
             act_s2
                WHEN (io_hit='1' AND RD='0' AND io_reg=x"F") ELSE
             (OTHERS => 'Z');

  -- ==========================================================================
  --  Memory clock: commit, phase, fetch, mix
  -- ==========================================================================
  SD_REQ <= sd_rq;
  SD_A   <= std_logic_vector(sd_ad);

  MEM_P : PROCESS (CLKMEM)
    VARIABLE nxt  : unsigned(31 DOWNTO 0);
    VARIABLE cur  : unsigned(19 DOWNTO 0);
    VARIABLE smp  : signed(7 DOWNTO 0);
    VARIABLE prod : signed(15 DOWNTO 0);
    VARIABLE sum  : signed(17 DOWNTO 0);
  BEGIN
    IF rising_edge(CLKMEM) THEN
      -- three flops on every commit toggle; the shadow it qualifies has been
      -- stable for all three by the time the edge is seen
      cm_s1 <= commit;
      cm_s2 <= cm_s1;
      cm_s3 <= cm_s2;

      FOR v IN 0 TO NVOICE-1 LOOP
        IF cm_s3(v) /= cm_s2(v) THEN
          lv_start(v) <= sh_start(v);
          lv_endp(v)  <= sh_endp(v);
          lv_loop(v)  <= sh_loop(v);
          lv_step(v)  <= sh_step(v);
          lv_run(v)   <= sh_ctl(v)(0);
          lv_lp(v)    <= sh_ctl(v)(1);
          IF sh_ctl(v)(2) = '1' THEN         -- KEYON restarts from the top
            pos(v)       <= (OTHERS => '0');
            want_addr(v) <= sh_start(v);
            have_addr(v) <= (OTHERS => '1'); -- force a fetch before it sounds
          END IF;
        END IF;
      END LOOP;

      -- ---- 48 kHz, by accumulation rather than division ----
      tick <= '0';
      IF nco >= NCO_TOP THEN
        nco  <= nco - NCO_TOP + NCO_INC;
        tick <= '1';
      ELSE
        nco <= nco + NCO_INC;
      END IF;

      IF tick = '1' THEN
        sum := (OTHERS => '0');
        FOR v IN 0 TO NVOICE-1 LOOP
          IF lv_run(v) = '1' THEN
            -- What the fetch engine has, not what the position now points at.
            -- A voice mixes the byte it was given while the engine goes for
            -- the next: that is the whole reason this client can sit at the
            -- bottom of the arbiter's priority list.
            smp := signed(have_byte(v));

            prod := smp * signed('0' & std_logic_vector(v_vol(v)));
            sum  := sum + resize(prod, 18);

            nxt := pos(v) + resize(lv_step(v), 32);
            cur := lv_start(v) + nxt(31 DOWNTO 16);
            IF cur >= lv_endp(v) THEN
              IF lv_lp(v) = '1' THEN
                -- Back to the loop point, as an OFFSET from start. Both are
                -- 20-bit addresses and the difference is taken to 16 bits,
                -- which bounds a voice's sample at 64 KB -- exactly what a MOD
                -- sample can be, and the same 16-bit position the accumulator
                -- carries.
                nxt(31 DOWNTO 16) := resize(lv_loop(v) - lv_start(v), 16);
                cur := lv_loop(v);
              ELSE
                lv_run(v) <= '0';
              END IF;
            END IF;
            pos(v)       <= nxt;
            want_addr(v) <= cur;
          END IF;
        END LOOP;

        mix_r   <= sum;
        mix_tgl <= NOT mix_tgl;
      END IF;

      -- ---- fetch engine ----
      -- One byte at a time, round robin. Eight voices at 48 kHz is 384,000
      -- reads a second and an access is a handful of clocks, so this is idle
      -- most of the time -- but walking the voices rather than serving them in
      -- a burst keeps any one of them from monopolising the port.
      CASE fst IS
        WHEN F_SCAN =>
          sd_rq <= '0';
          IF lv_run(fv) = '1' AND want_addr(fv) /= have_addr(fv) THEN
            -- sdram word = base + (cpu byte address / 2). The same mapping
            -- sdram_mem uses; if the two ever disagree the voices read a
            -- different memory from the one the samples were loaded into.
            sd_ad <= SDRAM_BASE + resize(want_addr(fv)(19 DOWNTO 1), 24);
            sd_rq <= '1';
            fst   <= F_REQ;
          ELSE
            IF fv = NVOICE-1 THEN fv <= 0; ELSE fv <= fv + 1; END IF;
          END IF;

        WHEN F_REQ =>
          -- REQ stays up until ACK: the controller requires it and the arbiter
          -- latches its grant on the strength of it.
          IF SD_ACK = '1' THEN
            IF want_addr(fv)(0) = '0' THEN
              have_byte(fv) <= SD_D(7 DOWNTO 0);
            ELSE
              have_byte(fv) <= SD_D(15 DOWNTO 8);
            END IF;
            have_addr(fv) <= want_addr(fv);
            sd_rq <= '0';
            fst   <= F_WAIT;
          END IF;

        WHEN F_WAIT =>
          IF fv = NVOICE-1 THEN fv <= 0; ELSE fv <= fv + 1; END IF;
          fst <= F_SCAN;
      END CASE;

      IF RESET = '1' THEN
        lv_run <= (OTHERS => '0');
        sd_rq  <= '0';
        fst    <= F_SCAN;
        fv     <= 0;
      END IF;
    END IF;
  END PROCESS;

  -- ==========================================================================
  --  48 MHz side: take the finished mix across, and add it to the stream
  -- ==========================================================================
  OUT_P : PROCESS (CLK48)
  BEGIN
    IF rising_edge(CLK48) THEN
      -- mix_r is stable long before its toggle arrives: it changes once per
      -- 48 kHz sample and the toggle takes three of these clocks to cross.
      mx_s <= mx_s(1 DOWNTO 0) & mix_tgl;
      IF mx_s(2) /= mx_s(1) THEN
        mixed <= resize(shift_right(mix_r, 2), 16);
      END IF;

      act_s1 <= lv_run;
      act_s2 <= act_s1;

      PCM_STB <= PCM_STB_IN;
      IF PCM_STB_IN = '1' THEN
        -- Saturate. An overflowing signed sum does not become quiet, it becomes
        -- the loudest possible noise with the sign inverted.
        IF    (signed(PCM_IN) > 0) AND (mixed > 0) AND
              (signed(PCM_IN) + mixed < 0) THEN
          PCM <= x"7FFF";
        ELSIF (signed(PCM_IN) < 0) AND (mixed < 0) AND
              (signed(PCM_IN) + mixed > 0) THEN
          PCM <= x"8000";
        ELSE
          PCM <= std_logic_vector(signed(PCM_IN) + mixed);
        END IF;
      END IF;
    END IF;
  END PROCESS;

END behavior;
