--------------------------------------------------------------------------------
-- fdc8272.vhd  --  uPD765 / 8272A-compatible floppy controller
--                   backed by a UART link to a host PC serving a floppy.img
--
-- Supports BOTH transfer modes, selected by the ND bit of the Specify command
-- (param 2, bit 0):
--   ND = 0  -> DMA mode  : execution-phase bytes move FDC<->memory via the 8237
--                          (DREQ/DACK/TC). Works with a STOCK DMA BIOS.
--   ND = 1  -> non-DMA   : bytes move through the 0x3F5 FIFO with MSR.RQM
--                          handshaking (needs a PIO INT 13h).
-- Default after reset is DMA (ND=0) so a stock BIOS works out of the box.
--
-- In both modes the disk side is identical: per 512-byte sector the controller
-- fetches/stores over the UART:
--   READ :  FPGA -> host : 0x33 0x01 C H R          ; host -> FPGA : 512 bytes
--   WRITE:  FPGA -> host : 0x33 0x02 C H R <512>     ; host -> FPGA : 0x06
--
-- I/O map: 0x3F2 DOR(w) 0x3F4 MSR(r) 0x3F5 DATA(rw) 0x3F7 DIR(r)/CCR(w).
-- Commands: Specify(03) SenseDrive(04) Write(05) Read(06) Recalibrate(07)
--           SenseInterrupt(08) ReadID(0A) Seek(0F); others -> ST0=0x80.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY fdc8272 IS
  GENERIC(
        CLK_FREQ : integer := 50_000_000;   -- system clock feeding CLK
        BAUD     : integer := 115200 );     -- raise for more throughput
  PORT(
        CLK      : IN    std_logic;
        RESET    : IN    std_logic;

        -- CPU bus (active-LOW strobes, gated I/O cycle)
        ADDR     : IN    std_logic_vector(15 DOWNTO 0);
        RD       : IN    std_logic;
        WR       : IN    std_logic;
        DATAIN   : IN    std_logic_vector(7 DOWNTO 0);
        DATAOUT  : OUT   std_logic_vector(7 DOWNTO 0);  -- 'Z' when not addressed

        IRQ      : OUT   std_logic;                     -- -> 8259 IR6 (active high)

        -- DMA handshake (active HIGH, to/from 8237)
        DRQ      : OUT   std_logic;                     -- -> 8237 DREQ2
        DACK     : IN    std_logic;                     -- <- 8237 DACK2
        TC       : IN    std_logic;                     -- <- 8237 terminal count
        DMA_DOUT : OUT   std_logic_vector(7 DOWNTO 0);  -- byte -> memory (floppy read)
        DMA_DIN  : IN    std_logic_vector(7 DOWNTO 0);  -- byte <- memory (floppy write)

        -- UART to host
        UART_TX  : OUT   std_logic;
        UART_RX  : IN    std_logic );
END fdc8272;


