--------------------------------------------------------------------------------
-- dma8237.vhd  --  8237A DMA Controller, register model + bus-master engine
--
-- The complete programmer's-view register set is unchanged from the original
-- stub (address/count pairs with byte-pointer FF, command/status/request/mode/
-- mask, master clear, etc.).  Added on top is a real single-transfer bus master
-- so the floppy controller can move bytes into/out of PSRAM by itself:
--
--   DREQ(n) (or a software request) raises HRQ -> V20 HOLD.  When the V20 grants
--   the bus (HLDA), the engine drives DMA_ADDR + DACK(n) and the memory strobe
--   for one byte, waits for RAM_READY, advances the address, decrements the
--   count, and releases HRQ (single mode).  TC is asserted on the final byte.
--
--   Data does NOT pass through this module: the byte moves FDC<->PSRAM through
--   busdecode's HLDA mux.  This engine only sequences the transfer.
--
--   Transfer type from mode_reg(ch)(3:2):  "01" = write-to-memory (floppy READ)
--   -> IOR+MEMW ; otherwise read-from-memory (floppy WRITE) -> MEMR+IOW.
--   Direction from mode_reg(ch)(5) (0=inc), autoinit from mode_reg(ch)(4).
--
-- DREQ/DACK/TC are active HIGH here (both ends of the handshake are ours).
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
        DATAOUT     : INOUT std_logic_vector(7 DOWNTO 0);    -- 'Z' when not addressed

        -- DMA bus-master interface (single floppy channel = ch2)
        -- One line per channel now, rather than a single pair hardwired to the
        -- floppy's ch2. The register model always modelled four channels; only
        -- the hardware handshake was singular, so adding a second device meant
        -- widening this rather than inventing a parallel path beside it.
        --   ch1 = Sound Blaster DSP    ch2 = floppy
        DREQ        : IN    std_logic_vector(3 DOWNTO 0);    -- requests (active high)
        DACK        : OUT   std_logic_vector(3 DOWNTO 0);    -- acks     (active high)
        HRQ         : OUT   std_logic;                       -- -> V20 HOLD
        HLDA        : IN    std_logic;                       -- <- V20 HLDA
        DMA_ADDR    : OUT   std_logic_vector(15 DOWNTO 0);   -- -> busdecode
        DMA_MEMR    : OUT   std_logic;                       -- active LOW -> busdecode
        DMA_MEMW    : OUT   std_logic;                       -- active LOW -> busdecode
        DMA_IOR     : OUT   std_logic;                       -- active LOW (optional)
        DMA_IOW     : OUT   std_logic;                       -- active LOW (optional)
        TC          : OUT   std_logic;                       -- terminal count -> FDC
        RAM_READY   : IN    std_logic);                      -- <- ram1 READY
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

  -- Status: upper nibble = software-request bits, lower nibble = TC latches.
  SIGNAL status_reg : std_logic_vector(7 DOWNTO 0);
  SIGNAL tc_status  : std_logic_vector(3 DOWNTO 0) := (OTHERS => '0');

  -- Internal byte-pointer flip-flop (for the 16-bit register pairs)
  SIGNAL bp_ff : std_logic := '0';   -- 0 -> next access is LSB, 1 -> MSB

  -- Edge detection on /IOR and /IOW
  SIGNAL io_rd_prev : std_logic := '1';
  SIGNAL io_wr_prev : std_logic := '1';

  -- Combinational read mux
  SIGNAL read_data : std_logic_vector(7 DOWNTO 0);

  -- ---------------- Bus-master engine -------------------------------------
  TYPE dst_t IS (D_IDLE, D_HOLD, D_MEM, D_FIN);
  SIGNAL dst     : dst_t := D_IDLE;
  SIGNAL ach     : integer RANGE 0 TO 3 := 0;
  SIGNAL last_b  : std_logic := '0';
  SIGNAL req_eff : std_logic_vector(3 DOWNTO 0);
  SIGNAL hw_dreq : std_logic_vector(3 DOWNTO 0);   -- per-channel hardware requests

