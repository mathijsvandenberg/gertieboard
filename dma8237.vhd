--------------------------------------------------------------------------------
-- dma8237.vhd  --  Minimal 8237A DMA Controller
--
-- Behavioural model of the 8237A as used in the IBM PC/XT, with the
-- assumption that no real DMA-using cards (FDC, HDC, SDLC, sound) are
-- installed.  All four channels remain idle; no bus mastering ever
-- happens.  What this module DOES implement, completely, is the
-- programmer's-view register set:
--
--   I/O range 0x00 - 0x0F (lower 4 bits select the register)
--
--   0x0 : Ch0 current/base address  (16-bit via byte-pointer FF)
--   0x1 : Ch0 current/base word cnt (16-bit via byte-pointer FF)
--   0x2 : Ch1 current/base address
--   0x3 : Ch1 current/base word cnt
--   0x4 : Ch2 current/base address
--   0x5 : Ch2 current/base word cnt
--   0x6 : Ch3 current/base address
--   0x7 : Ch3 current/base word cnt
--   0x8 : R = Status, W = Command
--   0x9 : W = Request (software DREQ)
--   0xA : W = Single Mask bit
--   0xB : W = Mode
--   0xC : W = Clear Byte Pointer FF
--   0xD : R = Temp,   W = Master Clear
--   0xE : W = Clear Mask register
--   0xF : W = Write Mask register (all 4 bits)
--
-- The byte-pointer flip-flop toggles on every read or write of an
-- address/count register, and resets to 0 on master clear, hard reset,
-- and writes to 0x0C.  All channels are masked at reset (mask reg = 0xF).
--
-- Page registers (0x81/0x82/0x83/0x87) are NOT in this module - they
-- were a separate latch chip on the real XT.  Add them as a tiny
-- companion module if Ruud's tests ever check them.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY dma8237 IS
  PORT(
        CLK         : IN    std_logic;
        RESET       : IN    std_logic;

        -- CPU bus
        IO_ADDR     : IN    std_logic_vector(15 DOWNTO 0);
        IO_RD       : IN    std_logic;                       -- active LOW
        IO_WR       : IN    std_logic;                       -- active LOW
        DATAIN      : IN    std_logic_vector(7 DOWNTO 0);
        DATAOUT     : INOUT std_logic_vector(7 DOWNTO 0));   -- 'Z' when not addressed
END dma8237;