ARCHITECTURE behavior OF fdc8272 IS

  CONSTANT BAUD_DIV : integer := CLK_FREQ / BAUD;

  -- Host protocol constants
  CONSTANT PREAMBLE : std_logic_vector(7 DOWNTO 0) := x"33";
  CONSTANT HCMD_RD  : std_logic_vector(7 DOWNTO 0) := x"01";
  CONSTANT HCMD_WR  : std_logic_vector(7 DOWNTO 0) := x"02";
  CONSTANT WR_ACK   : std_logic_vector(7 DOWNTO 0) := x"06";

  ----------------------------------------------------------------------------
  -- UART
  ----------------------------------------------------------------------------
  SIGNAL tx_start : std_logic := '0';
  SIGNAL tx_data  : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL tx_busy  : std_logic := '0';
  SIGNAL tx_out   : std_logic := '1';
  SIGNAL tx_shift : std_logic_vector(9 DOWNTO 0) := (OTHERS => '1');
  SIGNAL tx_cnt   : integer RANGE 0 TO 10 := 0;
  SIGNAL tx_div   : integer RANGE 0 TO 65535 := 0;

  SIGNAL rx_sync  : std_logic_vector(1 DOWNTO 0) := "11";
  SIGNAL rx_busy  : std_logic := '0';
  SIGNAL rx_div   : integer RANGE 0 TO 65535 := 0;
  SIGNAL rx_cnt   : integer RANGE 0 TO 10 := 0;
  SIGNAL rx_shift : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL rx_valid : std_logic := '0';
  SIGNAL rx_data  : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');

  ----------------------------------------------------------------------------
  -- 512-byte sector buffer (registered read)
  ----------------------------------------------------------------------------
  TYPE buf_t IS ARRAY (0 TO 511) OF std_logic_vector(7 DOWNTO 0);
  SIGNAL sbuf     : buf_t;
  SIGNAL buf_dout : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL buf_idx  : integer RANGE 0 TO 512 := 0;

  ----------------------------------------------------------------------------
  -- Register decode + bus edge detect
  ----------------------------------------------------------------------------
  SIGNAL sel_dor, sel_msr, sel_data, sel_dir, sel_ccr : std_logic;
  SIGNAL rd_prev, wr_prev : std_logic := '1';
  SIGNAL rd_done, wr_done : std_logic;

  SIGNAL dor : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');

  ----------------------------------------------------------------------------
  -- Command engine
  ----------------------------------------------------------------------------
  TYPE st_t IS (
    ST_IDLE, ST_PARAMS, ST_DISPATCH,
    ST_RD_REQ, ST_RD_RX, ST_RD_XFER, ST_RD_DMA,
    ST_WR_XFER, ST_WR_DMA, ST_WR_REQ, ST_WR_DATA, ST_WR_ACK,
    ST_NEXT, ST_RESULT, ST_SEEKDONE );
  SIGNAL st : st_t := ST_IDLE;

  TYPE bytes8_t IS ARRAY (0 TO 7) OF std_logic_vector(7 DOWNTO 0);
  TYPE bytes7_t IS ARRAY (0 TO 6) OF std_logic_vector(7 DOWNTO 0);
  SIGNAL params : bytes8_t;
  SIGNAL res    : bytes7_t;

  SIGNAL cmd       : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL nparams   : integer RANGE 0 TO 8 := 0;
  SIGNAL pidx      : integer RANGE 0 TO 8 := 0;
  SIGNAL nresults  : integer RANGE 0 TO 7 := 0;
  SIGNAL ridx      : integer RANGE 0 TO 7 := 0;

  -- transfer bookkeeping
  SIGNAL cur_c, cur_h, cur_r, eot : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL drive_sel : std_logic_vector(1 DOWNTO 0) := "00";
  SIGNAL pcn       : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');  -- present cyl
  SIGNAL u_cnt     : integer RANGE 0 TO 1023 := 0;   -- UART byte counter

  -- interrupt + reset handling
  SIGNAL irq_int   : std_logic := '0';
  SIGNAL seek_flag : std_logic := '0';   -- last int was a seek/recal/reset
  SIGNAL rst_poll  : integer RANGE 0 TO 4 := 0;
  SIGNAL dor_rst_prev : std_logic := '0';

  -- DMA control
  SIGNAL nodma     : std_logic := '0';   -- ND bit from Specify (0 = DMA)
  SIGNAL dack_prev : std_logic := '0';
  SIGNAL dma_tc    : std_logic := '0';
  SIGNAL dreq_r    : std_logic := '0';

  ----------------------------------------------------------------------------
  -- MSR fields
  ----------------------------------------------------------------------------
  SIGNAL msr : std_logic_vector(7 DOWNTO 0);
  -- bit7 RQM, bit6 DIO(1=to CPU), bit5 NDM(exec non-dma), bit4 CB(busy)

