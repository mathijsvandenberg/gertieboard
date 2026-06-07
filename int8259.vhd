--------------------------------------------------------------------------------
-- int8259.vhd  --  8259A Programmable Interrupt Controller
--
-- Single-master configuration as used in the IBM PC/XT.  Implements the
-- parts DOS and the BIOS actually exercise:
--
--   * Full initialization sequence ICW1 -> ICW2 -> [ICW3] -> [ICW4]
--   * Programmable vector base (ICW2; XT BIOS programs 0x08)
--   * IRR / ISR / IMR with fully-nested priority resolution (IR0 highest)
--   * Edge- or level-triggered request capture (LTIM from ICW1)
--   * Two-pulse 8086/8088-mode interrupt-acknowledge with vector on pulse 2
--   * OCW1 mask register at port 0x21 (1 = masked, correct polarity)
--   * OCW2 non-specific and specific EOI at port 0x20
--   * OCW3 read-register select (read IRR or ISR back from port 0x20)
--   * Auto-EOI (ICW4 bit 1) if programmed
--   * Spurious IR7 on acknowledge with no pending request
--
-- Ports (A0 = ADDR(0)):
--   0x20 (A0=0): W = ICW1 / OCW2 / OCW3,  R = IRR or ISR
--   0x21 (A0=1): W = ICW2 / ICW3 / ICW4 / OCW1(mask),  R = IMR
--
-- Cascade (slave) operation is not implemented - the XT has a single PIC.
--
-- Originally derived from the Next186 project PIC by Nicolae Dumitrache;
-- substantially rewritten for full ICW/OCW and ISR support.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY int8259 IS
  PORT(
        CLK     : IN  std_logic;
        RESET   : IN  std_logic;
        DATA    : IN  std_logic_vector(7 DOWNTO 0);   -- CPU write data
        ADDR    : IN  std_logic_vector(15 DOWNTO 0);  -- I/O address
        RD      : IN  std_logic;                      -- active LOW (I/O read)
        WR      : IN  std_logic;                      -- active LOW (I/O write)
        INTA    : IN  std_logic;                      -- active LOW interrupt ack
		  IRQ0    : IN  std_logic;
		  IRQ1    : IN  std_logic;
        IRQ2    : IN  std_logic;
        IRQ6    : IN  std_logic;		  
        DATAOUT : OUT std_logic_vector(7 DOWNTO 0);   -- 'Z' when not driving
        INT     : OUT std_logic);                     -- to CPU INTR (active HIGH)
END int8259;


ARCHITECTURE behavior OF int8259 IS

  -- The IRQ bus
  SIGNAL IRQ : std_logic_vector(7 DOWNTO 0);
  
  -- Core registers
  SIGNAL IRR : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL ISR : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL IMR : std_logic_vector(7 DOWNTO 0) := (OTHERS => '1');  -- masked at power-up

  SIGNAL vector_base : std_logic_vector(7 DOWNTO 0) := x"08";    -- ICW2

  -- Mode flags
  SIGNAL ltim     : std_logic := '0';   -- ICW1 bit3: 1 = level, 0 = edge
  SIGNAL need_icw4: std_logic := '0';   -- ICW1 bit0: ICW4 will follow
  SIGNAL single   : std_logic := '1';   -- ICW1 bit1: 1 = single (no ICW3)
  SIGNAL auto_eoi : std_logic := '0';   -- ICW4 bit1: auto end-of-interrupt
  SIGNAL read_isr : std_logic := '0';   -- OCW3: 0 = read IRR, 1 = read ISR

  -- Initialization sequence state
  TYPE init_state_t IS (RUN, WANT_ICW2, WANT_ICW3, WANT_ICW4);
  SIGNAL istate : init_state_t := RUN;

  -- Interrupt-acknowledge sequence state
  TYPE inta_state_t IS (IDLE, P1, GAP, P2);
  SIGNAL astate    : inta_state_t := IDLE;
  SIGNAL ack_level : integer RANGE 0 TO 7 := 0;

  -- Edge-detect histories
  SIGNAL irq_prev  : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL wr_prev   : std_logic := '1';
  SIGNAL inta_prev : std_logic := '1';

  -- Decode
  SIGNAL cs : std_logic;
  SIGNAL a0 : std_logic;

  -- Priority resolver outputs (combinational)
  SIGNAL sel_level : integer RANGE 0 TO 7;
  SIGNAL sel_valid : std_logic;

  -- Registered interrupt request to CPU
  SIGNAL int_reg : std_logic := '0';

  -- Acknowledge vector
  SIGNAL vector : std_logic_vector(7 DOWNTO 0);