ARCHITECTURE behavior OF dma8237 IS

  -- Address decode: chip lives at 0x00 - 0x0F
  SIGNAL cs : std_logic;

  -- ---------------- Register set ------------------------------------------
  TYPE word_array IS ARRAY (0 TO 3) OF std_logic_vector(15 DOWNTO 0);
  TYPE byte_array IS ARRAY (0 TO 3) OF std_logic_vector(7  DOWNTO 0);

  SIGNAL cur_addr  : word_array := (OTHERS => (OTHERS => '0'));
  SIGNAL base_addr : word_array := (OTHERS => (OTHERS => '0'));
  SIGNAL cur_cnt   : word_array := (OTHERS => (OTHERS => '0'));
  SIGNAL base_cnt  : word_array := (OTHERS => (OTHERS => '0'));
  SIGNAL mode_reg  : byte_array := (OTHERS => (OTHERS => '0'));

  SIGNAL command_reg : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL mask_reg    : std_logic_vector(3 DOWNTO 0) := (OTHERS => '1');  -- all masked at reset
  SIGNAL request_reg : std_logic_vector(3 DOWNTO 0) := (OTHERS => '0');
  SIGNAL temp_reg    : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');

  -- Status is combinational: never any TCs (we don't run transfers), and
  -- the software request bits feed the upper nibble.
  SIGNAL status_reg : std_logic_vector(7 DOWNTO 0);

  -- Internal byte-pointer flip-flop (for the 16-bit register pairs)
  SIGNAL bp_ff : std_logic := '0';   -- 0 -> next access is LSB, 1 -> MSB

  -- Edge detection on /IOR and /IOW
  SIGNAL io_rd_prev : std_logic := '1';
  SIGNAL io_wr_prev : std_logic := '1';

  -- Combinational read mux
  SIGNAL read_data : std_logic_vector(7 DOWNTO 0);

BEGIN

  -- ---------------- Address decode ----------------------------------------
  cs <= '1' WHEN IO_ADDR(15 DOWNTO 4) = X"000" ELSE '0';

  -- ---------------- Status register (combinational) -----------------------
  -- Bits 7..4 : channel software-request status
  -- Bits 3..0 : channel terminal-count status (never set in this stub)
  status_reg <= request_reg & "0000";

  -- ---------------- Read data mux -----------------------------------------
  read_mux : PROCESS (IO_ADDR, bp_ff,
                      cur_addr, cur_cnt, status_reg, temp_reg)
  BEGIN
    CASE IO_ADDR(3 DOWNTO 0) IS
      WHEN X"0" => IF bp_ff = '0' THEN read_data <= cur_addr(0)(7 DOWNTO 0);
                   ELSE                read_data <= cur_addr(0)(15 DOWNTO 8); END IF;
      WHEN X"1" => IF bp_ff = '0' THEN read_data <= cur_cnt(0)(7 DOWNTO 0);
                   ELSE                read_data <= cur_cnt(0)(15 DOWNTO 8);  END IF;
      WHEN X"2" => IF bp_ff = '0' THEN read_data <= cur_addr(1)(7 DOWNTO 0);
                   ELSE                read_data <= cur_addr(1)(15 DOWNTO 8); END IF;
      WHEN X"3" => IF bp_ff = '0' THEN read_data <= cur_cnt(1)(7 DOWNTO 0);
                   ELSE                read_data <= cur_cnt(1)(15 DOWNTO 8);  END IF;
      WHEN X"4" => IF bp_ff = '0' THEN read_data <= cur_addr(2)(7 DOWNTO 0);
                   ELSE                read_data <= cur_addr(2)(15 DOWNTO 8); END IF;
      WHEN X"5" => IF bp_ff = '0' THEN read_data <= cur_cnt(2)(7 DOWNTO 0);
                   ELSE                read_data <= cur_cnt(2)(15 DOWNTO 8);  END IF;
      WHEN X"6" => IF bp_ff = '0' THEN read_data <= cur_addr(3)(7 DOWNTO 0);
                   ELSE                read_data <= cur_addr(3)(15 DOWNTO 8); END IF;
      WHEN X"7" => IF bp_ff = '0' THEN read_data <= cur_cnt(3)(7 DOWNTO 0);
                   ELSE                read_data <= cur_cnt(3)(15 DOWNTO 8);  END IF;
      WHEN X"8" => read_data <= status_reg;
      WHEN X"D" => read_data <= temp_reg;
      WHEN OTHERS => read_data <= (OTHERS => '0');
    END CASE;
  END PROCESS;

  DATAOUT <= read_data WHEN (cs = '1' AND IO_RD = '0') ELSE "ZZZZZZZZ";

  -- ---------------- Register writes + BP toggle on reads ------------------
  main : PROCESS (CLK)
    VARIABLE ch : integer RANGE 0 TO 3;
  BEGIN
    IF rising_edge(CLK) THEN
      IF RESET = '1' THEN
        cur_addr    <= (OTHERS => (OTHERS => '0'));
        base_addr   <= (OTHERS => (OTHERS => '0'));
        cur_cnt     <= (OTHERS => (OTHERS => '0'));
        base_cnt    <= (OTHERS => (OTHERS => '0'));
        mode_reg    <= (OTHERS => (OTHERS => '0'));
        command_reg <= (OTHERS => '0');
        mask_reg    <= (OTHERS => '1');
        request_reg <= (OTHERS => '0');
        temp_reg    <= (OTHERS => '0');
        bp_ff       <= '0';
        io_rd_prev  <= '1';
        io_wr_prev  <= '1';

      ELSE
        io_rd_prev <= IO_RD;
        io_wr_prev <= IO_WR;

        -- =============================================================
        -- Latch writes on the RISING edge of /IOW (end of write strobe,
        -- data has been stable on the bus throughout T3).
        -- =============================================================
        IF (io_wr_prev = '0' AND IO_WR = '1' AND cs = '1') THEN
          CASE IO_ADDR(3 DOWNTO 0) IS

            -- ---------------- Address registers (0x0, 0x2, 0x4, 0x6) ---
            WHEN X"0" | X"2" | X"4" | X"6" =>
              ch := conv_integer(IO_ADDR(3 DOWNTO 1));
              IF bp_ff = '0' THEN
                cur_addr(ch)(7 DOWNTO 0)  <= DATAIN;
                base_addr(ch)(7 DOWNTO 0) <= DATAIN;
                bp_ff <= '1';
              ELSE
                cur_addr(ch)(15 DOWNTO 8)  <= DATAIN;
                base_addr(ch)(15 DOWNTO 8) <= DATAIN;
                bp_ff <= '0';
              END IF;

            -- ---------------- Count registers (0x1, 0x3, 0x5, 0x7) -----
            WHEN X"1" | X"3" | X"5" | X"7" =>
              ch := conv_integer(IO_ADDR(3 DOWNTO 1));
              IF bp_ff = '0' THEN
                cur_cnt(ch)(7 DOWNTO 0)  <= DATAIN;
                base_cnt(ch)(7 DOWNTO 0) <= DATAIN;
                bp_ff <= '1';
              ELSE
                cur_cnt(ch)(15 DOWNTO 8)  <= DATAIN;
                base_cnt(ch)(15 DOWNTO 8) <= DATAIN;
                bp_ff <= '0';
              END IF;

            -- ---------------- 0x8 Command register --------------------
            WHEN X"8" =>
              command_reg <= DATAIN;

            -- ---------------- 0x9 Request register --------------------
            --   DATAIN(2)   : 1 = set, 0 = clear
            --   DATAIN(1:0) : channel
            WHEN X"9" =>
              request_reg(conv_integer(DATAIN(1 DOWNTO 0))) <= DATAIN(2);

            -- ---------------- 0xA Single mask bit ---------------------
            --   DATAIN(2)   : 1 = mask, 0 = unmask
            --   DATAIN(1:0) : channel
            WHEN X"A" =>
              mask_reg(conv_integer(DATAIN(1 DOWNTO 0))) <= DATAIN(2);

            -- ---------------- 0xB Mode register -----------------------
            WHEN X"B" =>
              mode_reg(conv_integer(DATAIN(1 DOWNTO 0))) <= DATAIN;

            -- ---------------- 0xC Clear byte-pointer FF --------------
            WHEN X"C" =>
              bp_ff <= '0';

            -- ---------------- 0xD Master clear -----------------------
            WHEN X"D" =>
              command_reg <= (OTHERS => '0');
              request_reg <= (OTHERS => '0');
              temp_reg    <= (OTHERS => '0');
              bp_ff       <= '0';
              mask_reg    <= (OTHERS => '1');

            -- ---------------- 0xE Clear mask register ----------------
            WHEN X"E" =>
              mask_reg <= (OTHERS => '0');

            -- ---------------- 0xF Write all mask bits ----------------
            WHEN X"F" =>
              mask_reg <= DATAIN(3 DOWNTO 0);

            WHEN OTHERS => NULL;
          END CASE;
        END IF;

        -- =============================================================
        -- Reads of address/count registers toggle the byte-pointer FF
        -- (latched on rising edge of /IOR).  Reads of any other
        -- register do not touch it.
        -- =============================================================
        IF (io_rd_prev = '0' AND IO_RD = '1' AND cs = '1') THEN
          CASE IO_ADDR(3 DOWNTO 0) IS
            WHEN X"0" | X"1" | X"2" | X"3"
               | X"4" | X"5" | X"6" | X"7" =>
              bp_ff <= NOT bp_ff;
            WHEN OTHERS => NULL;
          END CASE;
        END IF;

      END IF;
    END IF;
  END PROCESS;

END;