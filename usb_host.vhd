--------------------------------------------------------------------------------
-- usb_host.vhd  --  USB 1.1 full-speed host controller (soft SIE)
--
-- Both USB ports on the top board are raw D+/D- straight to FPGA pins, with the
-- 15K pulldowns a host is supposed to have and no host-controller chip in
-- between. So the serial interface engine lives here, in fabric.
--
-- ONE INSTANCE DRIVES ONE PORT. It used to drive both, muxed by a port-select
-- bit in CTRL, which meant the fixed disk on USB0 and anything on USB1 shared a
-- single engine: a mouse poll landing between the CBW and the CSW of a disk
-- transfer would repoint the pins mid-transaction. The top level now
-- instantiates this entity twice, once per port, at two I/O windows chosen by
-- the IO_BASE generic. The cost is ~900 LEs on a part with room to spare; what
-- it buys is that the two ports cannot interfere at all, and the disk path is
-- unchanged rather than merely arbitrated.
--
-- WHAT IS IN HARDWARE AND WHAT IS NOT
-- -----------------------------------
-- Hardware does only what software cannot: bit-level timing at 12 Mbps. That is
-- NRZI, bit stuffing, the SYNC pattern, EOP, CRC5/CRC16, the 4x oversampling
-- receiver, response timeout, and the 1 ms SOF that stops devices suspending.
--
-- Everything above a single transaction -- enumeration, descriptors, addresses,
-- endpoint toggles, mass-storage transport -- is left to software, where it can
-- be changed with a rebuild instead of a reflash. The CPU sets up one
-- transaction, starts it, and reads the result. See tools/usbtest.asm.
--
-- I/O MAP  (8 registers at IO_BASE, which must be 8-byte aligned)
--   USB0 / fixed disk : 0xE8..0xEF, next to the other custom registers
--   USB1 / everything else : 0xA8..0xAF
-- The offsets below are named relative to IO_BASE; the 0xE8.. addresses are
-- spelled out because every existing tool and the BIOS use them literally.
-- ---------------------------------------------------------------------
--   0xE8  W  CMD     [2:0] operation   0 = NOP
--                                      1 = SETUP  token + DATA0 + handshake
--                                      2 = IN     token + rx data + ACK
--                                      3 = OUT    token + DATAx + handshake
--                                      5 = SOF    send one frame marker
--                    [3]   DATA1 -- send DATA1 instead of DATA0 (OUT)
--                    [7]   GO    -- writing this bit starts the transaction
--         R  STATUS  [0] BUSY      transaction in progress
--                    [1] ACK       device acknowledged
--                    [2] NAK       device not ready, retry
--                    [3] STALL     endpoint halted
--                    [4] TIMEOUT   no response within 18 bit times
--                    [5] ERROR     CRC, bit-stuff or PID check failed
--                    [6] RXDATA1   the received data packet was DATA1
--                    [7] RXVALID   a data packet was received
--
--   0xE9  W  DEVADDR [6:0] device address (0 until SET_ADDRESS)
--   0xEA  W  ENDP    [3:0] endpoint number
--         R  RXPID   the PID byte of the last packet received, raw. Worth more
--                    than the status bits when something is wrong: it says what
--                    actually came back rather than how it was classified.
--   0xEB  W  TXLEN   bytes to send from the TX buffer (0..64)
--         R  RXLEN   bytes received into the RX buffer
--   0xEC  W  DATA    write a byte to the TX buffer, pointer auto-increments
--         R  DATA    read a byte from the RX buffer, pointer auto-increments
--   0xED  W  PTR     set both buffer pointers (normally 0)
--         R  PTR     current TX pointer
--   0xEE  W  CTRL    [0] RESERVED -- was port select while one engine drove both
--                        ports. Ignored now; each instance has its own pins.
--                        Software that writes 0 here is unaffected, which is
--                        every caller that only ever used USB0.
--                    [1] BUSRESET -- drive SE0 while set (software times 10 ms)
--                    [2] SOFEN    -- run the 1 ms SOF generator
--         R  LINE    [0] D+ level        [1] D- level
--                    [2] FS device seen  (idle J:  D+ high, D- low)
--                    [3] LS device seen  (idle K:  D- high, D+ low)
--                    [4] SOF running     [5] 48 MHz PLL locked
--   0xEF  R  FRAME   low 8 bits of the frame counter -- if this changes, the
--                    SOF generator is alive
--
-- BUS RESET is deliberately software-timed. It has to be held at least 10 ms,
-- which is an eternity in fabric and trivial in a DOS program.
--
-- SPEED: full speed (12 Mbps) only. Mass storage is never low speed, and the
-- point of this is eventually to boot from a stick. A low-speed device will be
-- reported on bit 3 of LINE and otherwise ignored.
--
-- ELECTRICAL CAVEAT: there are no series resistors on D+/D-, so the lines are
-- driven straight from 3.3 V LVTTL pins with no source termination. That is out
-- of spec -- USB wants ~22-33 ohm in series -- and it is the first thing to
-- suspect if packets get through at all but with intermittent CRC errors,
-- especially on a long cable. Nothing here can compensate for it.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;

ENTITY usb_host IS
  GENERIC (
    -- Base of this instance's 8-register I/O window. MUST be 8-byte aligned:
    -- the decode compares ADDR(15 DOWNTO 3) and indexes with ADDR(2 DOWNTO 0),
    -- so a misaligned base would silently answer at the wrong eight addresses.
    IO_BASE   : std_logic_vector(15 DOWNTO 0) := x"00E8"
  );
  PORT (
    CLK       : IN    std_logic;                     -- 10 MHz CPU I/O bus (c0)
    CLK48     : IN    std_logic;                     -- 48 MHz USB domain
    LOCKED    : IN    std_logic;                     -- 48 MHz PLL locked
    RESET     : IN    std_logic;                     -- active high
    DATAIN    : IN    std_logic_vector(7 DOWNTO 0);
    ADDR      : IN    std_logic_vector(15 DOWNTO 0);
    RD        : IN    std_logic;                     -- active low
    WR        : IN    std_logic;                     -- active low
    DATAOUT   : INOUT std_logic_vector(7 DOWNTO 0);
    USB_DP    : INOUT std_logic;
    USB_DM    : INOUT std_logic
  );
END usb_host;

