--------------------------------------------------------------------------------
-- usb_audio.vhd  --  control registers for the isochronous audio streamer
--
-- The streaming engine itself lives in usb_host, because it has to inject a
-- transaction into that sequencer's frame. This module is only the CPU-facing
-- side of it: which device to send to, how much, how loud, and whether to run.
--
-- WHY A SEPARATE MODULE AND NOT FOUR MORE usb_host REGISTERS
--
--   usb_host's window is exactly eight registers and all eight are in use, by
--   a BIOS and four DOS tools that address them literally. Widening it to
--   sixteen would move the second instance off its 8-byte alignment (0xA8 is
--   not 16-byte aligned), and stealing bits out of the existing registers
--   would change the meaning of writes that existing software already makes.
--   A separate window costs one decode and breaks nothing.
--
--   0xA0-0xA7 is free and sits directly below USB1's 0xA8-0xAF, which is the
--   port the audio device is on. The adjacency is the documentation.
--
-- I/O MAP
-- -------
--   0xA0  W  CTL    [0] EN     -- stream one packet per frame while set
--                   [1] CLRERR -- write 1 to clear the sticky underrun flag
--         R  STAT   [0] EN
--                   [1] UNDER  -- sticky: a frame went out short. See below.
--                   [7:4] 0xA -- signature, so a tool can tell this module is
--                               present rather than reading back a floating bus
--   0xA1  W  ADDR   [6:0] USB device address of the audio device
--   0xA2  W  ENDP   [3:0] its isochronous OUT endpoint number
--   0xA3  W  NSMP   samples per frame. 48 for 48 kHz, which is the only rate
--                   that divides the 1 ms frame exactly and the reason the
--                   PCM tap runs at 48 kHz rather than the OPL2's 49716.
--   0xA4  W  GAIN   [2:0] right shift applied to every sample, 0 = loudest
--   0xA5  R  UNDERN low 8 bits of a count of short frames, for a tool that
--                   wants a rate rather than a flag
--
-- SET ADDR, ENDP, NSMP AND GAIN BEFORE SETTING EN. They cross into the 48 MHz
-- domain unsynchronised, which is safe only because they are static by the
-- time anything reads them; EN is the one bit that changes while the engine is
-- running, and usb_host synchronises that one properly.
--
-- UNDER means the PCM writer did not fill a whole frame before the swap. Both
-- the 48 kHz sample clock and the 1 kHz frame clock are divided from the same
-- 48 MHz PLL output, so they cannot drift apart -- if this flag ever sets, the
-- fault is structural (CLK48 not connected, PCM_STB not arriving) and not a
-- timing margin to be tuned.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;
USE  IEEE.NUMERIC_STD.ALL;

ENTITY usb_audio IS
  GENERIC(
        IO_BASE : std_logic_vector(15 DOWNTO 0) := x"00A0");
  PORT(
        CLK     : IN    std_logic;                      -- peripheral clock
        RESET   : IN    std_logic;
        DATA    : IN    std_logic_vector(7 DOWNTO 0);
        ADDR    : IN    std_logic_vector(15 DOWNTO 0);
        RD      : IN    std_logic;                      -- active LOW
        WR      : IN    std_logic;                      -- active LOW
        DATAOUT : INOUT std_logic_vector(7 DOWNTO 0);

        -- to usb_host's streamer
        AUD_EN    : OUT std_logic;
        AUD_ADDR  : OUT std_logic_vector(6 DOWNTO 0);
        AUD_ENDP  : OUT std_logic_vector(3 DOWNTO 0);
        AUD_NSMP  : OUT std_logic_vector(7 DOWNTO 0);
        AUD_GAIN  : OUT std_logic_vector(2 DOWNTO 0);
        AUD_UNDER : IN  std_logic := '0');
END usb_audio;

ARCHITECTURE behavior OF usb_audio IS

  SIGNAL r_en    : std_logic := '0';
  SIGNAL r_addr  : std_logic_vector(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL r_endp  : std_logic_vector(3 DOWNTO 0) := (OTHERS => '0');
  SIGNAL r_nsmp  : std_logic_vector(7 DOWNTO 0) := x"30";   -- 48
  SIGNAL r_gain  : std_logic_vector(2 DOWNTO 0) := (OTHERS => '0');

  SIGNAL und_s1, und_s2, und_p : std_logic := '0';
  SIGNAL und_sticky : std_logic := '0';
  SIGNAL und_cnt    : unsigned(7 DOWNTO 0) := (OTHERS => '0');

  -- Writes must be taken on the EDGE of WR. busdecode's strobes are
  -- combinational passthroughs that stay asserted for the whole bus cycle, so
  -- a level-triggered write lands several times -- harmless for a plain value
  -- register, not harmless for the write-1-to-clear bit below, which would
  -- swallow an underrun that arrived during the same cycle. Same trap, and the
  -- same fix, as usb_host and flash.
  SIGNAL wr_prev : std_logic := '1';
  SIGNAL wr_rise : std_logic;

  SIGNAL io_hit  : std_logic;
  SIGNAL io_reg  : std_logic_vector(2 DOWNTO 0);

BEGIN

  io_hit  <= '1' WHEN ADDR(15 DOWNTO 3) = IO_BASE(15 DOWNTO 3) ELSE '0';
  io_reg  <= ADDR(2 DOWNTO 0);
  wr_rise <= '1' WHEN (wr_prev = '1' AND WR = '0') ELSE '0';

  AUD_EN   <= r_en;
  AUD_ADDR <= r_addr;
  AUD_ENDP <= r_endp;
  AUD_NSMP <= r_nsmp;
  AUD_GAIN <= r_gain;

  REGS : PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      wr_prev <= WR;

      -- AUD_UNDER is set in the 48 MHz domain and read here. Two flops to
      -- resolve it, then an edge detect: the flag is a level over there and a
      -- count is wanted here, so a level would add one per bus clock.
      und_s1 <= AUD_UNDER;
      und_s2 <= und_s1;
      und_p  <= und_s2;
      IF und_s2 = '1' AND und_p = '0' THEN
        und_sticky <= '1';
        IF und_cnt /= x"FF" THEN            -- saturate rather than wrap, so a
          und_cnt <= und_cnt + 1;           -- reading of 255 stays alarming
        END IF;
      END IF;

      IF io_hit = '1' AND wr_rise = '1' THEN
        CASE io_reg IS
          WHEN "000" =>
            r_en <= DATA(0);
            IF DATA(1) = '1' THEN
              und_sticky <= '0';
              und_cnt    <= (OTHERS => '0');
            END IF;
          WHEN "001" => r_addr <= DATA(6 DOWNTO 0);
          WHEN "010" => r_endp <= DATA(3 DOWNTO 0);
          WHEN "011" => r_nsmp <= DATA;
          WHEN "100" => r_gain <= DATA(2 DOWNTO 0);
          WHEN OTHERS => NULL;
        END CASE;
      END IF;

      IF RESET = '1' THEN
        r_en <= '0'; und_sticky <= '0'; und_cnt <= (OTHERS => '0');
      END IF;
    END IF;
  END PROCESS;

  -- Shared tri-state read bus: drive only when addressed and only during a read
  DATAOUT <= x"A" & "00" & und_sticky & r_en
                WHEN (io_hit = '1' AND RD = '0' AND io_reg = "000") ELSE
             std_logic_vector(und_cnt)
                WHEN (io_hit = '1' AND RD = '0' AND io_reg = "101") ELSE
             (OTHERS => 'Z');

END behavior;