BEGIN

  IRQ(0) <= IRQ0;
  IRQ(1) <= IRQ1;
  IRQ(2) <= IRQ2;
  IRQ(3) <= '0';
  IRQ(4) <= '0';
  IRQ(5) <= '0';
  IRQ(6) <= IRQ6;
  IRQ(7) <= '0';	
  cs <= '1' WHEN ADDR(15 DOWNTO 1) = "000000000010000" ELSE '0';   -- 0x20 / 0x21
  a0 <= ADDR(0);

  ------------------------------------------------------------------------
  -- Priority resolver (fully nested).  An IRR bit is eligible if it is
  -- unmasked and no equal-or-higher-priority ISR bit is set.  IR0 is the
  -- highest priority, IR7 the lowest.
  ------------------------------------------------------------------------
  resolve : PROCESS (IRR, IMR, ISR)
    VARIABLE pend    : std_logic_vector(7 DOWNTO 0);
    VARIABLE blocked : std_logic;
    VARIABLE got     : std_logic;
    VARIABLE lvl     : integer RANGE 0 TO 7;
  BEGIN
    pend    := IRR AND NOT IMR;
    blocked := '0';
    got     := '0';
    lvl     := 0;
    FOR i IN 0 TO 7 LOOP
      IF ISR(i) = '1' THEN
        blocked := '1';           -- this level and all lower are blocked
      END IF;
      IF got = '0' AND blocked = '0' AND pend(i) = '1' THEN
        got := '1';
        lvl := i;
      END IF;
    END LOOP;
    sel_valid <= got;
    sel_level <= lvl;
  END PROCESS;

  vector <= vector_base(7 DOWNTO 3) & conv_std_logic_vector(ack_level, 3);

  ------------------------------------------------------------------------
  -- Data-bus output:
  --   2nd INTA pulse -> vector;  read 0x20 -> IRR/ISR;  read 0x21 -> IMR
  ------------------------------------------------------------------------
  DATAOUT <= vector WHEN (astate = P2) ELSE
             ISR    WHEN (cs = '1' AND RD = '0' AND a0 = '0' AND read_isr = '1') ELSE
             IRR    WHEN (cs = '1' AND RD = '0' AND a0 = '0' AND read_isr = '0') ELSE
             IMR    WHEN (cs = '1' AND RD = '0' AND a0 = '1') ELSE
             "ZZZZZZZZ";

  INT <= int_reg;

  ------------------------------------------------------------------------
  -- Main synchronous logic
  ------------------------------------------------------------------------
  main : PROCESS (CLK)
    VARIABLE eoi_done : boolean;
  BEGIN
    IF rising_edge(CLK) THEN
      IF RESET = '1' THEN
        IRR <= (OTHERS => '0');
        ISR <= (OTHERS => '0');
        IMR <= (OTHERS => '1');
        vector_base <= x"08";
        ltim <= '0'; need_icw4 <= '0'; single <= '1'; auto_eoi <= '0';
        read_isr <= '0';
        istate <= RUN;
        astate <= IDLE;
        ack_level <= 0;
        irq_prev  <= (OTHERS => '0');
        wr_prev   <= '1';
        inta_prev <= '1';
        int_reg   <= '0';

      ELSE
        -- Edge-detect histories
        irq_prev  <= IRQ;
        wr_prev   <= WR;
        inta_prev <= INTA;

        -- Registered interrupt line to CPU
        int_reg <= sel_valid;

        -- --------------- Capture interrupt requests -----------------
        FOR i IN 0 TO 7 LOOP
          IF ltim = '1' THEN
            -- Level triggered: request present while input is high
            IF IRQ(i) = '1' THEN
              IRR(i) <= '1';
            END IF;
          ELSE
            -- Edge triggered: latch on the rising edge
            IF IRQ(i) = '1' AND irq_prev(i) = '0' THEN
              IRR(i) <= '1';
            END IF;
          END IF;
        END LOOP;

        -- --------------- Register writes (rising edge of /WR) -------
        IF (wr_prev = '0' AND WR = '1' AND cs = '1') THEN
          IF a0 = '0' THEN
            ------------------------------------------------ port 0x20
            IF DATA(4) = '1' THEN
              -- ICW1: start initialization
              need_icw4 <= DATA(0);
              single    <= DATA(1);
              ltim      <= DATA(3);
              IMR       <= (OTHERS => '0');
              ISR       <= (OTHERS => '0');
              IRR       <= (OTHERS => '0');
              read_isr  <= '0';
              istate    <= WANT_ICW2;

            ELSIF DATA(3) = '0' THEN
              -- OCW2 (D4 D3 = 0 0): end-of-interrupt / rotate
              CASE DATA(7 DOWNTO 5) IS
                WHEN "001" =>          -- non-specific EOI
                  eoi_done := false;
                  FOR i IN 0 TO 7 LOOP
                    IF (NOT eoi_done) AND ISR(i) = '1' THEN
                      ISR(i) <= '0';
                      eoi_done := true;
                    END IF;
                  END LOOP;
                WHEN "011" =>          -- specific EOI
                  ISR(conv_integer(DATA(2 DOWNTO 0))) <= '0';
                WHEN OTHERS =>
                  NULL;                -- rotate modes unused on XT
              END CASE;

            ELSE
              -- OCW3 (D4 D3 = 0 1): read-register select
              IF DATA(1) = '1' THEN
                read_isr <= DATA(0);   -- RIS: 1 = ISR, 0 = IRR
              END IF;
            END IF;

          ELSE
            ------------------------------------------------ port 0x21
            CASE istate IS
              WHEN WANT_ICW2 =>
                vector_base <= DATA;
                IF single = '0' THEN
                  istate <= WANT_ICW3;
                ELSIF need_icw4 = '1' THEN
                  istate <= WANT_ICW4;
                ELSE
                  istate <= RUN;
                END IF;
              WHEN WANT_ICW3 =>
                -- cascade map: ignored in single-master XT
                IF need_icw4 = '1' THEN
                  istate <= WANT_ICW4;
                ELSE
                  istate <= RUN;
                END IF;
              WHEN WANT_ICW4 =>
                auto_eoi <= DATA(1);
                istate   <= RUN;
              WHEN OTHERS =>
                -- OCW1: interrupt mask (1 = masked)
                IMR <= DATA;
            END CASE;
          END IF;
        END IF;

        -- --------------- Interrupt acknowledge sequence -------------
        CASE astate IS
          WHEN IDLE =>
            IF (inta_prev = '1' AND INTA = '0') THEN
              -- First INTA pulse: freeze priority, set ISR, clear IRR.
              IF sel_valid = '1' THEN
                ack_level      <= sel_level;
                ISR(sel_level) <= '1';
                IRR(sel_level) <= '0';
              ELSE
                ack_level <= 7;            -- spurious: IR7 vector, no ISR set
              END IF;
              astate <= P1;
            END IF;

          WHEN P1 =>
            IF (inta_prev = '0' AND INTA = '1') THEN
              astate <= GAP;               -- first pulse ended
            END IF;

          WHEN GAP =>
            IF (inta_prev = '1' AND INTA = '0') THEN
              astate <= P2;                -- second pulse begins (vector driven)
            END IF;

          WHEN P2 =>
            IF (inta_prev = '0' AND INTA = '1') THEN
              IF auto_eoi = '1' THEN
                ISR(ack_level) <= '0';     -- auto end-of-interrupt
              END IF;
              astate <= IDLE;
            END IF;
        END CASE;

      END IF;
    END IF;
  END PROCESS;

END;