BEGIN

  ----------------------------------------------------------------------------
  -- Address decode (0x3F2/4/5/7)
  ----------------------------------------------------------------------------
  sel_dor  <= '1' WHEN ADDR = x"03F2" ELSE '0';
  sel_msr  <= '1' WHEN ADDR = x"03F4" ELSE '0';
  sel_data <= '1' WHEN ADDR = x"03F5" ELSE '0';
  sel_dir  <= '1' WHEN ADDR = x"03F7" ELSE '0';
  sel_ccr  <= '1' WHEN ADDR = x"03F7" ELSE '0';

  rd_done <= '1' WHEN (rd_prev = '0' AND RD = '1') ELSE '0';
  wr_done <= '1' WHEN (wr_prev = '0' AND WR = '1') ELSE '0';

  ----------------------------------------------------------------------------
  -- MSR (combinational from state)
  ----------------------------------------------------------------------------
  PROCESS (st, irq_int)
  BEGIN
    CASE st IS
      WHEN ST_IDLE     => msr <= "10000000";  -- RQM, accept command
      WHEN ST_PARAMS   => msr <= "10010000";  -- RQM, CB, expect params
      WHEN ST_RD_XFER  => msr <= "11110000";  -- RQM, DIO->CPU, NDM, CB
      WHEN ST_WR_XFER  => msr <= "10110000";  -- RQM, NDM, CB
      WHEN ST_RESULT   => msr <= "11010000";  -- RQM, DIO->CPU, CB
      WHEN OTHERS      => msr <= "00010000";  -- CB only (busy / DMA exec / UART)
    END CASE;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- Read data path
  ----------------------------------------------------------------------------
  PROCESS (sel_msr, sel_data, sel_dir, RD, msr, st, buf_dout, res, ridx)
  BEGIN
    IF (RD = '0' AND sel_msr = '1') THEN
      DATAOUT <= msr;
    ELSIF (RD = '0' AND sel_data = '1') THEN
      IF st = ST_RESULT THEN
        DATAOUT <= res(ridx);
      ELSE
        DATAOUT <= buf_dout;          -- read execution phase (non-DMA)
      END IF;
    ELSIF (RD = '0' AND sel_dir = '1') THEN
      DATAOUT <= x"00";               -- no disk-change
    ELSE
      DATAOUT <= "ZZZZZZZZ";
    END IF;
  END PROCESS;

  DRQ      <= dreq_r;
  DMA_DOUT <= buf_dout;               -- byte presented to memory during DMA read
  IRQ      <= irq_int AND dor(3);     -- DOR bit3 enables IRQ/DMA gate

  ----------------------------------------------------------------------------
  -- UART transmitter
  ----------------------------------------------------------------------------
  UART_TX <= tx_out;
  PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      IF RESET = '1' THEN
        tx_busy <= '0'; tx_out <= '1'; tx_cnt <= 0; tx_div <= 0;
      ELSIF tx_busy = '0' THEN
        tx_out <= '1';
        IF tx_start = '1' THEN
          tx_shift <= '1' & tx_data & '0';   -- [0]=start, [1..8]=data, [9]=stop
          tx_cnt   <= 10;
          tx_div   <= BAUD_DIV - 1;
          tx_busy  <= '1';
          tx_out   <= '0';                    -- start bit
        END IF;
      ELSE
        IF tx_div = 0 THEN
          tx_div <= BAUD_DIV - 1;
          IF tx_cnt = 1 THEN
            tx_busy <= '0';
            tx_out  <= '1';
          ELSE
            tx_shift <= '1' & tx_shift(9 DOWNTO 1);
            tx_out   <= tx_shift(1);
            tx_cnt   <= tx_cnt - 1;
          END IF;
        ELSE
          tx_div <= tx_div - 1;
        END IF;
      END IF;
    END IF;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- UART receiver
  ----------------------------------------------------------------------------
  PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      IF RESET = '1' THEN
        rx_busy <= '0'; rx_valid <= '0'; rx_sync <= "11";
      ELSE
        rx_sync  <= rx_sync(0) & UART_RX;
        rx_valid <= '0';
        IF rx_busy = '0' THEN
          IF rx_sync(1) = '0' THEN              -- start bit
            rx_busy <= '1';
            rx_div  <= BAUD_DIV/2 - 1;
            rx_cnt  <= 0;
          END IF;
        ELSE
          IF rx_div = 0 THEN
            rx_div <= BAUD_DIV - 1;
            IF rx_cnt = 0 THEN
              rx_cnt <= 1;                       -- mid start bit
            ELSIF rx_cnt <= 8 THEN
              rx_shift <= rx_sync(1) & rx_shift(7 DOWNTO 1);  -- LSB first
              rx_cnt   <= rx_cnt + 1;
            ELSE
              rx_data  <= rx_shift;              -- stop bit -> latch
              rx_valid <= '1';
              rx_busy  <= '0';
            END IF;
          ELSE
            rx_div <= rx_div - 1;
          END IF;
        END IF;
      END IF;
    END IF;
  END PROCESS;

  ----------------------------------------------------------------------------
  -- Main controller
  ----------------------------------------------------------------------------
  PROCESS (CLK)
    VARIABLE op : std_logic_vector(4 DOWNTO 0);
  BEGIN
    IF rising_edge(CLK) THEN
      IF RESET = '1' THEN
        st <= ST_IDLE; dor <= (OTHERS => '0');
        rd_prev <= '1'; wr_prev <= '1';
        irq_int <= '0'; seek_flag <= '0'; rst_poll <= 0; dor_rst_prev <= '0';
        pcn <= (OTHERS => '0'); buf_idx <= 0; u_cnt <= 0;
        tx_start <= '0';
        nodma <= '0'; dack_prev <= '0'; dma_tc <= '0'; dreq_r <= '0';
      ELSE
        rd_prev   <= RD;
        wr_prev   <= WR;
        dack_prev <= DACK;
        tx_start  <= '0';
        dreq_r    <= '0';                     -- default: no DMA request
        buf_dout  <= sbuf(buf_idx MOD 512);   -- registered buffer read

        --------------------------------------------------------------------
        -- DOR writes: motor/drive/reset/irq-enable. Reset edge -> poll ints.
        --------------------------------------------------------------------
        IF (wr_done = '1' AND sel_dor = '1') THEN
          dor <= DATAIN;
          IF (dor_rst_prev = '0' AND DATAIN(2) = '1') THEN
            -- /RESET de-asserted: controller comes ready, polls 4 drives
            st        <= ST_IDLE;
            irq_int   <= '1';
            seek_flag <= '1';
            rst_poll  <= 4;
            pcn       <= (OTHERS => '0');
          END IF;
          dor_rst_prev <= DATAIN(2);
        END IF;

        --------------------------------------------------------------------
        CASE st IS

          ----------------------------------------------------------------
          WHEN ST_IDLE =>
            IF (wr_done = '1' AND sel_data = '1') THEN
              cmd  <= DATAIN;
              pidx <= 0;
              op   := DATAIN(4 DOWNTO 0);
              CASE op IS
                WHEN "00011" => nparams <= 2;  -- Specify
                WHEN "00100" => nparams <= 1;  -- Sense Drive Status
                WHEN "00101" => nparams <= 8;  -- Write Data
                WHEN "00110" => nparams <= 8;  -- Read Data
                WHEN "00111" => nparams <= 1;  -- Recalibrate
                WHEN "01000" => nparams <= 0;  -- Sense Interrupt Status
                WHEN "01010" => nparams <= 1;  -- Read ID
                WHEN "01111" => nparams <= 2;  -- Seek
                WHEN OTHERS  => nparams <= 0;  -- invalid
              END CASE;
              IF op = "01000" THEN
                st <= ST_DISPATCH;             -- Sense Int has no params
              ELSIF (op = "00011" OR op = "00100" OR op = "00101" OR
                     op = "00110" OR op = "00111" OR op = "01010" OR
                     op = "01111") THEN
                st <= ST_PARAMS;
              ELSE
                st <= ST_DISPATCH;             -- invalid -> straight to result
              END IF;
            END IF;

          ----------------------------------------------------------------
          WHEN ST_PARAMS =>
            IF (wr_done = '1' AND sel_data = '1') THEN
              params(pidx) <= DATAIN;
              IF pidx + 1 >= nparams THEN
                st <= ST_DISPATCH;
              ELSE
                pidx <= pidx + 1;
              END IF;
            END IF;

          ----------------------------------------------------------------
          WHEN ST_DISPATCH =>
            op := cmd(4 DOWNTO 0);
            irq_int <= '0';
            CASE op IS

              WHEN "00011" =>                      -- Specify: no result, no int
                nodma <= params(1)(0);             -- capture ND bit (0=DMA)
                st <= ST_IDLE;

              WHEN "00100" =>                      -- Sense Drive Status -> ST3
                res(0) <= "00101000" OR ("000000" & params(0)(1 DOWNTO 0));
                nresults <= 1; ridx <= 0;
                st <= ST_RESULT;

              WHEN "01000" =>                      -- Sense Interrupt Status
                IF rst_poll > 0 THEN
                  res(0) <= x"C0" OR ("000000" & conv_std_logic_vector(4 - rst_poll, 2));
                  res(1) <= (OTHERS => '0');
                  rst_poll <= rst_poll - 1;
                  IF rst_poll = 1 THEN irq_int <= '0'; ELSE irq_int <= '1'; END IF;
                ELSIF seek_flag = '1' THEN
                  res(0) <= x"20" OR ("000000" & drive_sel);  -- seek end
                  res(1) <= pcn;
                  seek_flag <= '0';
                ELSE
                  res(0) <= x"80";                 -- invalid: no int pending
                  res(1) <= pcn;
                END IF;
                nresults <= 2; ridx <= 0;
                st <= ST_RESULT;

              WHEN "00111" =>                      -- Recalibrate
                drive_sel <= params(0)(1 DOWNTO 0);
                pcn <= (OTHERS => '0');
                seek_flag <= '1';
                st <= ST_SEEKDONE;

              WHEN "01111" =>                      -- Seek
                drive_sel <= params(0)(1 DOWNTO 0);
                pcn <= params(1);
                seek_flag <= '1';
                st <= ST_SEEKDONE;

              WHEN "01010" =>                      -- Read ID -> result like a read
                drive_sel <= params(0)(1 DOWNTO 0);
                res(0) <= "00000" & params(0)(2) & params(0)(1 DOWNTO 0); -- ST0
                res(1) <= (OTHERS => '0');
                res(2) <= (OTHERS => '0');
                res(3) <= pcn;
                res(4) <= "0000000" & params(0)(2);
                res(5) <= x"01"; res(6) <= x"02";
                nresults <= 7; ridx <= 0;
                irq_int <= '1';
                st <= ST_RESULT;

              WHEN "00110" =>                      -- Read Data
                cur_c <= params(1); cur_h <= params(2);
                cur_r <= params(3); eot <= params(5);
                drive_sel <= params(0)(1 DOWNTO 0);
                dma_tc <= '0';
                st <= ST_RD_REQ;                   -- fetch sector via UART first

              WHEN "00101" =>                      -- Write Data
                cur_c <= params(1); cur_h <= params(2);
                cur_r <= params(3); eot <= params(5);
                drive_sel <= params(0)(1 DOWNTO 0);
                dma_tc <= '0';
                buf_idx <= 0;
                IF nodma = '1' THEN
                  st <= ST_WR_XFER;                -- collect from CPU (PIO)
                ELSE
                  st <= ST_WR_DMA;                 -- collect from memory (DMA)
                END IF;

              WHEN OTHERS =>                       -- invalid command
                res(0) <= x"80";
                nresults <= 1; ridx <= 0;
                st <= ST_RESULT;
            END CASE;

          ----------------------------------------------------------------
          WHEN ST_SEEKDONE =>
            irq_int <= '1';                        -- seek/recal complete int
            st <= ST_IDLE;

          ----------------------------------------------------------------
          -- READ: request a sector over UART
          ----------------------------------------------------------------
          WHEN ST_RD_REQ =>
            -- send 0x33 0x01 C H R, then receive 512 bytes
            IF tx_busy = '0' AND tx_start = '0' THEN
              CASE u_cnt IS
                WHEN 0 => tx_data <= PREAMBLE; tx_start <= '1'; u_cnt <= 1;
                WHEN 1 => tx_data <= HCMD_RD;  tx_start <= '1'; u_cnt <= 2;
                WHEN 2 => tx_data <= cur_c;    tx_start <= '1'; u_cnt <= 3;
                WHEN 3 => tx_data <= cur_h;    tx_start <= '1'; u_cnt <= 4;
                WHEN 4 => tx_data <= cur_r;    tx_start <= '1'; u_cnt <= 5;
                WHEN OTHERS => u_cnt <= 0; buf_idx <= 0; st <= ST_RD_RX;
              END CASE;
            END IF;

          WHEN ST_RD_RX =>
            IF rx_valid = '1' THEN
              sbuf(buf_idx) <= rx_data;
              IF buf_idx = 511 THEN
                buf_idx <= 0;
                IF nodma = '1' THEN
                  st <= ST_RD_XFER;               -- present via 0x3F5 (PIO)
                ELSE
                  st <= ST_RD_DMA;                -- push to memory (DMA)
                END IF;
              ELSE
                buf_idx <= buf_idx + 1;
              END IF;
            END IF;

          WHEN ST_RD_XFER =>
            -- present buffer byte-by-byte; CPU read advances the index
            IF (rd_done = '1' AND sel_data = '1') THEN
              IF buf_idx = 511 THEN
                st <= ST_NEXT;
              ELSE
                buf_idx <= buf_idx + 1;
              END IF;
            END IF;

          WHEN ST_RD_DMA =>
            -- 8237 pulls each byte (DMA_DOUT) into memory; one per DACK pulse
            dreq_r <= '1';
            IF (dack_prev = '1' AND DACK = '0') THEN
              IF TC = '1' THEN                    -- DMA ended the command
                dreq_r <= '0';
                res(0) <= "00000" & cur_h(0) & drive_sel;
                res(1) <= (OTHERS => '0');
                res(2) <= (OTHERS => '0');
                res(3) <= cur_c; res(4) <= cur_h;
                res(5) <= cur_r + 1; res(6) <= x"02";
                nresults <= 7; ridx <= 0;
                irq_int <= '1';
                st <= ST_RESULT;
              ELSIF buf_idx = 511 THEN            -- sector done, fetch next
                dreq_r <= '0';
                cur_r  <= cur_r + 1;
                u_cnt  <= 0; buf_idx <= 0;
                st <= ST_RD_REQ;
              ELSE
                buf_idx <= buf_idx + 1;
              END IF;
            END IF;

          ----------------------------------------------------------------
          -- WRITE (PIO): collect 512 from CPU, then ship over UART
          ----------------------------------------------------------------
          WHEN ST_WR_XFER =>
            IF (wr_done = '1' AND sel_data = '1') THEN
              sbuf(buf_idx) <= DATAIN;
              IF buf_idx = 511 THEN
                buf_idx <= 0; u_cnt <= 0;
                st <= ST_WR_REQ;
              ELSE
                buf_idx <= buf_idx + 1;
              END IF;
            END IF;

          ----------------------------------------------------------------
          -- WRITE (DMA): collect 512 from memory, then ship over UART
          ----------------------------------------------------------------
          WHEN ST_WR_DMA =>
            dreq_r <= '1';
            IF (dack_prev = '1' AND DACK = '0') THEN
              sbuf(buf_idx) <= DMA_DIN;           -- latch byte read from memory
              IF TC = '1' THEN
                dma_tc <= '1';
                dreq_r <= '0';
                buf_idx <= 0; u_cnt <= 0;
                st <= ST_WR_REQ;                  -- ship final sector
              ELSIF buf_idx = 511 THEN
                dreq_r <= '0';
                buf_idx <= 0; u_cnt <= 0;
                st <= ST_WR_REQ;                  -- ship full sector, more to come
              ELSE
                buf_idx <= buf_idx + 1;
              END IF;
            END IF;

          WHEN ST_WR_REQ =>
            IF tx_busy = '0' AND tx_start = '0' THEN
              CASE u_cnt IS
                WHEN 0 => tx_data <= PREAMBLE; tx_start <= '1'; u_cnt <= 1;
                WHEN 1 => tx_data <= HCMD_WR;  tx_start <= '1'; u_cnt <= 2;
                WHEN 2 => tx_data <= cur_c;    tx_start <= '1'; u_cnt <= 3;
                WHEN 3 => tx_data <= cur_h;    tx_start <= '1'; u_cnt <= 4;
                WHEN 4 => tx_data <= cur_r;    tx_start <= '1'; u_cnt <= 5;
                WHEN OTHERS => u_cnt <= 0; buf_idx <= 0; st <= ST_WR_DATA;
              END CASE;
            END IF;

          WHEN ST_WR_DATA =>
            IF tx_busy = '0' AND tx_start = '0' THEN
              tx_data  <= buf_dout;     -- buf_dout already tracks buf_idx
              tx_start <= '1';
              IF buf_idx = 511 THEN
                st <= ST_WR_ACK;
              ELSE
                buf_idx <= buf_idx + 1;
              END IF;
            END IF;

          WHEN ST_WR_ACK =>
            IF rx_valid = '1' THEN     -- WRITE OK
              IF nodma = '1' THEN
                st <= ST_NEXT;                     -- PIO: walk R..EOT
              ELSE
                IF dma_tc = '1' THEN               -- DMA ended -> result
                  res(0) <= "00000" & cur_h(0) & drive_sel;
                  res(1) <= (OTHERS => '0');
                  res(2) <= (OTHERS => '0');
                  res(3) <= cur_c; res(4) <= cur_h;
                  res(5) <= cur_r + 1; res(6) <= x"02";
                  nresults <= 7; ridx <= 0;
                  irq_int <= '1';
                  st <= ST_RESULT;
                ELSE                               -- next sector via DMA
                  cur_r  <= cur_r + 1;
                  buf_idx <= 0;
                  st <= ST_WR_DMA;
                END IF;
              END IF;
            END IF;

          ----------------------------------------------------------------
          -- advance within track (R..EOT) or finish into result phase (PIO)
          ----------------------------------------------------------------
          WHEN ST_NEXT =>
            IF cur_r >= eot THEN
              -- build read/write result (ST0,ST1,ST2,C,H,R,N)
              res(0) <= "00000" & cur_h(0) & drive_sel;     -- ST0 normal term
              res(1) <= (OTHERS => '0');
              res(2) <= (OTHERS => '0');
              res(3) <= cur_c;
              res(4) <= cur_h;
              res(5) <= cur_r + 1;
              res(6) <= x"02";
              nresults <= 7; ridx <= 0;
              irq_int <= '1';
              st <= ST_RESULT;
            ELSE
              cur_r <= cur_r + 1;
              u_cnt <= 0; buf_idx <= 0;
              IF cmd(4 DOWNTO 0) = "00110" THEN
                st <= ST_RD_REQ;
              ELSE
                st <= ST_WR_XFER;
              END IF;
            END IF;

          ----------------------------------------------------------------
          WHEN ST_RESULT =>
            IF (rd_done = '1' AND sel_data = '1') THEN
              irq_int <= '0';
              IF ridx + 1 >= nresults THEN
                st <= ST_IDLE;
              ELSE
                ridx <= ridx + 1;
              END IF;
            END IF;

        END CASE;
      END IF;
    END IF;
  END PROCESS;

END;