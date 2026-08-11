--------------------------------------------------------------------------------
-- sdram_io.vhd  --  an I/O window onto the SDRAM, so it can be proved
--
-- The SDRAM is going to hold the EGA planes, and a memory fault there would
-- present as a corrupt picture -- which is indistinguishable, from the outside,
-- from a bug in the addressing, the scanline buffer, the arbitration, or the
-- write path. Every one of those was wrong at least once while EGA was being
-- built on M9K.
--
-- So the memory gets proved on its own first, through ports, by a DOS program
-- that can write a word and read it back and say which bit disagreed. Nothing
-- moves into SDRAM until SDRAMTST passes.
--
--   0x300 W    address bits  7:0        (WORD address, not byte)
--   0x301 W    address bits 15:8
--   0x302 W    address bits 23:16
--   0x303 W/R  data low byte
--   0x304 W/R  data high byte
--   0x306 R    CRTC start address, low byte   (R13 / 0x0D)
--   0x307 R    CRTC start address, high byte  (R12 / 0x0C)
--   0x308 R    CRTC offset -- the logical line width in WORDS (R19 / 0x13)
--   0x305 W    1 = read, 2 = write
--         R    bit 0 = busy, bit 1 = init done, bit 2 = always 1 (see below),
--              bit 3 = RESET as the controller sees it, bits 7:4 = state
--
-- ---------------------------------------------------------------------------
-- WHY 0x300 AND NOT 0xE8
--
-- 0xE8..0xEF is the USB host controller's register block. This module was
-- written at 0xE8 first, and both modules then drove 0xED on a read: the bus
-- resolved to X and read back as 00, which looks exactly like a controller
-- stuck in its reset state. Worse, every write to 0xE8..0xED also landed in
-- usb_host's device address, endpoint and transfer length.
--
-- 0x300..0x31F is the prototype-card range, which is free by convention on a
-- PC and decoded by nothing else here.
--
-- Bit 2 of the status byte is a hardwired 1 for the same reason: an all-zero
-- read is ambiguous between "the controller is in state 0" and "nobody
-- answered". With this bit set, 0x00 can only mean the second.
--
-- Write the address, write the data, write 2, poll until not busy. Read is the
-- same with a 1, and the word appears at 0xEB/0xEC.
--
-- ---------------------------------------------------------------------------
-- TWO CLOCKS
--
-- The registers live on the I/O bus clock c0, because that is the only clock
-- that can see an I/O cycle. The controller runs on c3 at 50 MHz, because that
-- is the SDRAM's clock. So GO crosses c0 -> c3 as a TOGGLE through two flops
-- and an edge detect, and DONE crosses back the same way.
--
-- The address and data do NOT need synchronising: they are written by separate
-- I/O cycles long before GO toggles, and are static by then. Synchronising a
-- bus that is already stable buys nothing and costs 40 flops.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.ALL;
USE  IEEE.NUMERIC_STD.ALL;

ENTITY sdram_io IS
  PORT(
        CLK_IO    : IN    std_logic;                      -- c0, the I/O bus
        CLK_MEM   : IN    std_logic;                      -- c3, the SDRAM
        RESET     : IN    std_logic;

        IOADDR    : IN    std_logic_vector(15 DOWNTO 0);
        DATA      : IN    std_logic_vector(7 DOWNTO 0);
        IORD      : IN    std_logic;                      -- active LOW
        IOWR      : IN    std_logic;                      -- active LOW
        DATAOUT   : INOUT std_logic_vector(7 DOWNTO 0);

        -- to sdram_ctrl
        REQ       : OUT   std_logic;
        WE        : OUT   std_logic;
        ADDR      : OUT   std_logic_vector(23 DOWNTO 0);
        DIN       : OUT   std_logic_vector(15 DOWNTO 0);
        BE        : OUT   std_logic_vector(1 DOWNTO 0);
        DOUT      : IN    std_logic_vector(15 DOWNTO 0);
        ACK       : IN    std_logic;
        INIT_DONE : IN    std_logic;
        DBG_STATE : IN    std_logic_vector(3 DOWNTO 0);
        -- Read-only windows onto what software has programmed into the CRTC.
        -- Keen 4 sets these directly through 0x3D4/0x3D5 and they read back as
        -- zero there, because a 6845's registers are write-only and that
        -- asymmetry is what card detection looks for. So they are exposed
        -- here instead, where DEBUG can simply IN them.
        CRTC_START: IN    std_logic_vector(15 DOWNTO 0);
        CRTC_OFFS : IN    std_logic_vector(7 DOWNTO 0));
END sdram_io;

