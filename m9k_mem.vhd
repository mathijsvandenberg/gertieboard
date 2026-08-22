--------------------------------------------------------------------------------
-- m9k_mem.vhd  --  reliable on-chip M9K RAM for the hybrid map
--
-- Backs two disjoint windows:
--   0x00000..0x07FFF  -- 32 KB low RAM: IVT, BDA, stack, trampoline scratch
--   0xE0000..0xE0FFF  --  4 KB fixed-disk block buffer
-- The BIOS lives in the PSRAM-backed F-segment (full 64 KB, no mirror), so this
-- block never touches 0xF0000+. 36 M9K blocks total.
--
-- The 4 KB window exists so the fixed-disk read-modify-write buffer costs no
-- conventional memory. It used to sit at 0x9E000, which forced the BIOS to
-- report 632 KB instead of 640 KB; up here DOS never sees it and the full
-- 640 KB is given back. See tools/xtbios_src.s (HDBUF_SEG) and docs/fixed-disk.md.
--
-- 0xE0000 is not an arbitrary choice. busdecode's MEMADDR is true for
-- ADDR < 0xA0000 OR ADDR >= 0xE0000, so a window here is treated as a real
-- memory cycle and the CPU waits on RAM_READY. Anywhere in 0xA0000..0xDFFFF
-- the READY handshake would be bypassed by the T >= 3 clause and the CPU could
-- sample the bus before this block drives it. Do not move the window down
-- without also widening MEMADDR.
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  work.memmap.ALL;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;

ENTITY m9k_mem IS
  PORT(
        CLK_RAM : IN    std_logic;
        RESET   : IN    std_logic;
        DATAIN  : IN    std_logic_vector(7  DOWNTO 0);
        ADDR    : IN    std_logic_vector(19 DOWNTO 0);
        RD      : IN    std_logic;                          -- /MEMR (active LOW)
        WR      : IN    std_logic;                          -- /MEMW (active LOW)
        DATAOUT : INOUT std_logic_vector(7  DOWNTO 0);
        READY   : OUT   std_logic);
END m9k_mem;

ARCHITECTURE m9k OF m9k_mem IS

  -- The BIOS image, not low RAM. Conventional memory is now uniformly PSRAM
  -- (see mem_hybrid) so that the 640 KB has ONE speed; M9K is spent instead on
  -- the code that runs on every interrupt.
  CONSTANT BIOS_DEPTH : integer := 16#6000#;  -- 24 KB BIOS image     0xFA000..0xFFFFF
  CONSTANT BUF_DEPTH  : integer := 16#1000#;  -- 4 KB disk buffer     0xE0000..0xE0FFF
  CONSTANT DEPTH      : integer := BIOS_DEPTH + BUF_DEPTH;

  TYPE mem_t IS ARRAY(0 TO DEPTH-1) OF std_logic_vector(7 DOWNTO 0);
  SIGNAL mem : mem_t;

  SIGNAL in_bios : std_logic;
  SIGNAL in_buf  : std_logic;
  SIGNAL in_win  : std_logic;
  SIGNAL in_win_q : std_logic := '0';   -- registered, for the READY path only
  SIGNAL midx    : integer RANGE 0 TO DEPTH-1;
  SIGNAL cpu_rd  : std_logic;
  SIGNAL cpu_wr  : std_logic;
  SIGNAL cpu_op  : std_logic;
  SIGNAL dout    : std_logic_vector(7 DOWNTO 0) := (OTHERS => '0');
  SIGNAL we      : std_logic := '0';

  TYPE st_t IS (M_IDLE, M_WAIT, M_DONE);
  SIGNAL st        : st_t := M_IDLE;
  SIGNAL ready_int : std_logic := '1';

BEGIN

  in_bios <= owned_by_bios(ADDR);
  in_buf  <= owned_by_diskbuf(ADDR);
  in_win  <= in_bios OR in_buf;

  -- The BIOS maps 1:1 from 0xF8000; the 4 KB buffer is packed above it.
  -- FIFTEEN address bits now, not fourteen: a 32 KB window needs 0..0x7FFF,
  -- and leaving this at 13 DOWNTO 0 would have mirrored the top half of the
  -- BIOS onto the bottom -- the machine would boot, because the reset vector
  -- and everything near it live in the top 16 KB, and then fail somewhere in
  -- the newly added code with no clue as to why.
  midx   <= conv_integer(ADDR(14 DOWNTO 0)) WHEN in_bios = '1'
       ELSE BIOS_DEPTH + conv_integer(ADDR(11 DOWNTO 0));

  -- THE ADDRESS DECODE IS REGISTERED, AND THAT IS A TIMING FIX.
  --
  -- ownership is a 20-bit range decode, and it fed cpu_op, which feeds READY,
  -- which is CPU_RDY -- the tightest external path on the board at 10.35 ns.
  -- mem_hybrid's own comment describes removing exactly this decode from the
  -- READY path; it removed it one level up and left it here, where it does
  -- the same damage. Every build was landing between +0.1 and -0.6 ns
  -- depending on where the fitter happened to put these gates, which is not a
  -- margin, it is a coin toss.
  --
  -- Registering it is free because the address is LATCHED at ALE and holds for
  -- the whole bus cycle, while RD/WR do not assert until the following
  -- T-state -- roughly 100 ns later at 10 MHz against one 20 ns clock of
  -- pipeline. So the registered copy is settled long before anything asks.
  -- Same argument, and same wording, as busdecode's memaddr_q.
  --
  -- Only the READY path uses the registered copy. The RAM's own write guard
  -- keeps the live decode, because by the time a write fires the access has
  -- already been accepted and the two agree.
  cpu_rd <= in_win_q AND (NOT RD);
  cpu_wr <= in_win_q AND (NOT WR);
  cpu_op <= cpu_rd OR cpu_wr;

  DATAOUT <= dout WHEN cpu_rd = '1' ELSE "ZZZZZZZZ";
  READY   <= '0'  WHEN (cpu_op = '1' AND st = M_IDLE) ELSE ready_int;

  PROCESS (CLK_RAM)
  BEGIN
    IF rising_edge(CLK_RAM) THEN
      in_win_q <= in_win;
      IF (we = '1' AND in_win = '1') THEN
        mem(midx) <= DATAIN;
      END IF;
      dout <= mem(midx);
    END IF;
  END PROCESS;

  PROCESS (CLK_RAM, RESET)
  BEGIN
    IF RESET = '1' THEN
      st <= M_IDLE; ready_int <= '1'; we <= '0';
    ELSIF rising_edge(CLK_RAM) THEN
      we <= '0';
      CASE st IS
        WHEN M_IDLE =>
          ready_int <= '1';
          IF cpu_wr = '1' THEN we <= '1'; ready_int <= '0'; st <= M_WAIT;
          ELSIF cpu_rd = '1' THEN ready_int <= '0'; st <= M_WAIT; END IF;
        WHEN M_WAIT =>
          ready_int <= '1'; st <= M_DONE;
        WHEN M_DONE =>
          ready_int <= '1';
          IF RD = '1' AND WR = '1' THEN st <= M_IDLE; END IF;
      END CASE;
    END IF;
  END PROCESS;

END m9k;