BEGIN

  -- ---------------- Address decode ----------------------------------------
  cs <= '1' WHEN IO_ADDR(15 DOWNTO 4) = X"000" ELSE '0';

  -- ---------------- Status register (combinational) -----------------------
  status_reg <= request_reg & tc_status;

  -- effective requests: hardware DREQ (ch2 only) or software request, unmasked
  hw_dreq <= DREQ;
  req_eff <= (hw_dreq OR request_reg) AND NOT mask_reg;

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

  -- ---------------- Register writes + BP toggle + DMA engine --------------
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
        tc_status   <= (OTHERS => '0');
        bp_ff       <= '0';
        io_rd_prev  <= '1';
        io_wr_prev  <= '1';
        dst         <= D_IDLE;
        HRQ         <= '0';
        DACK        <= (OTHERS => '0');
        TC          <= '0';
        DMA_MEMR    <= '1';
        DMA_MEMW    <= '1';
        DMA_IOR     <= '1';
        DMA_IOW     <= '1';
        DMA_ADDR    <= (OTHERS => '0');
        last_b      <= '0';
        ach         <= 0;

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
            WHEN X"9" =>
              request_reg(conv_integer(DATAIN(1 DOWNTO 0))) <= DATAIN(2);

            -- ---------------- 0xA Single mask bit ---------------------
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
              tc_status   <= (OTHERS => '0');

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
        -- Reads of address/count registers toggle the byte-pointer FF.
        -- Reading the status register (0x8) clears the TC latches.
        -- =============================================================
        IF (io_rd_prev = '0' AND IO_RD = '1' AND cs = '1') THEN
          CASE IO_ADDR(3 DOWNTO 0) IS
            WHEN X"0" | X"1" | X"2" | X"3"
               | X"4" | X"5" | X"6" | X"7" =>
              bp_ff <= NOT bp_ff;
            WHEN X"8" =>
              tc_status <= (OTHERS => '0');
            WHEN OTHERS => NULL;
          END CASE;
        END IF;

        -- =============================================================
        -- Bus-master engine (single transfer mode). CPU register writes
        -- above and this engine never run in the same cycle: while a
        -- transfer is in progress the V20 is held off the bus.
        -- =============================================================
        CASE dst IS

          WHEN D_IDLE =>
            HRQ      <= '0';
            DACK     <= (OTHERS => '0');
            TC       <= '0';
            DMA_MEMR <= '1'; DMA_MEMW <= '1';
            DMA_IOR  <= '1'; DMA_IOW  <= '1';
            -- command_reg(2) = 1 disables the whole controller
            IF (command_reg(2) = '0' AND req_eff /= "0000") THEN
              IF    req_eff(0) = '1' THEN ach <= 0;
              ELSIF req_eff(1) = '1' THEN ach <= 1;
              ELSIF req_eff(2) = '1' THEN ach <= 2;
              ELSE                        ach <= 3; END IF;
              HRQ <= '1';
              dst <= D_HOLD;
            END IF;

          WHEN D_HOLD =>
            HRQ <= '1';
            IF HLDA = '1' THEN
              DMA_ADDR  <= cur_addr(ach);
              DACK(ach) <= '1';                      -- whichever channel won
              IF cur_cnt(ach) = x"0000" THEN last_b <= '1'; ELSE last_b <= '0'; END IF;
              IF mode_reg(ach)(3 DOWNTO 2) = "01" THEN   -- device -> memory (floppy read)
                DMA_IOR <= '0'; DMA_MEMW <= '0';
              ELSE                                        -- memory -> device (floppy write)
                DMA_MEMR <= '0'; DMA_IOW <= '0';
              END IF;
              dst <= D_MEM;
            END IF;

          WHEN D_MEM =>
            IF last_b = '1' THEN TC <= '1'; END IF;   -- assert with DACK on final byte
            IF RAM_READY = '1' THEN                   -- memory cycle complete
              DMA_MEMR <= '1'; DMA_MEMW <= '1';
              DMA_IOR  <= '1'; DMA_IOW  <= '1';
              -- advance address
              IF mode_reg(ach)(5) = '0' THEN
                cur_addr(ach) <= cur_addr(ach) + 1;
              ELSE
                cur_addr(ach) <= cur_addr(ach) - 1;
              END IF;
              -- decrement / terminal count
              IF cur_cnt(ach) = x"0000" THEN
                tc_status(ach)   <= '1';
                request_reg(ach) <= '0';
                IF mode_reg(ach)(4) = '1' THEN          -- autoinit: reload
                  cur_addr(ach) <= base_addr(ach);
                  cur_cnt(ach)  <= base_cnt(ach);
                ELSE
                  mask_reg(ach) <= '1';                 -- else self-mask
                END IF;
              ELSE
                cur_cnt(ach) <= cur_cnt(ach) - 1;
              END IF;
              dst <= D_FIN;
            END IF;

          WHEN D_FIN =>
            DACK <= (OTHERS => '0');
            HRQ  <= '0';            -- release the bus (single mode); TC held until idle
            dst  <= D_IDLE;

        END CASE;

      END IF;
    END IF;
  END PROCESS;

END;