ARCHITECTURE behavior OF sdram_io IS

  SIGNAL a_reg  : std_logic_vector(23 DOWNTO 0) := (OTHERS => '0');
  SIGNAL d_reg  : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL q_reg  : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL we_reg : std_logic := '0';

  SIGNAL go_tog : std_logic := '0';                       -- c0 side
  SIGNAL dn_tog : std_logic := '0';                       -- c3 side

  SIGNAL go_s   : std_logic_vector(2 DOWNTO 0) := "000";  -- into c3
  SIGNAL dn_s   : std_logic_vector(2 DOWNTO 0) := "000";  -- back into c0

  SIGNAL busy_i : std_logic := '0';                       -- c0 view
  SIGNAL req_i  : std_logic := '0';

  SIGNAL wr_act, wr_prev : std_logic := '0';

  SIGNAL rdval  : std_logic_vector(7 DOWNTO 0);
  SIGNAL sel_rd : std_logic;

BEGIN

  wr_act <= NOT IOWR;

  ADDR <= a_reg;
  DIN  <= d_reg;
  BE   <= "11";                    -- always a whole word here
  REQ  <= req_i;
  WE   <= we_reg;

  ----------------------------------------------------------------------------
  -- Read path
  ----------------------------------------------------------------------------
  rdval <= q_reg(7 DOWNTO 0)               WHEN IOADDR = x"0303" ELSE
           q_reg(15 DOWNTO 8)              WHEN IOADDR = x"0304" ELSE
           DBG_STATE & RESET & '1' & INIT_DONE & busy_i
                                           WHEN IOADDR = x"0305" ELSE
           CRTC_START(7 DOWNTO 0)          WHEN IOADDR = x"0306" ELSE
           CRTC_START(15 DOWNTO 8)         WHEN IOADDR = x"0307" ELSE
           CRTC_OFFS                       WHEN IOADDR = x"0308" ELSE
           x"00";

  sel_rd  <= '1' WHEN (IORD = '0' AND (IOADDR = x"0303" OR IOADDR = x"0304" OR
                                       IOADDR = x"0305" OR IOADDR = x"0306" OR
                                       IOADDR = x"0307" OR IOADDR = x"0308"))
             ELSE '0';
  DATAOUT <= rdval WHEN sel_rd = '1' ELSE "ZZZZZZZZ";

  ----------------------------------------------------------------------------
  -- c0 side: the registers, and the GO toggle
  ----------------------------------------------------------------------------
  PROCESS (CLK_IO)
    VARIABLE wr_rise : std_logic;
  BEGIN
    IF rising_edge(CLK_IO) THEN
      wr_prev <= wr_act;
      wr_rise := wr_act AND NOT wr_prev;

      dn_s <= dn_s(1 DOWNTO 0) & dn_tog;
      -- Either edge of the done toggle clears busy: a toggle carries the event
      -- without needing the two sides to agree on a level.
      IF dn_s(2) /= dn_s(1) THEN
        busy_i <= '0';
      END IF;

      IF RESET = '1' THEN
        busy_i <= '0';
      ELSIF wr_rise = '1' THEN
        CASE IOADDR IS
          WHEN x"0300" => a_reg(7 DOWNTO 0)   <= DATA;
          WHEN x"0301" => a_reg(15 DOWNTO 8)  <= DATA;
          WHEN x"0302" => a_reg(23 DOWNTO 16) <= DATA;
          WHEN x"0303" => d_reg(7 DOWNTO 0)   <= DATA;
          WHEN x"0304" => d_reg(15 DOWNTO 8)  <= DATA;
          WHEN x"0305" =>
            IF DATA(1 DOWNTO 0) /= "00" THEN
              we_reg <= DATA(1);          -- 1 = read, 2 = write
              busy_i <= '1';
              go_tog <= NOT go_tog;
            END IF;
          WHEN OTHERS => NULL;
        END CASE;
      END IF;
    END IF;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- c3 side: turn a GO edge into one REQ, and ACK back into a DONE edge
  ----------------------------------------------------------------------------
  PROCESS (CLK_MEM)
  BEGIN
    IF rising_edge(CLK_MEM) THEN
      go_s <= go_s(1 DOWNTO 0) & go_tog;

      IF RESET = '1' THEN
        req_i <= '0';
      ELSE
        IF go_s(2) /= go_s(1) THEN        -- a new command arrived
          req_i <= '1';
        END IF;
        IF ACK = '1' THEN
          req_i  <= '0';                  -- REQ is held until ACK, as required
          q_reg  <= DOUT;
          dn_tog <= NOT dn_tog;
        END IF;
      END IF;
    END IF;
  END PROCESS;

END behavior;