ARCHITECTURE rtl OF usb_host IS

  -- ---- PIDs (low nibble; the high nibble is its complement) ----------------
  CONSTANT PID_OUT   : std_logic_vector(7 DOWNTO 0) := x"E1";
  CONSTANT PID_IN    : std_logic_vector(7 DOWNTO 0) := x"69";
  CONSTANT PID_SOF   : std_logic_vector(7 DOWNTO 0) := x"A5";
  CONSTANT PID_SETUP : std_logic_vector(7 DOWNTO 0) := x"2D";
  CONSTANT PID_DATA0 : std_logic_vector(7 DOWNTO 0) := x"C3";
  CONSTANT PID_DATA1 : std_logic_vector(7 DOWNTO 0) := x"4B";
  CONSTANT PID_ACK   : std_logic_vector(7 DOWNTO 0) := x"D2";
  CONSTANT PID_NAK   : std_logic_vector(7 DOWNTO 0) := x"5A";
  CONSTANT PID_STALL : std_logic_vector(7 DOWNTO 0) := x"1E";

  -- 48 MHz / 12 Mbps = 4 clocks per bit
  CONSTANT BIT_DIV   : integer := 4;
  -- 1 ms of 48 MHz for the SOF generator
  CONSTANT SOF_DIV   : integer := 48000;
  -- Response timeout. This bounds how long the device may take to START
  -- answering -- the FS limit is 7.5 bit times after EOP, so 24 is generous.
  --
  -- It must NOT bound the whole response: rx_done only fires at EOP, so an ACK
  -- (SYNC 8 + PID 8 + EOP 3, plus turnaround) already needs ~27 bit times and an
  -- 8-byte DATA packet needs ~99. An earlier version timed the completion and so
  -- reported TIMEOUT for a device that was answering perfectly.
  CONSTANT RX_TO     : integer := 24 * BIT_DIV;
  -- Backstop once a packet IS arriving: the longest legal one is a 64-byte DATA
  -- (8 + 8 + 512 + 16 + 3 bit times, plus stuffing), so 1024 bit times cannot cut
  -- a real packet short while still stopping a wedged receiver from hanging the
  -- engine. Bound the whole operation, not just each loop -- see docs/gotchas.md.
  CONSTANT RX_GUARD  : integer := 1024 * BIT_DIV;

  -- ---- CPU-side registers (CLK domain) -------------------------------------
  SIGNAL r_cmd      : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL r_devaddr  : std_logic_vector(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL r_endp     : std_logic_vector(3 DOWNTO 0) := (OTHERS => '0');
  SIGNAL r_txlen    : std_logic_vector(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL r_ctrl     : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL tx_ptr     : std_logic_vector(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL rx_ptr     : std_logic_vector(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL go_cpu     : std_logic := '0';             -- toggles to request a run
  -- busdecode's IO_WR/IO_RD are combinational passthroughs of the CPU strobes
  -- (IO_WR <= NOT(NOT WR AND IOM)), so they stay asserted for the whole bus
  -- cycle -- several CLK edges. Every register access must therefore be
  -- taken on an EDGE, exactly as flash.vhd does. Without this the auto-
  -- incrementing data port stored each byte into several slots and advanced the
  -- pointer several times, so an 8-byte SETUP packet went out as garbage and the
  -- device answered STALL. See docs/gotchas.md, "Timing races in I/O sequences".
  SIGNAL wr_prev    : std_logic := '1';
  SIGNAL rd_prev    : std_logic := '1';
  SIGNAL rd_data_c  : std_logic := '0';   -- a read of 0xEC is in progress

  -- ---- I/O window decode ----------------------------------------------------
  -- Split once, here, so no decode site has to know the base address.
  SIGNAL io_hit     : std_logic;                        -- ADDR is in our window
  SIGNAL io_reg     : std_logic_vector(2 DOWNTO 0);     -- which of the eight
  CONSTANT RG_CMD    : std_logic_vector(2 DOWNTO 0) := "000";  -- 0xE8
  CONSTANT RG_DEVA   : std_logic_vector(2 DOWNTO 0) := "001";  -- 0xE9
  CONSTANT RG_ENDP   : std_logic_vector(2 DOWNTO 0) := "010";  -- 0xEA
  CONSTANT RG_LEN    : std_logic_vector(2 DOWNTO 0) := "011";  -- 0xEB
  CONSTANT RG_DATA   : std_logic_vector(2 DOWNTO 0) := "100";  -- 0xEC
  CONSTANT RG_PTR    : std_logic_vector(2 DOWNTO 0) := "101";  -- 0xED
  CONSTANT RG_CTRL   : std_logic_vector(2 DOWNTO 0) := "110";  -- 0xEE
  CONSTANT RG_DIAG   : std_logic_vector(2 DOWNTO 0) := "111";  -- 0xEF

  -- ---- status back from the USB domain -------------------------------------
  SIGNAL st_busy    : std_logic := '0';
  SIGNAL st_ack     : std_logic := '0';
  SIGNAL st_nak     : std_logic := '0';
  SIGNAL st_stall   : std_logic := '0';
  SIGNAL st_to      : std_logic := '0';
  SIGNAL st_err     : std_logic := '0';
  SIGNAL st_rxd1    : std_logic := '0';
  SIGNAL st_rxv     : std_logic := '0';
  SIGNAL rx_len     : std_logic_vector(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL frame_cnt  : std_logic_vector(10 DOWNTO 0) := (OTHERS => '0');

  -- ---- packet buffers: TX written by CPU / read by SIE, RX the other way ----
  TYPE buf_t IS ARRAY(0 TO 63) OF std_logic_vector(7 DOWNTO 0);
  SIGNAL txbuf     : buf_t;
  SIGNAL rxbuf     : buf_t;
  SIGNAL txb_q     : std_logic_vector(7 DOWNTO 0);
  SIGNAL rxb_q     : std_logic_vector(7 DOWNTO 0);
  SIGNAL sie_txadr : std_logic_vector(5 DOWNTO 0) := (OTHERS => '0');
  SIGNAL sie_rxadr : std_logic_vector(5 DOWNTO 0) := (OTHERS => '0');
  SIGNAL sie_rxwe  : std_logic := '0';
  SIGNAL sie_rxd   : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');

  -- ---- clock crossing -------------------------------------------------------
  SIGNAL go_m1, go_m2, go_m3 : std_logic := '0';
  SIGNAL cmd_s      : std_logic_vector(7 DOWNTO 0);
  SIGNAL dev_s      : std_logic_vector(6 DOWNTO 0);
  SIGNAL endp_s     : std_logic_vector(3 DOWNTO 0);
  SIGNAL txlen_s    : std_logic_vector(6 DOWNTO 0);
  SIGNAL ctrl_s     : std_logic_vector(7 DOWNTO 0);
  SIGNAL ctrl_m     : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');

  -- ---- line interface -------------------------------------------------------
  SIGNAL dp_in, dm_in       : std_logic;
  SIGNAL dp_s1, dm_s1       : std_logic := '0';
  SIGNAL dp_r,  dm_r        : std_logic := '0';
  SIGNAL dp_p,  dm_p        : std_logic := '0';   -- previous, for edge detect
  SIGNAL tx_dp, tx_dm, tx_oe: std_logic := '0';

  -- ---- transmitter ----------------------------------------------------------
  TYPE tx_st_t IS (T_IDLE, T_SYNC, T_BYTE, T_CRC, T_TAIL, T_EOP1, T_EOP2,
                   T_EOPJ, T_DONE);
  SIGNAL tx_st      : tx_st_t := T_IDLE;
  SIGNAL tx_ph      : integer RANGE 0 TO BIT_DIV-1 := 0;
  SIGNAL tx_sh      : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL tx_nbit    : integer RANGE 0 TO 8 := 0;
  SIGNAL tx_ones    : integer RANGE 0 TO 7 := 0;
  SIGNAL tx_j       : std_logic := '1';          -- current NRZI level (1 = J)
  SIGNAL tx_stuff   : std_logic := '0';
  SIGNAL tx_cnt     : std_logic_vector(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL tx_total   : std_logic_vector(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL tx_crcen   : std_logic := '0';
  SIGNAL tx_crc16   : std_logic_vector(15 DOWNTO 0) := (OTHERS => '1');
  SIGNAL tx_crcsel  : std_logic := '0';          -- 1 = append CRC16
  SIGNAL tx_src     : std_logic := '0';          -- 0 = literal reg, 1 = buffer
  SIGNAL tx_lit     : std_logic_vector(23 DOWNTO 0) := (OTHERS => '0');
  SIGNAL tx_litn    : integer RANGE 0 TO 3 := 0;

  -- The sequencer describes the packet it wants in these; the transmitter
  -- copies them into its own working registers when it starts. Every signal
  -- above is written ONLY by TXP and every req_* ONLY by SEQ -- VHDL allows a
  -- single driver per signal, and sharing them is what an earlier version did.
  SIGNAL req_lit    : std_logic_vector(23 DOWNTO 0) := (OTHERS => '0');
  SIGNAL req_litn   : integer RANGE 0 TO 3 := 0;
  SIGNAL req_total  : std_logic_vector(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL req_crc16  : std_logic := '0';
  SIGNAL tx_go      : std_logic := '0';
  -- tx_go is a one-cycle pulse from the sequencer. If the transmitter is not in
  -- T_IDLE at that exact cycle the pulse is LOST, and the sequencer then waits
  -- for a tx_done that will never come -- BUSY stays high until the CPU's poll
  -- times out. That is the third single-cycle handshake in this module to bite
  -- (after GO and BUSY-during-SOF), and it accounted for 227 stalls in one
  -- enumeration. Latch it, like everything else here should have been.
  SIGNAL tx_req     : std_logic := '0';
  SIGNAL tx_done    : std_logic := '0';

  -- ---- receiver -------------------------------------------------------------
  TYPE rx_st_t IS (R_IDLE, R_SYNC, R_DATA, R_EOP);
  SIGNAL rx_st      : rx_st_t := R_IDLE;
  SIGNAL rx_ph      : integer RANGE 0 TO BIT_DIV-1 := 0;
  SIGNAL rx_prev    : std_logic := '1';
  SIGNAL rx_ones    : integer RANGE 0 TO 7 := 0;
  SIGNAL rx_sh      : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL rx_nbit    : integer RANGE 0 TO 8 := 0;
  SIGNAL rx_bytes   : std_logic_vector(6 DOWNTO 0) := (OTHERS => '0');
  SIGNAL rx_pid     : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL rx_crc16   : std_logic_vector(15 DOWNTO 0) := (OTHERS => '1');
  SIGNAL rx_active  : std_logic := '0';
  SIGNAL rx_done    : std_logic := '0';
  SIGNAL rx_err     : std_logic := '0';
  SIGNAL rx_arm     : std_logic := '0';
  SIGNAL rx_to_cnt  : integer RANGE 0 TO RX_TO := 0;
  SIGNAL rx_gcnt   : integer RANGE 0 TO RX_GUARD := 0;
  -- Debounced SE0. D+ and D- do not switch at the same instant: on every J<->K
  -- transition there is a window of a few nanoseconds where D+ has already
  -- fallen and D- has not yet risen, and BOTH READ LOW. Treating that as SE0
  -- ends the packet mid-data, truncating it and failing the CRC -- randomly, and
  -- more often the more transitions a packet contains. That is why small control
  -- transfers and large bulk transfers were failing at similar rates.
  --
  -- A real EOP is 2 bit times of SE0 = 8 cycles at 48 MHz. Requiring 3 cycles
  -- (~62 ns) is far longer than any plausible D+/D- skew and far shorter than a
  -- genuine EOP, so it filters the glitch without ever missing a real one.
  SIGNAL se0_cnt   : integer RANGE 0 TO 7 := 0;
  SIGNAL se0_st    : std_logic := '0';

  -- ---- sequencer ------------------------------------------------------------
  TYPE se_t IS (S_IDLE, S_TOKEN, S_TOKW, S_TXDATA, S_TXDW, S_RXWAIT, S_RXEND,
                S_ACK, S_ACKW, S_SOFW, S_FIN);
  SIGNAL se        : se_t := S_IDLE;
  SIGNAL se_op     : std_logic_vector(2 DOWNTO 0) := (OTHERS => '0');
  SIGNAL se_d1     : std_logic := '0';
  SIGNAL sof_cnt   : integer RANGE 0 TO SOF_DIV-1 := 0;
  SIGNAL sof_req   : std_logic := '0';
  -- GO must be LATCHED, not edge-detected in place. "go_m3 /= go_m2" is true
  -- for exactly one 48 MHz cycle as the toggle walks the synchroniser, so a
  -- command issued while the sequencer was busy -- sending a SOF, for instance,
  -- which happens every 1 ms -- was dropped on the floor. BUSY then never rose,
  -- the CPU's poll saw it clear immediately and read the PREVIOUS
  -- transaction's status, so a packet that never went looked like an ACK.
  -- That desynchronises the bulk stream and shows up much later as a CSW
  -- signature error or an endlessly NAKed CBW. sof_req was always a latch;
  -- this makes GO behave the same way.
  SIGNAL go_pend   : std_logic := '0';

  -- ---- diagnostic counters -------------------------------------------------
  -- Read through a window at 0xEF: write an index, read the value. They wrap;
  -- software takes differences. Without these there is no way to tell "the link
  -- is losing packets" from "the driver has a bug", and this stack has produced
  -- both symptoms from four different causes already.
  SIGNAL c_crcerr  : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL c_tmo     : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL c_nak     : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL c_txn     : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL c_stall   : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL c_pktin   : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL c_pktout  : std_logic_vector(15 DOWNTO 0) := (OTHERS => '0');
  SIGNAL diag_sel  : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL diag_q    : std_logic_vector(7 DOWNTO 0);
  -- Where the machine actually is. I have guessed wrong twice about which state
  -- wedges; reading it costs a few LUTs and ends the argument.
  SIGNAL se_code   : std_logic_vector(3 DOWNTO 0);
  SIGNAL tx_code   : std_logic_vector(3 DOWNTO 0);
  SIGNAL rx_code   : std_logic_vector(1 DOWNTO 0);
  SIGNAL turn      : integer RANGE 0 TO 63 := 0;
  -- Backstop for the four states that wait on tx_done. The longest legal packet
  -- is a 64-byte DATA (~600 bit times, 2400 cycles), so 8192 cycles (~170 us)
  -- cannot cut a real transmission short. Bounding the whole operation rather
  -- than trusting every handshake is the lesson from docs/gotchas.md, and it
  -- turns any future missed pulse into a reported error instead of a stall.
  SIGNAL tx_wcnt   : integer RANGE 0 TO 8191 := 0;

  -- CRC5 over the 11-bit token field
  FUNCTION crc5(d : std_logic_vector(10 DOWNTO 0)) RETURN std_logic_vector IS
    VARIABLE c : std_logic_vector(4 DOWNTO 0) := "11111";
    VARIABLE f : std_logic;
  BEGIN
    FOR i IN 0 TO 10 LOOP
      f := d(i) XOR c(4);
      c(4) := c(3);
      c(3) := c(2);
      c(2) := c(1) XOR f;
      c(1) := c(0);
      c(0) := f;
    END LOOP;
    RETURN NOT c;
  END crc5;

BEGIN

  -- ==========================================================================
  --  Pins.  This instance owns one port outright: driven while transmitting,
  --  high-Z otherwise so the pulldowns hold it at SE0.
  -- ==========================================================================
  USB_DP <= tx_dp WHEN tx_oe = '1' ELSE 'Z';
  USB_DM <= tx_dm WHEN tx_oe = '1' ELSE 'Z';

  dp_in <= USB_DP;
  dm_in <= USB_DM;

  io_hit <= '1' WHEN ADDR(15 DOWNTO 3) = IO_BASE(15 DOWNTO 3) ELSE '0';
  io_reg <= ADDR(2 DOWNTO 0);

  se_code <= x"0" WHEN se = S_IDLE   ELSE
             x"1" WHEN se = S_TOKEN  ELSE
             x"2" WHEN se = S_TOKW   ELSE
             x"3" WHEN se = S_TXDATA ELSE
             x"4" WHEN se = S_TXDW   ELSE
             x"5" WHEN se = S_RXWAIT ELSE
             x"6" WHEN se = S_RXEND  ELSE
             x"7" WHEN se = S_ACK    ELSE
             x"8" WHEN se = S_ACKW   ELSE
             x"9" WHEN se = S_SOFW   ELSE
             x"A";                                    -- S_FIN

  tx_code <= x"0" WHEN tx_st = T_IDLE ELSE
             x"1" WHEN tx_st = T_SYNC ELSE
             x"2" WHEN tx_st = T_BYTE ELSE
             x"3" WHEN tx_st = T_CRC  ELSE
             x"4" WHEN tx_st = T_TAIL ELSE
             x"5" WHEN tx_st = T_EOP1 ELSE
             x"6" WHEN tx_st = T_EOP2 ELSE
             x"7" WHEN tx_st = T_EOPJ ELSE
             x"8";                                    -- T_DONE

  rx_code <= "00" WHEN rx_st = R_IDLE ELSE
             "01" WHEN rx_st = R_SYNC ELSE
             "10" WHEN rx_st = R_DATA ELSE
             "11";                                    -- R_EOP

  -- Diagnostic window. Index 0 keeps 0xEF's original meaning (frame counter),
  -- so anything already reading it is unaffected.
  diag_q <= frame_cnt(7 DOWNTO 0)  WHEN diag_sel = x"00" ELSE
            c_crcerr               WHEN diag_sel = x"01" ELSE
            c_tmo                  WHEN diag_sel = x"02" ELSE
            c_nak(7 DOWNTO 0)      WHEN diag_sel = x"03" ELSE
            c_stall                WHEN diag_sel = x"04" ELSE
            c_pktin(7 DOWNTO 0)    WHEN diag_sel = x"05" ELSE
            c_pktin(15 DOWNTO 8)   WHEN diag_sel = x"06" ELSE
            c_pktout(7 DOWNTO 0)   WHEN diag_sel = x"07" ELSE
            c_pktout(15 DOWNTO 8)  WHEN diag_sel = x"08" ELSE
            c_nak(15 DOWNTO 8)     WHEN diag_sel = x"09" ELSE
            c_txn(7 DOWNTO 0)      WHEN diag_sel = x"0A" ELSE
            c_txn(15 DOWNTO 8)     WHEN diag_sel = x"0B" ELSE
            tx_code & se_code      WHEN diag_sel = x"0C" ELSE
            (LOCKED & go_pend & tx_req & st_busy &
             sof_req & ctrl_m(1) & rx_code)
                                   WHEN diag_sel = x"0D" ELSE
            -- Which instance is answering. With two engines at two windows, a
            -- tool pointed at the wrong one reads plausible-looking registers
            -- and draws confident wrong conclusions -- the same failure mode as
            -- the build signature below, one level up. This reads back the low
            -- byte of the window the instance actually decodes, so software can
            -- assert it is talking to the port it thinks it is.
            IO_BASE(7 DOWNTO 0)    WHEN diag_sel = x"0E" ELSE
            -- Build signature. Twice now, a board running an older bitstream has
            -- been diagnosed as a USB fault: the registers still answer, so the
            -- controller looks present, and the numbers look like a real failure.
            -- Software reads this first and refuses to blame USB if it is wrong.
            x"A5"                  WHEN diag_sel = x"0F" ELSE
            x"00";

  -- ==========================================================================
  --  CPU register interface (5 MHz domain)
  -- ==========================================================================
  DATAOUT <=
      (st_rxv & st_rxd1 & st_err & st_to & st_stall & st_nak & st_ack & st_busy)
        WHEN (RD = '0' AND io_hit = '1' AND io_reg = RG_CMD)  ELSE
      ('0' & r_devaddr)  WHEN (RD = '0' AND io_hit = '1' AND io_reg = RG_DEVA) ELSE
      rx_pid             WHEN (RD = '0' AND io_hit = '1' AND io_reg = RG_ENDP) ELSE
      ('0' & rx_len)     WHEN (RD = '0' AND io_hit = '1' AND io_reg = RG_LEN)  ELSE
      rxb_q              WHEN (RD = '0' AND io_hit = '1' AND io_reg = RG_DATA) ELSE
      ('0' & tx_ptr)     WHEN (RD = '0' AND io_hit = '1' AND io_reg = RG_PTR)  ELSE
      ("00" & LOCKED & ctrl_s(2) &
       (dm_r AND NOT dp_r) & (dp_r AND NOT dm_r) & dm_r & dp_r)
                         WHEN (RD = '0' AND io_hit = '1' AND io_reg = RG_CTRL) ELSE
      diag_q             WHEN (RD = '0' AND io_hit = '1' AND io_reg = RG_DIAG) ELSE
      "ZZZZZZZZ";

  CPU_REGS : PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      IF RESET = '1' THEN
        r_cmd <= (OTHERS => '0'); r_devaddr <= (OTHERS => '0');
        r_endp <= (OTHERS => '0'); r_txlen <= (OTHERS => '0');
        r_ctrl <= (OTHERS => '0'); tx_ptr <= (OTHERS => '0');
        rx_ptr <= (OTHERS => '0'); go_cpu <= '0';
      ELSE
        -- falling edge of WR: DATAIN is valid and this fires exactly once
        IF (wr_prev = '1' AND WR = '0' AND io_hit = '1') THEN
          CASE io_reg IS
            WHEN RG_CMD =>
              r_cmd <= DATAIN;
              IF DATAIN(7) = '1' THEN
                go_cpu <= NOT go_cpu;        -- level toggle crosses cleanly
              END IF;
            WHEN RG_DEVA => r_devaddr <= DATAIN(6 DOWNTO 0);
            WHEN RG_ENDP => r_endp    <= DATAIN(3 DOWNTO 0);
            WHEN RG_LEN  => r_txlen   <= DATAIN(6 DOWNTO 0);
            WHEN RG_DATA =>
              IF tx_ptr < 64 THEN
                txbuf(conv_integer(tx_ptr(5 DOWNTO 0))) <= DATAIN;
                tx_ptr <= tx_ptr + 1;
              END IF;
            WHEN RG_PTR =>
              tx_ptr <= DATAIN(6 DOWNTO 0);
              rx_ptr <= DATAIN(6 DOWNTO 0);
            WHEN RG_CTRL => r_ctrl <= DATAIN;
            WHEN RG_DIAG => diag_sel <= DATAIN;   -- pick a counter to read
            WHEN OTHERS => NULL;
          END CASE;
        END IF;

        -- Reading the data port advances the RX pointer, on the RISING edge of
        -- RD -- i.e. once the CPU has taken the byte. Advancing on the falling
        -- edge would change rxb_q underneath the cycle that is still reading it.
        -- Latch the fact during the cycle and act at the end, rather than
        -- testing ADDR on the closing edge: ADDR is held by busdecode until the
        -- next ALE, but not relying on that is free.
        IF (RD = '0' AND io_hit = '1' AND io_reg = RG_DATA) THEN
          rd_data_c <= '1';
        END IF;
        IF (rd_prev = '0' AND RD = '1' AND rd_data_c = '1') THEN
          rd_data_c <= '0';
          IF rx_ptr < 64 THEN
            rx_ptr <= rx_ptr + 1;
          END IF;
        END IF;
      END IF;

      wr_prev <= WR;
      rd_prev <= RD;

      rxb_q <= rxbuf(conv_integer(rx_ptr(5 DOWNTO 0)));
    END IF;
  END PROCESS;

  -- ==========================================================================
  --  Clock crossing.  The command registers are only sampled while the SIE is
  --  idle, and go_cpu is a toggle, so a plain two-stage synchroniser is enough.
  --  ctrl_m is used combinationally by the transmitter (BUSRESET), so it gets
  --  its own synchroniser rather than being read straight out of the CLK domain.
  -- ==========================================================================
  SYNC48 : PROCESS (CLK48)
  BEGIN
    IF rising_edge(CLK48) THEN
      go_m1 <= go_cpu;  go_m2 <= go_m1;  go_m3 <= go_m2;
      ctrl_s <= r_ctrl; ctrl_m <= ctrl_s;
      cmd_s  <= r_cmd;  dev_s  <= r_devaddr; endp_s <= r_endp;
      txlen_s <= r_txlen;
      dp_s1 <= dp_in;   dm_s1 <= dm_in;
      dp_r  <= dp_s1;   dm_r  <= dm_s1;
      dp_p  <= dp_r;    dm_p  <= dm_r;
    END IF;
  END PROCESS;

  -- ==========================================================================
  --  Buffers, USB side
  -- ==========================================================================
  BUF48 : PROCESS (CLK48)
  BEGIN
    IF rising_edge(CLK48) THEN
      txb_q <= txbuf(conv_integer(sie_txadr));
      IF sie_rxwe = '1' THEN
        rxbuf(conv_integer(sie_rxadr)) <= sie_rxd;
      END IF;
    END IF;
  END PROCESS;

  -- ==========================================================================
  --  Transmitter.  Emits SYNC, then bytes with NRZI + bit stuffing, then either
  --  a CRC16 or nothing, then EOP.  Bytes come either from tx_lit (up to three
  --  literal bytes: PID and token, or PID alone) or from the TX buffer.
  -- ==========================================================================
  TXP : PROCESS (CLK48)
    VARIABLE b : std_logic;
  BEGIN
    IF rising_edge(CLK48) THEN
      tx_done <= '0';

      -- BUSRESET wins over everything: hold SE0 for as long as software asks
      -- Latch the request whatever state the transmitter is in.
      IF tx_go = '1' THEN
        tx_req <= '1';
      END IF;

      IF ctrl_m(1) = '1' THEN
        tx_oe <= '1'; tx_dp <= '0'; tx_dm <= '0';
        tx_st <= T_IDLE;
        tx_req <= '0';                 -- a bus reset abandons any request
      ELSE

      CASE tx_st IS

        WHEN T_IDLE =>
          tx_oe <= '0';
          tx_ph <= 0; tx_ones <= 0; tx_j <= '1'; tx_stuff <= '0';
          tx_crc16 <= (OTHERS => '1');
          tx_cnt    <= (OTHERS => '0');
          sie_txadr <= (OTHERS => '0');
          tx_src    <= '0';
          tx_crcen  <= '0';
          IF tx_req = '1' THEN
            tx_req   <= '0';
            tx_st    <= T_SYNC;
            tx_nbit  <= 0;
            tx_oe    <= '1';
            tx_dp    <= '1'; tx_dm <= '0';       -- start from idle J
            tx_lit   <= req_lit;                 -- take a private copy
            tx_litn  <= req_litn;
            tx_total <= req_total;
            tx_crcsel<= req_crc16;
          END IF;

        -- SYNC is KJKJKJKK: seven transitions then a held K. Sending the bit
        -- pattern 00000001 through the NRZI encoder produces exactly that, and
        -- SYNC is never bit-stuffed.
        WHEN T_SYNC =>
          IF tx_ph = BIT_DIV-1 THEN
            tx_ph <= 0;
            IF tx_nbit = 7 THEN
              b := '1';
            ELSE
              b := '0';
            END IF;
            IF b = '0' THEN                       -- 0 = toggle
              tx_j <= NOT tx_j;
              tx_dp <= NOT tx_j; tx_dm <= tx_j;
            END IF;
            IF tx_nbit = 7 THEN
              tx_nbit  <= 0;
              tx_st    <= T_BYTE;
              tx_sh    <= tx_lit(7 DOWNTO 0);
              tx_ones  <= 0;
            ELSE
              tx_nbit <= tx_nbit + 1;
            END IF;
          ELSE
            tx_ph <= tx_ph + 1;
          END IF;

        WHEN T_BYTE =>
          IF tx_ph = BIT_DIV-1 THEN
            tx_ph <= 0;
            IF tx_stuff = '1' THEN
              -- forced 0 after six 1s
              tx_stuff <= '0';
              tx_ones  <= 0;
              tx_j     <= NOT tx_j;
              tx_dp    <= NOT tx_j; tx_dm <= tx_j;
            ELSE
              b := tx_sh(0);
              tx_sh <= '0' & tx_sh(7 DOWNTO 1);
              IF b = '0' THEN
                tx_j  <= NOT tx_j;
                tx_dp <= NOT tx_j; tx_dm <= tx_j;
                tx_ones <= 0;
              ELSE
                IF tx_ones = 5 THEN
                  tx_stuff <= '1';
                  tx_ones  <= 0;
                ELSE
                  tx_ones <= tx_ones + 1;
                END IF;
              END IF;
              -- CRC16 over payload bytes only
              IF tx_crcen = '1' THEN
                IF (b XOR tx_crc16(15)) = '1' THEN
                  tx_crc16 <= (tx_crc16(14 DOWNTO 0) & '0') XOR x"8005";
                ELSE
                  tx_crc16 <= tx_crc16(14 DOWNTO 0) & '0';
                END IF;
              END IF;

              IF tx_nbit = 7 THEN
                tx_nbit <= 0;
                -- next byte?
                IF tx_src = '0' THEN
                  IF tx_litn > 1 THEN
                    tx_lit  <= x"00" & tx_lit(23 DOWNTO 8);
                    tx_litn <= tx_litn - 1;
                    tx_sh   <= tx_lit(15 DOWNTO 8);
                  ELSE
                    -- literals exhausted: buffer next, or CRC, or EOP
                    IF tx_total > 0 THEN
                      tx_src   <= '1';
                      tx_crcen <= '1';
                      tx_sh    <= txb_q;
                      tx_cnt   <= tx_cnt + 1;
                      sie_txadr<= tx_cnt(5 DOWNTO 0) + 1;
                    ELSIF tx_crcsel = '1' THEN
                      tx_st  <= T_CRC;
                      tx_nbit<= 0;
                      tx_crcen <= '0';
                    ELSE
                      tx_st <= T_TAIL;
                    END IF;
                  END IF;
                ELSE
                  IF tx_cnt < tx_total THEN
                    tx_sh     <= txb_q;
                    tx_cnt    <= tx_cnt + 1;
                    sie_txadr <= tx_cnt(5 DOWNTO 0) + 1;
                  ELSIF tx_crcsel = '1' THEN
                    tx_st    <= T_CRC;
                    tx_nbit  <= 0;
                    tx_crcen <= '0';
                  ELSE
                    tx_st <= T_TAIL;
                  END IF;
                END IF;
              ELSE
                tx_nbit <= tx_nbit + 1;
              END IF;
            END IF;
          ELSE
            tx_ph <= tx_ph + 1;
          END IF;

        -- CRC16 goes out inverted, MSB of the register first
        WHEN T_CRC =>
          IF tx_ph = BIT_DIV-1 THEN
            tx_ph <= 0;
            IF tx_stuff = '1' THEN
              tx_stuff <= '0'; tx_ones <= 0;
              tx_j  <= NOT tx_j;
              tx_dp <= NOT tx_j; tx_dm <= tx_j;
            ELSE
              b := NOT tx_crc16(15);
              tx_crc16 <= tx_crc16(14 DOWNTO 0) & '0';
              IF b = '0' THEN
                tx_j <= NOT tx_j;
                tx_dp <= NOT tx_j; tx_dm <= tx_j;
                tx_ones <= 0;
              ELSE
                IF tx_ones = 5 THEN
                  tx_stuff <= '1'; tx_ones <= 0;
                ELSE
                  tx_ones <= tx_ones + 1;
                END IF;
              END IF;
              IF tx_nbit = 15 THEN
                tx_nbit <= 0;
                tx_st   <= T_TAIL;
              ELSE
                tx_nbit <= tx_nbit + 1;
              END IF;
            END IF;
          ELSE
            tx_ph <= tx_ph + 1;
          END IF;

        -- Hold the final bit for its own full bit time before EOP.
        --
        -- The level for bit N is computed at the phase wrap and then sits on the
        -- wire through the FOLLOWING bit slot. That is fine everywhere except the
        -- end of a packet: jumping straight from the last bit to T_EOP1 gave that
        -- bit a single clock instead of four, so the receiving device never
        -- assembled the final byte. Tokens arrived without their CRC5 byte, data
        -- packets without half their CRC16, and an ACK lost its PID entirely.
        --
        -- A device that receives a SETUP whose last byte is missing answers
        -- STALL, which is exactly what the hardware did.
        WHEN T_TAIL =>
          IF tx_ph = BIT_DIV-1 THEN
            tx_ph <= 0;
            IF tx_stuff = '1' THEN
              -- A run of six 1s can end on the packet's very LAST bit, and the
              -- mandatory stuffed 0 must still go out before EOP. Dropping it
              -- makes the receiver see six 1s against EOP -- a bit-stuff
              -- violation -- so it discards the packet and answers nothing.
              -- Whether a packet hits this depends only on its bytes: the
              -- write soak failed at the same three LBAs on every run, and the
              -- Python model of this logic reproduced exactly those three from
              -- the pattern generator alone. Emit the stuffed bit, hold it for
              -- a full bit time by staying here, then end the packet.
              tx_stuff <= '0';
              tx_ones  <= 0;
              tx_j     <= NOT tx_j;
              tx_dp    <= NOT tx_j; tx_dm <= tx_j;
            ELSE
              tx_st <= T_EOP1;
            END IF;
          ELSE
            tx_ph <= tx_ph + 1;
          END IF;

        WHEN T_EOP1 =>                              -- SE0, two bit times
          tx_dp <= '0'; tx_dm <= '0';
          IF tx_ph = BIT_DIV-1 THEN
            tx_ph <= 0; tx_st <= T_EOP2;
          ELSE
            tx_ph <= tx_ph + 1;
          END IF;

        WHEN T_EOP2 =>
          IF tx_ph = BIT_DIV-1 THEN
            tx_ph <= 0; tx_st <= T_EOPJ;
            tx_dp <= '1'; tx_dm <= '0';             -- one bit of J
          ELSE
            tx_ph <= tx_ph + 1;
          END IF;

        WHEN T_EOPJ =>
          IF tx_ph = BIT_DIV-1 THEN
            tx_ph <= 0; tx_st <= T_DONE;
          ELSE
            tx_ph <= tx_ph + 1;
          END IF;

        WHEN T_DONE =>
          tx_oe   <= '0';
          tx_done <= '1';
          tx_st   <= T_IDLE;

      END CASE;
      END IF;

      IF RESET = '1' THEN
        tx_st <= T_IDLE; tx_oe <= '0'; tx_req <= '0';
      END IF;
    END IF;
  END PROCESS;

  -- ==========================================================================
  --  Receiver.  4x oversampled with a one-shot resync: every line transition
  --  restarts the phase counter, so sampling stays in the middle of the eye
  --  even with the frequency tolerance USB allows.
  -- ==========================================================================
  RXP : PROCESS (CLK48)
    VARIABLE k    : std_logic;
    VARIABLE b    : std_logic;
    VARIABLE se0  : std_logic;
    VARIABLE edg  : std_logic;
    VARIABLE samp : std_logic;
  BEGIN
    IF rising_edge(CLK48) THEN
      rx_done  <= '0';
      sie_rxwe <= '0';

      -- Count consecutive SE0 samples; se0_st is the filtered result.
      IF (dp_r = '0' AND dm_r = '0') THEN
        IF se0_cnt < 7 THEN
          se0_cnt <= se0_cnt + 1;
        END IF;
      ELSE
        se0_cnt <= 0;
      END IF;
      IF se0_cnt >= 3 THEN
        se0_st <= '1';
      ELSE
        se0_st <= '0';
      END IF;
      se0 := se0_st;
      k := dm_r;                                    -- FS: K is D- high

      -- Sampling clock. The phase counter free-runs mod 4, and ANY line
      -- transition forces it back to 0, so the sample point stays two clocks
      -- (half a bit) after the most recent edge no matter how the device's
      -- 12 MHz drifts against our 48 MHz.
      edg := (dp_r XOR dp_p) OR (dm_r XOR dm_p);
      samp := '0';
      IF edg = '1' THEN
        rx_ph <= 0;
      ELSIF rx_ph = BIT_DIV-1 THEN
        rx_ph <= 0;
      ELSE
        IF rx_ph = 1 THEN
          samp := '1';
        END IF;
        rx_ph <= rx_ph + 1;
      END IF;

      CASE rx_st IS

        -- Nothing is cleared on the way OUT of a packet. rx_done reaches the
        -- sequencer one clock after R_EOP, by which point this state has already
        -- run -- clearing here wiped rx_bytes and rx_err before they could be
        -- read, so every reply looked like a zero-length packet. The state is
        -- cleared when a packet STARTS instead.
        WHEN R_IDLE =>
          -- SYNC opens with idle J -> K while we are listening
          IF (rx_arm = '1' AND dp_r = '0' AND dm_r = '1') THEN
            rx_st    <= R_SYNC;
            -- rx_prev holds the previous value of k, and k IS D-. Idle J has
            -- D- LOW, so this seeds to '0'. Seeding it to '1' -- thinking of it
            -- as "the J state" -- made the first SYNC bit decode as 1, which
            -- ended SYNC immediately and shifted the entire packet by seven
            -- bits. The payload still arrived, just misaligned.
            rx_prev  <= '0';
            rx_ph    <= 0;
            rx_ones  <= 0;
            rx_nbit  <= 0;
            rx_bytes <= (OTHERS => '0');
            rx_err   <= '0';
          END IF;

        -- SYNC is KJKJKJKK, which through the NRZI decoder is 0000_0001: seven
        -- transitions then one hold. So the same decoder used for data finds the
        -- end of SYNC for free -- the first decoded 1 IS the last SYNC bit, and
        -- the next sample is the first bit of the PID.
        --
        -- An earlier version tried to count six bit times here, but the edge
        -- branch reset the phase without ever advancing the counter, so during
        -- the transitions the count never moved and this state never exited.
        WHEN R_SYNC =>
          IF se0 = '1' THEN
            rx_st <= R_IDLE;                        -- collapsed, give up
          ELSIF samp = '1' THEN
            IF k = rx_prev THEN
              b := '1';
            ELSE
              b := '0';
            END IF;
            rx_prev <= k;
            IF b = '1' THEN
              rx_st   <= R_DATA;
              rx_nbit <= 0;
              rx_ones <= 0;
            ELSE
              IF rx_nbit = 11 THEN                  -- SYNC far too long
                rx_err <= '1';
                rx_st  <= R_IDLE;
              ELSE
                rx_nbit <= rx_nbit + 1;
              END IF;
            END IF;
          END IF;

        WHEN R_DATA =>
          IF se0 = '1' THEN
            rx_st <= R_EOP;
          ELSIF samp = '1' THEN
            IF k = rx_prev THEN                     -- NRZI: no change = 1
              b := '1';
            ELSE
              b := '0';
            END IF;
            rx_prev <= k;
            IF rx_ones = 6 THEN
              -- stuffed bit, always a 0; drop it and do not count it
              rx_ones <= 0;
              IF b /= '0' THEN
                rx_err <= '1';
              END IF;
            ELSE
              IF b = '1' THEN
                rx_ones <= rx_ones + 1;
              ELSE
                rx_ones <= 0;
              END IF;
              rx_sh <= b & rx_sh(7 DOWNTO 1);       -- LSB first
              IF rx_nbit = 7 THEN
                rx_nbit <= 0;
                IF rx_bytes = 0 THEN
                  rx_pid <= b & rx_sh(7 DOWNTO 1);
                ELSIF rx_bytes < 65 THEN
                  sie_rxadr <= rx_bytes(5 DOWNTO 0) - 1;
                  sie_rxd   <= b & rx_sh(7 DOWNTO 1);
                  sie_rxwe  <= '1';
                END IF;
                rx_bytes <= rx_bytes + 1;
              ELSE
                rx_nbit <= rx_nbit + 1;
              END IF;
            END IF;
          END IF;

        WHEN R_EOP =>
          rx_done <= '1';
          rx_st   <= R_IDLE;

      END CASE;

      IF RESET = '1' THEN
        rx_st   <= R_IDLE;
        se0_cnt <= 0;
        se0_st  <= '0';
      END IF;
    END IF;
  END PROCESS;

  -- ==========================================================================
  --  Sequencer: one transaction, plus the 1 ms SOF that keeps devices awake.
  -- ==========================================================================
  SEQ : PROCESS (CLK48)
    VARIABLE tok : std_logic_vector(10 DOWNTO 0);
    VARIABLE c5  : std_logic_vector(4 DOWNTO 0);
  BEGIN
    IF rising_edge(CLK48) THEN
      tx_go <= '0';

      -- Catch the GO toggle whenever it arrives; S_IDLE consumes it when it can.
      --
      -- BUSY is raised HERE, not when the sequencer actually starts the
      -- transaction. Latching GO stopped commands being lost, but the CPU could
      -- still poll BUSY while the sequencer was mid-SOF -- where it is 0 -- see
      -- "not busy", conclude the transaction had already finished, and read the
      -- PREVIOUS one's status. A stale ACK means the caller believes a packet
      -- went out when it never did, which desynchronises the bulk stream just
      -- as thoroughly as dropping the command did.
      IF go_m3 /= go_m2 THEN
        go_pend <= '1';
        st_busy <= '1';
      END IF;

      -- free-running 1 ms tick
      IF ctrl_m(2) = '1' THEN
        IF sof_cnt = SOF_DIV-1 THEN
          sof_cnt <= 0;
          sof_req <= '1';
        ELSE
          sof_cnt <= sof_cnt + 1;
        END IF;
      ELSE
        sof_cnt <= 0;
      END IF;

      CASE se IS

        WHEN S_IDLE =>
          rx_arm  <= '0';
          IF go_pend = '1' THEN                     -- a command is waiting
            go_pend  <= '0';
            c_txn    <= c_txn + 1;
            st_ack   <= '0'; st_nak <= '0'; st_stall <= '0';
            st_to    <= '0'; st_err <= '0'; st_rxv <= '0';
            rx_len   <= (OTHERS => '0');
            rx_gcnt <= 0;
            se_op    <= cmd_s(2 DOWNTO 0);
            se_d1    <= cmd_s(3);
            se       <= S_TOKEN;
          ELSIF sof_req = '1' THEN
            sof_req   <= '0';
            frame_cnt <= frame_cnt + 1;
            tok := frame_cnt(10 DOWNTO 0);
            c5  := crc5(tok);
            req_lit  <= (c5(0) & c5(1) & c5(2) & c5(3) & c5(4)
                         & tok(10 DOWNTO 8)) & tok(7 DOWNTO 0) & PID_SOF;
            req_litn <= 3;
            req_crc16<= '0';
            req_total<= (OTHERS => '0');
            tx_go    <= '1';
            tx_wcnt   <= 0;
            se      <= S_SOFW;
          END IF;

        -- ---- token packet: PID + address/endpoint + CRC5 ----
        WHEN S_TOKEN =>
          tok := endp_s & dev_s;
          c5  := crc5(tok);
          CASE se_op IS
            WHEN "001"  => req_lit(7 DOWNTO 0) <= PID_SETUP;
            WHEN "010"  => req_lit(7 DOWNTO 0) <= PID_IN;
            WHEN "011"  => req_lit(7 DOWNTO 0) <= PID_OUT;
            WHEN OTHERS => req_lit(7 DOWNTO 0) <= PID_SOF;
          END CASE;
          -- CRC5 is transmitted MSb first, so the field is the REVERSE of the
          -- LFSR output. Checked against reference vectors: addr 0 ep 0 must
          -- put 00 10 on the wire.
          req_lit(23 DOWNTO 8) <= (c5(0) & c5(1) & c5(2) & c5(3) & c5(4)
                                   & tok(10 DOWNTO 8)) & tok(7 DOWNTO 0);
          req_litn  <= 3;
          req_crc16 <= '0';
          req_total <= (OTHERS => '0');
          tx_go     <= '1';
          tx_wcnt   <= 0;
          se        <= S_TOKW;

        WHEN S_TOKW =>
          IF tx_wcnt = 8191 THEN
            st_err <= '1'; se <= S_FIN;
          ELSE
            tx_wcnt <= tx_wcnt + 1;
          END IF;
          IF tx_done = '1' THEN
            IF se_op = "010" THEN                   -- IN: listen for data
              rx_arm    <= '1';
              rx_to_cnt <= 0;
              se        <= S_RXWAIT;
            ELSE                                    -- SETUP / OUT: send data
              se <= S_TXDATA;
            END IF;
          END IF;

        -- ---- data packet ----
        WHEN S_TXDATA =>
          IF se_d1 = '1' THEN
            req_lit(7 DOWNTO 0) <= PID_DATA1;
          ELSE
            req_lit(7 DOWNTO 0) <= PID_DATA0;
          END IF;
          req_litn  <= 1;
          req_crc16 <= '1';
          req_total <= txlen_s;
          tx_go     <= '1';
          tx_wcnt   <= 0;
          se        <= S_TXDW;

        WHEN S_TXDW =>
          IF tx_wcnt = 8191 THEN
            st_err <= '1'; se <= S_FIN;
          ELSE
            tx_wcnt <= tx_wcnt + 1;
          END IF;
          IF tx_done = '1' THEN
            rx_arm    <= '1';
            rx_to_cnt <= 0;
            se        <= S_RXWAIT;
          END IF;

        -- ---- wait for the device ----
        WHEN S_RXWAIT =>
          IF rx_done = '1' THEN
            rx_arm <= '0';
            se     <= S_RXEND;
          ELSIF rx_st = R_IDLE THEN
            -- nothing has started arriving yet: this is the real response
            -- timeout, and the only case that should report TIMEOUT
            IF rx_to_cnt = RX_TO-1 THEN
              rx_arm <= '0';
              st_to  <= '1';
              c_tmo  <= c_tmo + 1;
              se     <= S_FIN;
            ELSE
              rx_to_cnt <= rx_to_cnt + 1;
            END IF;
          ELSE
            -- a packet is coming in; let it finish, but do not wait forever
            IF rx_gcnt = RX_GUARD-1 THEN
              rx_arm <= '0';
              st_err <= '1';
              se     <= S_FIN;
            ELSE
              rx_gcnt <= rx_gcnt + 1;
            END IF;
          END IF;

        WHEN S_RXEND =>
          -- PID check: high nibble must be the complement of the low one
          IF rx_pid(7 DOWNTO 4) /= (NOT rx_pid(3 DOWNTO 0)) THEN
            st_err   <= '1';
            c_crcerr <= c_crcerr + 1;
            se       <= S_FIN;
          ELSE
            CASE rx_pid IS
              WHEN PID_ACK   => st_ack <= '1';
                                c_pktout <= c_pktout + 1;
                                se <= S_FIN;
              WHEN PID_NAK   => st_nak <= '1';
                                c_nak <= c_nak + 1;
                                se <= S_FIN;
              WHEN PID_STALL => st_stall <= '1';
                                c_stall <= c_stall + 1;
                                se <= S_FIN;
              WHEN PID_DATA0 | PID_DATA1 =>
                st_rxv  <= '1';
                IF rx_pid = PID_DATA1 THEN
                  st_rxd1 <= '1';
                ELSE
                  st_rxd1 <= '0';
                END IF;
                c_pktin <= c_pktin + 1;
                IF rx_err = '1' THEN
                  st_err   <= '1';
                  c_crcerr <= c_crcerr + 1;
                END IF;
                -- rx_bytes counts PID + payload + 2 CRC bytes
                IF rx_bytes > 3 THEN
                  rx_len <= rx_bytes - 3;
                ELSE
                  rx_len <= (OTHERS => '0');
                END IF;
                se <= S_ACK;
              WHEN OTHERS =>
                st_err   <= '1';
                c_crcerr <= c_crcerr + 1;
                se       <= S_FIN;
            END CASE;
          END IF;

        -- ---- acknowledge a data packet we accepted ----
        WHEN S_ACK =>
          turn <= 0;
          IF se_op = "010" THEN
            req_lit(7 DOWNTO 0) <= PID_ACK;
            req_litn  <= 1;
            req_crc16 <= '0';
            req_total <= (OTHERS => '0');
            tx_go     <= '1';
            tx_wcnt   <= 0;
            se        <= S_ACKW;
          ELSE
            se <= S_FIN;
          END IF;

        WHEN S_ACKW =>
          IF tx_wcnt = 8191 THEN
            st_err <= '1'; se <= S_FIN;
          ELSE
            tx_wcnt <= tx_wcnt + 1;
          END IF;
          IF tx_done = '1' THEN
            se <= S_FIN;
          END IF;

        -- A SOF is the controller's own housekeeping, not a CPU transaction,
        -- so it must leave BUSY exactly as it found it.
        WHEN S_SOFW =>
          IF tx_wcnt = 8191 THEN
            se <= S_IDLE;            -- a lost SOF is not worth reporting
          ELSE
            tx_wcnt <= tx_wcnt + 1;
          END IF;
          IF tx_done = '1' THEN
            se <= S_IDLE;
          END IF;

        WHEN S_FIN =>
          IF go_pend = '0' THEN                     -- do not clear a command
            st_busy <= '0';                         -- that arrived this cycle
          END IF;
          se      <= S_IDLE;

      END CASE;

      IF RESET = '1' THEN
        se <= S_IDLE; st_busy <= '0'; frame_cnt <= (OTHERS => '0');
        go_pend <= '0';
      END IF;
    END IF;
  END PROCESS;

END rtl;
