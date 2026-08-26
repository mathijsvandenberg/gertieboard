------------------------------------------------------------------------------
-- gertieboard.vhdl  --  structural top level (converted from gertieboard.bdf)
--
-- 1:1 translation of the former schematic top level: same component
-- instances, same net connectivity, same pin names. Buses connect whole
-- (no bit-ripping in the original); bit splitting happens inside modules.
--
-- Faithful to the schematic, including its quirks:
--   * DBG(7..2) are undriven (were 'stuck at GND')
--   * a second PLL (pll2) is instantiated but its outputs are unused
------------------------------------------------------------------------------
LIBRARY IEEE;
USE IEEE.STD_LOGIC_1164.ALL;

ENTITY gertieboard IS
  PORT(
    CPU_A          : IN    std_logic_vector(19 downto 8);
    CPU_RD         : IN    std_logic;
    CPU_WR         : IN    std_logic;
    CPU_INTA       : IN    std_logic;
    CPU_HLDA       : IN    std_logic;
    CPU_ALE        : IN    std_logic;
    CPU_DEN        : IN    std_logic;
    CPU_DTR        : IN    std_logic;
    CPU_IOM        : IN    std_logic;
    CLOCK50        : IN    std_logic;
    RESET          : IN    std_logic;
    UART_RXD       : IN    std_logic;
    FL_MISO        : IN    std_logic;
    PS2DAT         : IN    std_logic;
    PS2CLK         : IN    std_logic;
    CPU_CLK        : OUT   std_logic;
    CPU_RST        : OUT   std_logic;
    CPU_NMI        : OUT   std_logic;
    CPU_INTR       : OUT   std_logic;
    CPU_HLD        : OUT   std_logic;
    VGA_HS         : OUT   std_logic;
    VGA_VS         : OUT   std_logic;
    VGA_RGB        : OUT   std_logic_vector(5 downto 0);
    BUZ            : OUT   std_logic;
    CPU_RDY        : OUT   std_logic;
    UART_TXD       : OUT   std_logic;
    FL_MOSI        : OUT   std_logic;
    FL_CS          : OUT   std_logic;
    FL_SCK         : OUT   std_logic;
    SEG_A          : OUT   std_logic;
    SEG_B          : OUT   std_logic;
    SEG_C          : OUT   std_logic;
    SEG_D          : OUT   std_logic;
    SEG_E          : OUT   std_logic;
    SEG_F          : OUT   std_logic;
    SEG_G          : OUT   std_logic;
    RAM_SCK        : OUT   std_logic;
    RAM_CS         : OUT   std_logic;
    CPU_AD         : INOUT std_logic_vector(7 downto 0);
    USB0_DP        : INOUT std_logic;
    USB0_DM        : INOUT std_logic;
    USB1_DP        : INOUT std_logic;
    USB1_DM        : INOUT std_logic;
    RAM_SIO        : INOUT std_logic_vector(3 downto 0);
    -- DE0-Nano SDRAM, 32 MB. Dedicated pins, not the GPIO headers.
    DRAM_ADDR      : OUT   std_logic_vector(12 downto 0);
    DRAM_BA        : OUT   std_logic_vector(1 downto 0);
    DRAM_DQ        : INOUT std_logic_vector(15 downto 0);
    DRAM_DQM       : OUT   std_logic_vector(1 downto 0);
    DRAM_CLK       : OUT   std_logic;
    DRAM_CKE       : OUT   std_logic;
    DRAM_CS_N      : OUT   std_logic;
    DRAM_RAS_N     : OUT   std_logic;
    DRAM_CAS_N     : OUT   std_logic;
    DRAM_WE_N      : OUT   std_logic;
    DBG            : OUT   std_logic_vector(7 downto 0)
  );
END gertieboard;

ARCHITECTURE structural OF gertieboard IS

  -- Set to '1' to silence the PC speaker without changing anything else -- handy
  -- when working at night. '0' = normal working buzzer.
  CONSTANT SPEAKER_MUTE : std_logic := '0';

  -- n_cpuclk is the CPU and I/O bus clock. It is NOT a PLL output any more:
  -- cpuclk1 divides the PLL's 100 MHz c0 down to the selected step, so the
  -- speed is a register the CPU can write. See cpuclk.vhd.
  SIGNAL n_cpuclk               : std_logic;
  -- The CPU pin's copy of the bus clock, 5 ns late on purpose. See cpuclk.vhd.
  SIGNAL n_cpuclk_pad           : std_logic;
  SIGNAL n_c100                 : std_logic;   -- pll1 c0, 100 MHz
  SIGNAL n_opl_smp              : integer RANGE 1 TO 1023;
  SIGNAL n_opl_t1               : integer RANGE 1 TO 8191;
  SIGNAL n_opl_t2               : integer RANGE 1 TO 8191;
  SIGNAL n_c1                   : std_logic;
  SIGNAL n_c2                   : std_logic;
  SIGNAL n_c3                   : std_logic;
  SIGNAL n_clk48       : std_logic;
  -- OPL2 PCM tap -> usb2's isochronous streamer, both in the 48 MHz domain
  SIGNAL n_opl_pcm     : std_logic_vector(15 DOWNTO 0);
  SIGNAL n_opl_pcm_stb : std_logic;
  SIGNAL n_aud_en      : std_logic;
  SIGNAL n_aud_addr    : std_logic_vector(6 DOWNTO 0);
  SIGNAL n_aud_endp    : std_logic_vector(3 DOWNTO 0);
  SIGNAL n_aud_nsmp    : std_logic_vector(7 DOWNTO 0);
  SIGNAL n_aud_gain    : std_logic_vector(2 DOWNTO 0);
  SIGNAL n_aud_under   : std_logic;
  SIGNAL n_usb_locked  : std_logic;
  SIGNAL n_pll_locked  : std_logic;   -- pll1 has locked; nothing runs before it
  SIGNAL n_clock50              : std_logic;
  SIGNAL n_cpu_a                : std_logic_vector(19 downto 8);
  SIGNAL n_cpu_ale              : std_logic;
  SIGNAL n_cpu_den              : std_logic;
  SIGNAL n_cpu_dtr              : std_logic;
  SIGNAL n_cpu_hlda             : std_logic;
  SIGNAL n_cpu_inta             : std_logic;
  SIGNAL n_cpu_iom              : std_logic;
  SIGNAL n_cpu_nmi              : std_logic;
  SIGNAL n_cpu_rd               : std_logic;
  SIGNAL n_cpu_wdata            : std_logic_vector(7 downto 0);
  SIGNAL n_cpu_wr               : std_logic;
  SIGNAL n_ctrl                 : std_logic_vector(7 downto 0);
  SIGNAL n_dma_addr             : std_logic_vector(15 downto 0);
  SIGNAL n_dma_dout             : std_logic_vector(7 downto 0);
  SIGNAL n_dma_memr             : std_logic;
  SIGNAL n_dma_memw             : std_logic;
  SIGNAL n_drq                  : std_logic;                     -- FDC -> ch2
  SIGNAL n_drq_v                : std_logic_vector(3 DOWNTO 0);  -- to the 8237
  SIGNAL n_dack_v               : std_logic_vector(3 DOWNTO 0);  -- from the 8237
  SIGNAL n_sb_drq               : std_logic;                     -- SB DSP -> ch1
  SIGNAL n_dma_iow              : std_logic;                     -- 8237 /IOW to devices
  SIGNAL n_dma_ch               : std_logic_vector(1 downto 0);  -- channel owning the bus
  SIGNAL n_sb_irq               : std_logic;                     -- SB DSP -> IR5
  SIGNAL n_sb_pcm               : std_logic_vector(15 DOWNTO 0); -- FM + DAC
  SIGNAL n_sb_pcm_stb           : std_logic;
  SIGNAL n_fl_cs                : std_logic;
  SIGNAL n_fl_do                : std_logic;
  SIGNAL n_fl_miso              : std_logic;
  SIGNAL n_fl_sck               : std_logic;
  SIGNAL n_g0                   : std_logic;
  SIGNAL n_hrq                  : std_logic;
  SIGNAL n_hs                   : std_logic;
  SIGNAL n_int                  : std_logic;
  SIGNAL n_io_addr              : std_logic_vector(15 downto 0);
  SIGNAL n_io_rd                : std_logic;
  SIGNAL n_io_wr                : std_logic;
  SIGNAL n_iochk_n              : std_logic;
  SIGNAL n_irq                  : std_logic;
  SIGNAL n_irq1                 : std_logic;
  SIGNAL n_cad_rst              : std_logic;   -- Ctrl+Alt+Del from the keyboard
  SIGNAL n_irq2                 : std_logic;
  SIGNAL n_kbd_clear            : std_logic;
  SIGNAL n_mem_addr             : std_logic_vector(19 downto 0);
  SIGNAL n_mem_ready            : std_logic;   -- PSRAM init done; gates CPU reset
  SIGNAL n_mem_rst              : std_logic;   -- active-HIGH, ungated, for mem_hybrid
  SIGNAL n_mem_rd               : std_logic;
  SIGNAL n_mem_wr               : std_logic;
  SIGNAL n_cur_addr             : std_logic_vector(13 downto 0);  -- CRTC R14/R15
  SIGNAL n_cur_top              : std_logic_vector(4 downto 0);   -- CRTC R10(4:0)
  SIGNAL n_cur_bot              : std_logic_vector(4 downto 0);   -- CRTC R11(4:0)
  SIGNAL n_cur_mod              : std_logic_vector(1 downto 0);   -- CRTC R10(6:5)
  SIGNAL n_opl_snd              : std_logic;   -- AdLib PWM, mixed into BUZ
  SIGNAL n_out0                 : std_logic;
  SIGNAL n_out2                 : std_logic;
  SIGNAL n_pa_data              : std_logic_vector(7 downto 0);
  SIGNAL n_periph_rdata         : std_logic_vector(7 downto 0);
  SIGNAL n_ps2clk               : std_logic;
  SIGNAL n_ps2dat               : std_logic;
  SIGNAL n_ram_cs               : std_logic;
  SIGNAL n_ram_sck              : std_logic;
  SIGNAL n_ready                : std_logic;
  SIGNAL n_ready_1              : std_logic;
  SIGNAL n_reset                : std_logic;
  SIGNAL n_rgb                  : std_logic_vector(5 downto 0);
  SIGNAL n_rom_data             : std_logic_vector(7 downto 0);
  SIGNAL n_rom_en               : std_logic;
  SIGNAL n_rst_out              : std_logic;
  SIGNAL n_seg_a                : std_logic;
  SIGNAL n_seg_b                : std_logic;
  SIGNAL n_seg_c                : std_logic;
  SIGNAL n_seg_d                : std_logic;
  SIGNAL n_seg_e                : std_logic;
  SIGNAL n_seg_f                : std_logic;
  SIGNAL n_seg_g                : std_logic;
  SIGNAL n_speaker_data         : std_logic;
  SIGNAL n_tc                   : std_logic;
  SIGNAL n_timer2_gate          : std_logic;
  SIGNAL n_uart_rxd             : std_logic;
  SIGNAL n_uart_tx              : std_logic;
  SIGNAL n_vs                   : std_logic;
  -- EGA register file -> vga
  SIGNAL n_ega_on               : std_logic;
  SIGNAL n_crtc_start           : std_logic_vector(15 downto 0); -- CRTC R12/R13
  SIGNAL n_crtc_offs            : std_logic_vector(7 downto 0);  -- CRTC R19 (0x13)
  SIGNAL n_map_mask             : std_logic_vector(3 downto 0);
  SIGNAL n_set_res              : std_logic_vector(3 downto 0);
  SIGNAL n_en_sr                : std_logic_vector(3 downto 0);
  SIGNAL n_rotate               : std_logic_vector(2 downto 0);
  SIGNAL n_func_sel             : std_logic_vector(1 downto 0);
  SIGNAL n_rd_map               : std_logic_vector(1 downto 0);
  SIGNAL n_wr_mode              : std_logic_vector(1 downto 0);
  SIGNAL n_bit_mask             : std_logic_vector(7 downto 0);
  SIGNAL n_palette              : std_logic_vector(95 downto 0);
  SIGNAL n_dispen               : std_logic;
  SIGNAL n_vret                 : std_logic;
  -- SDRAM client interface
  SIGNAL n_sd_req               : std_logic;
  SIGNAL n_sd_we                : std_logic;
  SIGNAL n_sd_addr              : std_logic_vector(23 downto 0);
  SIGNAL n_sd_din               : std_logic_vector(15 downto 0);
  SIGNAL n_sd_dout              : std_logic_vector(15 downto 0);
  SIGNAL n_sd_be                : std_logic_vector(1 downto 0);
  SIGNAL n_sd_ack               : std_logic;
  SIGNAL n_sd_init              : std_logic;
  SIGNAL n_sd_state             : std_logic_vector(3 downto 0);
  -- mem_hybrid's conventional memory <-> sdram_arb client 2
  SIGNAL n_cr_req               : std_logic;
  SIGNAL n_cr_lock              : std_logic;
  SIGNAL n_cr_we                : std_logic;
  SIGNAL n_cr_a                 : std_logic_vector(23 downto 0);
  SIGNAL n_cr_d                 : std_logic_vector(15 downto 0);
  SIGNAL n_cr_be                : std_logic_vector(1 downto 0);
  SIGNAL n_cr_ack               : std_logic;
  -- ega_mem <-> vga
  SIGNAL n_em_req               : std_logic;
  SIGNAL n_em_we                : std_logic;
  SIGNAL n_em_offs              : std_logic_vector(15 downto 0);
  SIGNAL n_em_wdata             : std_logic_vector(31 downto 0);
  SIGNAL n_em_wmask             : std_logic_vector(3 downto 0);
  SIGNAL n_em_rdata             : std_logic_vector(31 downto 0);
  SIGNAL n_em_ready             : std_logic;
  SIGNAL n_em_row_go            : std_logic;
  SIGNAL n_em_row_offs          : std_logic_vector(15 downto 0);
  SIGNAL n_em_col               : std_logic_vector(5 downto 0);
  SIGNAL n_em_scan              : std_logic_vector(31 downto 0);
  SIGNAL n_ega_claim            : std_logic;
  SIGNAL n_ega_rdy              : std_logic;
  -- SDRAM, arbitrated between ega_mem (client 0) and the test window
  SIGNAL n_ready_mem            : std_logic;
  SIGNAL n_e_req, n_e_we, n_e_ack : std_logic;
  SIGNAL n_e_a                  : std_logic_vector(23 downto 0);
  SIGNAL n_e_d                  : std_logic_vector(15 downto 0);
  SIGNAL n_e_be                 : std_logic_vector(1 downto 0);
  SIGNAL n_ega_sd_req, n_ega_sd_we, n_ega_sd_ack, n_ega_sd_lock : std_logic;
  SIGNAL n_ega_sd_a             : std_logic_vector(23 downto 0);
  SIGNAL n_ega_sd_d             : std_logic_vector(15 downto 0);
  SIGNAL n_ega_sd_be            : std_logic_vector(1 downto 0);
BEGIN

  vga1 : ENTITY work.vga
    PORT MAP (
      CLK_VGA              => n_c1,
      CLK_CPU              => n_cpuclk,
      RESET                => n_rst_out,
      WR                   => n_mem_wr,
      RD                   => n_mem_rd,
      ADDR                 => n_mem_addr,
      DATAIN               => n_cpu_wdata,
      IOWR                 => n_io_wr,
      IOADDR               => n_io_addr,
      CURSOR               => n_cur_addr,
      CUR_TOP              => n_cur_top,
      CUR_BOT              => n_cur_bot,
      CUR_MOD              => n_cur_mod,
      EGA_ON               => n_ega_on,
      EGA_START            => n_crtc_start,
      EGA_OFFS             => n_crtc_offs,
      MAP_MASK             => n_map_mask,
      SET_RES              => n_set_res,
      EN_SR                => n_en_sr,
      ROTATE               => n_rotate,
      FUNC_SEL             => n_func_sel,
      RD_MAP               => n_rd_map,
      WR_MODE              => n_wr_mode,
      BIT_MASK             => n_bit_mask,
      PALETTE              => n_palette,
      EM_REQ               => n_em_req,
      EM_WE                => n_em_we,
      EM_OFFS              => n_em_offs,
      EM_WDATA             => n_em_wdata,
      EM_WMASK             => n_em_wmask,
      EM_RDATA             => n_em_rdata,
      EM_READY             => n_em_ready,
      EM_ROW_GO            => n_em_row_go,
      EM_ROW_OFFS          => n_em_row_offs,
      EM_COL               => n_em_col,
      EM_SCAN              => n_em_scan,
      EGA_CLAIM            => n_ega_claim,
      EGA_RDY              => n_ega_rdy,
      HS                   => n_hs,
      VS                   => n_vs,
      DISPEN               => n_dispen,
      VRET                 => n_vret,
      RGB                  => n_rgb,
      DEBUG                => OPEN,
      DATAOUT              => n_periph_rdata
    );

  clkgen1 : ENTITY work.clkgen
    PORT MAP (
      CLK                  => n_cpuclk,
      RESET                => n_reset,
      MEM_READY            => n_mem_ready,
      RST_OUT              => n_rst_out
    );

  flash1 : ENTITY work.flash
    PORT MAP (
      CLK                  => n_cpuclk,
      DATAIN               => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      FL_DI                => n_fl_miso,
      DATAOUT              => n_periph_rdata,
      FL_SCK               => n_fl_sck,
      FL_CS                => n_fl_cs,
      FL_DO                => n_fl_do
    );

  ppi1 : ENTITY work.ppi8255
    PORT MAP (
      CLK                  => n_cpuclk,
      RESET                => n_rst_out,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      KBD_DATA             => n_pa_data,
      TIMER2_OUT           => n_out2,
      IOCHK_N              => n_iochk_n,
      PARITY_ERR_N         => n_iochk_n,
      DATA_OUT             => n_periph_rdata,
      TIMER2_GATE          => n_timer2_gate,
      SPEAKER_DATA         => n_speaker_data,
      ENABLE_PARITY_N      => OPEN,
      ENABLE_IOCHK_N       => OPEN,
      KBD_CLOCK_HOLD       => OPEN,
      KBD_CLEAR            => n_kbd_clear
    );

  -- CLK is the BUS clock so the register interface can see an I/O cycle;
  -- CNT_TICK carries the 1.1905 MHz counting rate. Driving CLK from c2, as
  -- this did, left the PIT sampling strobes on an 840 ns clock.
  timer1 : ENTITY work.timer8253
    PORT MAP (
      CLK                  => n_cpuclk,
      CNT_TICK             => n_c2,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      G0                   => n_g0,
      G1                   => n_g0,
      G2                   => n_timer2_gate,
      DATA_OUT             => n_periph_rdata,
      OUT0                 => n_out0,
      OUT1                 => OPEN,
      OUT2                 => n_out2
    );

  sevenseg1 : ENTITY work.sevenseg
    PORT MAP (
      CLK                  => n_cpuclk,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      WR                   => n_io_wr,
      SEG_A                => n_seg_a,
      SEG_B                => n_seg_b,
      SEG_C                => n_seg_c,
      SEG_D                => n_seg_d,
      SEG_E                => n_seg_e,
      SEG_F                => n_seg_f,
      SEG_G                => n_seg_g
    );

  dma1 : ENTITY work.dma8237
    PORT MAP (
      CLK                  => n_cpuclk,
      RESET                => n_rst_out,
      IO_ADDR              => n_io_addr,
      IO_RD                => n_io_rd,
      IO_WR                => n_io_wr,
      DATAIN               => n_cpu_wdata,
      DREQ                 => n_drq_v,
      HLDA                 => n_cpu_hlda,
      RAM_READY            => n_ready,
      DACK                 => n_dack_v,
      HRQ                  => n_hrq,
      DMA_CH               => n_dma_ch,
      DMA_ADDR             => n_dma_addr,
      DMA_MEMR             => n_dma_memr,
      DMA_MEMW             => n_dma_memw,
      DMA_IOR              => OPEN,
      DMA_IOW              => n_dma_iow,
      TC                   => n_tc,
      DATAOUT              => n_periph_rdata
    );

  int1 : ENTITY work.int8259
    PORT MAP (
      CLK                  => n_cpuclk,
      RESET                => n_rst_out,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      INTA                 => n_cpu_inta,
      IRQ0                 => n_out0,
      IRQ1                 => n_irq1,
      IRQ2                 => n_irq2,
      IRQ5                 => n_sb_irq,
      IRQ6                 => n_irq,
      DATAOUT              => n_periph_rdata,
      INT                  => n_int
    );

  busdecode1 : ENTITY work.busdecode
    PORT MAP (
      CLK                  => n_cpuclk,
      DMA_CH               => n_dma_ch,
      A                    => n_cpu_a,
      RD                   => n_cpu_rd,
      WR                   => n_cpu_wr,
      ALE                  => n_cpu_ale,
      DEN                  => n_cpu_den,
      DTR                  => n_cpu_dtr,
      IOM                  => n_cpu_iom,
      RAM_READY            => n_ready,
      EGA_CLAIM            => n_ega_claim,
      DATA_IN              => n_periph_rdata,
      HLDA                 => n_cpu_hlda,
      DMA_ADDR             => n_dma_addr,
      DMA_MEMR             => n_dma_memr,
      DMA_MEMW             => n_dma_memw,
      DMA_DOUT             => n_dma_dout,
      ROM_EN               => n_rom_en,
      ROM_DATA             => n_rom_data,
      DATA_OUT             => n_cpu_wdata,
      IO_ADDR              => n_io_addr,
      IO_RD                => n_io_rd,
      IO_WR                => n_io_wr,
      MEM_ADDR             => n_mem_addr,
      MEM_RD               => n_mem_rd,
      MEM_WR               => n_mem_wr,
      READY                => n_ready_1,
      AD                   => CPU_AD
    );

  bootrom1 : ENTITY work.bootrom
    PORT MAP (
      CLK                  => n_cpuclk,
      RESET                => n_rst_out,
      MEM_ADDR             => n_mem_addr,
      IO_ADDR              => n_io_addr,
      IO_WR                => n_io_wr,
      DATAIN               => n_cpu_wdata,
      ROM_DATA             => n_rom_data,
      ROM_EN               => n_rom_en
    );

  -- c0 is 100 MHz and is NOT the bus clock: it is the master the programmable
  -- bus clock is divided from. Half-periods of 100 MHz are what let every step
  -- of the ladder keep a 50 % duty cycle AND land every rising edge on c3's
  -- 20 ns grid -- see cpuclk.vhd for why both matter.
  pll1 : ENTITY work.pll
    PORT MAP (
      inclk0               => n_clock50,
      c0                   => n_c100,
      c1                   => n_c1,
      c2                   => n_c2,
      c3                   => n_c3,
      c4                   => OPEN,
      locked               => n_pll_locked
    );

  -- The machine's speed. Writes to I/O 0xE5 pick a step; RESET_N is the RAW
  -- reset (like mem_hybrid's) because clkgen is clocked by what this produces.
  -- MAX_IDX must match the divide in gertieboard.sdc -- the SDC is what proves
  -- the design actually closes at the fastest step this will accept.
  cpuclk1 : ENTITY work.cpuclk
    GENERIC MAP (
      MAX_IDX              => 6,          -- 16.667 MHz, the -16 parts' rating
      -- 10 MHz on every reset (idx 4). This is the top of what the -8 part in
      -- this machine will do -- 12.5 fails -- so the board now BOOTS at its
      -- ceiling rather than starting at 5 and being stepped up.
      --
      -- That is a different test from running at 10 MHz: reset, the memory
      -- settle and the whole BIOS POST now happen at the fastest step, and
      -- those are exactly the paths the cold-boot faults lived in. Keep a
      -- 5 MHz .jic to fall back to.
      DEF_IDX              => 4           -- 10 MHz on every reset
    )
    PORT MAP (
      CLK100               => n_c100,
      RESET_N              => n_reset,
      ADDR                 => n_io_addr,
      DATA                 => n_cpu_wdata,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAOUT              => n_periph_rdata,
      CLK_CPU              => n_cpuclk,
      CLK_CPU_PAD          => n_cpuclk_pad,
      OPL_SMP              => n_opl_smp,
      OPL_T1               => n_opl_t1,
      OPL_T2               => n_opl_t2
    );

  ctrl1 : ENTITY work.ctrl_reg
    PORT MAP (
      CLK                  => n_cpuclk,
      RESET                => n_rst_out,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      WR                   => n_io_wr,
      CTRL                 => n_ctrl
    );

  -- RESET here is the RAW reset, not clkgen's gated RST_OUT. It must be:
  -- clkgen now holds the CPU until this controller reports INIT_DONE, so
  -- feeding it the gated reset would hold the memory in reset until it
  -- reported ready, which it could never do. The memory comes up first and
  -- the CPU waits for it -- which is the correct order regardless.
  inst : ENTITY work.mem_hybrid
    PORT MAP (
      CLK_RAM              => n_c3,
      RESET                => n_mem_rst,
      DATAIN               => n_cpu_wdata,
      ADDR                 => n_mem_addr,
      RD                   => n_mem_rd,
      WR                   => n_mem_wr,
      CTRL                 => n_ctrl,
      READY                => n_ready_mem,
      MEM_READY            => n_mem_ready,
      RAM_SCK              => n_ram_sck,
      RAM_CS               => n_ram_cs,
      DATAOUT              => n_periph_rdata,
      RAM_SIO              => RAM_SIO,
      SD_REQ               => n_cr_req,
      SD_LOCK              => n_cr_lock,
      SD_WE                => n_cr_we,
      SD_ADDR              => n_cr_a,
      SD_DIN               => n_cr_d,
      SD_BE                => n_cr_be,
      SD_DOUT              => n_sd_dout,
      SD_ACK               => n_cr_ack,
      SD_INIT              => n_sd_init
    );

  -- The EGA register file. It observes reads of 0x3DA to reset the attribute
  -- controller's index/data flip-flop, but does not drive that port -- that is
  -- cga_status's job and the two are not connected.
  egaregs1 : ENTITY work.ega_regs
    PORT MAP (
      CLK                  => n_cpuclk,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAOUT              => n_periph_rdata,
      EGA_ON               => n_ega_on,
      MAP_MASK             => n_map_mask,
      SET_RES              => n_set_res,
      EN_SR                => n_en_sr,
      COL_CMP              => OPEN,
      ROTATE               => n_rotate,
      FUNC_SEL             => n_func_sel,
      RD_MAP               => n_rd_map,
      WR_MODE              => n_wr_mode,
      RD_MODE              => OPEN,
      COL_DC               => OPEN,
      BIT_MASK             => n_bit_mask,
      PALETTE              => n_palette
    );

  -- The 32 MB SDRAM, and an I/O window onto it. The window exists so the memory
  -- can be proved by itself before the EGA planes move into it -- a fault there
  -- would show up as a corrupt picture, which looks exactly like a bug in the
  -- addressing, the scanline buffer or the write path.
  sdram1 : ENTITY work.sdram_ctrl
    GENERIC MAP (
      CLK_HZ               => 50000000
    )
    PORT MAP (
      CLK                  => n_c3,
      RESET                => n_mem_rst,
      REQ                  => n_e_req,
      WE                   => n_e_we,
      ADDR                 => n_e_a,
      DIN                  => n_e_d,
      BE                   => n_e_be,
      DOUT                 => n_sd_dout,
      ACK                  => n_e_ack,
      BUSY                 => OPEN,
      INIT_DONE            => n_sd_init,
      DBG_STATE            => n_sd_state,
      DRAM_ADDR            => DRAM_ADDR,
      DRAM_BA              => DRAM_BA,
      DRAM_DQ              => DRAM_DQ,
      DRAM_DQM             => DRAM_DQM,
      DRAM_CLK             => DRAM_CLK,
      DRAM_CKE             => DRAM_CKE,
      DRAM_CS_N            => DRAM_CS_N,
      DRAM_RAS_N           => DRAM_RAS_N,
      DRAM_CAS_N           => DRAM_CAS_N,
      DRAM_WE_N            => DRAM_WE_N
    );

  sdramio1 : ENTITY work.sdram_io
    PORT MAP (
      CLK_IO               => n_cpuclk,
      CLK_MEM              => n_c3,
      RESET                => n_mem_rst,
      IOADDR               => n_io_addr,
      DATA                 => n_cpu_wdata,
      IORD                 => n_io_rd,
      IOWR                 => n_io_wr,
      DATAOUT              => n_periph_rdata,
      REQ                  => n_sd_req,
      WE                   => n_sd_we,
      ADDR                 => n_sd_addr,
      DIN                  => n_sd_din,
      BE                   => n_sd_be,
      DOUT                 => n_sd_dout,
      ACK                  => n_sd_ack,
      INIT_DONE            => n_sd_init,
      DBG_STATE            => n_sd_state,
      CRTC_START           => n_crtc_start,
      CRTC_OFFS            => n_crtc_offs
    );

  egamem1 : ENTITY work.ega_mem
    PORT MAP (
      CLK_CPU              => n_cpuclk,
      CLK_VGA              => n_c1,
      CLK_MEM              => n_c3,
      RESET                => n_mem_rst,
      CPU_REQ              => n_em_req,
      CPU_WE               => n_em_we,
      CPU_OFFS             => n_em_offs,
      CPU_WDATA            => n_em_wdata,
      CPU_WMASK            => n_em_wmask,
      CPU_RDATA            => n_em_rdata,
      CPU_READY            => n_em_ready,
      ROW_GO               => n_em_row_go,
      ROW_OFFS             => n_em_row_offs,
      COL                  => n_em_col,
      SCAN_DATA            => n_em_scan,
      SD_REQ               => n_ega_sd_req,
      SD_LOCK              => n_ega_sd_lock,
      SD_WE                => n_ega_sd_we,
      SD_ADDR              => n_ega_sd_a,
      SD_DIN               => n_ega_sd_d,
      SD_BE                => n_ega_sd_be,
      SD_DOUT              => n_sd_dout,
      SD_ACK               => n_ega_sd_ack
    );

  sdramarb1 : ENTITY work.sdram_arb
    PORT MAP (
      CLK                  => n_c3,
      RESET                => n_mem_rst,
      R0_REQ               => n_ega_sd_req,
      R0_LOCK              => n_ega_sd_lock,
      R0_WE                => n_ega_sd_we,
      R0_A                 => n_ega_sd_a,
      R0_D                 => n_ega_sd_d,
      R0_BE                => n_ega_sd_be,
      R0_ACK               => n_ega_sd_ack,
      R1_REQ               => n_sd_req,
      R1_LOCK              => '0',      -- the diagnostic window is one word at a time
      R1_WE                => n_sd_we,
      R1_A                 => n_sd_addr,
      R1_D                 => n_sd_din,
      R1_BE                => n_sd_be,
      R1_ACK               => n_sd_ack,
      -- Client 2 is the CPU's conventional memory. mem_hybrid ties these off
      -- itself when memmap.USE_SDRAM_RAM is FALSE, so with REQ low the port is
      -- invisible to the arbiter and the build is the two-client one again --
      -- the revert needs no edit here.
      R2_REQ               => n_cr_req,
      R2_LOCK              => n_cr_lock,
      R2_WE                => n_cr_we,
      R2_A                 => n_cr_a,
      R2_D                 => n_cr_d,
      R2_BE                => n_cr_be,
      R2_ACK               => n_cr_ack,
      S_REQ                => n_e_req,
      S_WE                 => n_e_we,
      S_A                  => n_e_a,
      S_D                  => n_e_d,
      S_BE                 => n_e_be,
      S_ACK                => n_e_ack
    );

  -- The EGA window answers for itself; everything else is mem_hybrid's.
  n_ready <= n_ega_rdy WHEN n_ega_claim = '1' ELSE n_ready_mem;

  cgastatus1 : ENTITY work.cga_status
    PORT MAP (
      DISPEN               => n_dispen,
      VRET                 => n_vret,
      RD                   => n_io_rd,
      ADDR                 => n_io_addr,
      DATAOUT              => n_periph_rdata
    );

  com1_stub1 : ENTITY work.com1_stub
    PORT MAP (
      RD                   => n_io_rd,
      ADDR                 => n_io_addr,
      DATAOUT              => n_periph_rdata
    );

  -- The 6845 register file. vga.vhd still generates fixed timing and ignores
  -- these values -- this exists so the card can be DETECTED, which is done by
  -- writing a CRTC register and reading it back. START and CURSOR are left
  -- OPEN until vga.vhd can use them for hardware scrolling and a text cursor.
  crtc1 : ENTITY work.crtc6845
    PORT MAP (
      CLK                  => n_cpuclk,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAOUT              => n_periph_rdata,
      -- R12/R13 and the Offset register drive the EGA scan address. The CGA
      -- path still ignores both -- see the scan address in vga.vhd.
      START                => n_crtc_start,
      OFFSET               => n_crtc_offs,
      CURSOR               => n_cur_addr,
      CUR_TOP              => n_cur_top,
      CUR_BOT              => n_cur_bot,
      CUR_MOD              => n_cur_mod
    );

  -- AdLib at 0x388/0x389. Every period inside the module is derived from the
  -- three dividers, and the detection protocol depends on the two timers
  -- keeping real time -- so they come from cpuclk1's table and follow the speed
  -- step. CLK_HZ is now only the value they would have if nothing drove them.
  opl2lite1 : ENTITY work.opl2_lite
    GENERIC MAP (
      CLK_HZ               => 8_333_333
    )
    PORT MAP (
      CLK                  => n_cpuclk,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAOUT              => n_periph_rdata,
      SND                  => n_opl_snd,
      SAMPLE_DIV           => n_opl_smp,
      T1_DIV               => n_opl_t1,
      T2_DIV               => n_opl_t2,
      -- The PCM tap runs from the USB PLL, not from the CPU bus clock. That is
      -- the whole reason it can hold a sample rate: n_cpuclk is 5-10 MHz and
      -- changes at run time with the speed ladder, while a USB frame is a hard
      -- 1 ms. Sharing n_clk48 makes 48 samples per frame exact by construction.
      CLK48                => n_clk48,
      PCM                  => n_opl_pcm,
      PCM_STB              => n_opl_pcm_stb
    );

  fdc1 : ENTITY work.fdc8272
    -- CLK is the 8.33 MHz CPU-bus clock (c0), NOT the 50 MHz reference: the
    -- entity's own defaults are 50 MHz / 115200, which would divide down to
    -- ~11.5 kbaud on this clock. These were symbol parameters in the old .bdf.
    --
    -- The UART has its OWN clock now: CLK_UART is c3, 50 MHz, which does not
    -- move when the speed step does. 50e6 / 50 = 1,000,000 EXACTLY, at every
    -- step of the ladder. It used to be an integer divide of the bus clock,
    -- which was +4.2 % at the step the machine boots at -- inside 8N1's ~5 %
    -- envelope, but not clear of it, and an intermittent stall just after the
    -- BIOS arrives is what living there looks like.
    --
    -- For 2 Mbaud set BAUD => 2_000_000 (divisor 25, also exact) AND set the
    -- host to match. Do not raise it further without checking the adapter: an
    -- FTDI can only make 3 MHz / (n + eighths), so 2,000,000 lands exactly and
    -- 2,500,000 cannot be made at all.
    --
    -- Changing speed is now safe for the link at any moment -- the bit timing
    -- does not depend on the CPU clock any more -- but a step change still
    -- re-times nothing mid-byte only because the UART is on the other clock.
    GENERIC MAP (
      UART_CLK_HZ          => 50000000,
      BAUD                 => 1000000
    )
    PORT MAP (
      CLK                  => n_cpuclk,
      CLK_UART             => n_c3,
      RESET                => n_rst_out,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAIN               => n_cpu_wdata,
      DACK                 => n_dack_v(2),
      TC                   => n_tc,
      DMA_DIN              => n_periph_rdata,
      UART_RX              => n_uart_rxd,
      DATAOUT              => n_periph_rdata,
      IRQ                  => n_irq,
      DRQ                  => n_drq,
      DMA_DOUT             => n_dma_dout,
      UART_TX              => n_uart_tx
    );

  -- Sound Blaster DSP: A220 I5 D1, the addresses the real card used and the
  -- ones every game defaults to. It sits IN the PCM path rather than beside it,
  -- taking the OPL2's stream in and returning FM plus digitised audio summed --
  -- so the USB streamer still sees exactly one source and needs no mixer.
  sb1 : ENTITY work.sb_dsp
    GENERIC MAP (
      IO_BASE              => x"0220"
    )
    PORT MAP (
      CLK                  => n_cpuclk,
      RESET                => n_rst_out,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAIN               => n_cpu_wdata,
      DATAOUT              => n_periph_rdata,
      DRQ                  => n_sb_drq,
      DACK                 => n_dack_v(1),
      IOW                  => n_dma_iow,
      TC                   => n_tc,
      DMA_DIN              => n_periph_rdata,
      IRQ                  => n_sb_irq,
      CLK48                => n_clk48,
      PCM_IN               => n_opl_pcm,
      PCM_STB_IN           => n_opl_pcm_stb,
      PCM                  => n_sb_pcm,
      PCM_STB              => n_sb_pcm_stb
    );

  -- 48 MHz for the USB SIE. This replaces the dead `pll2` the schematic
  -- conversion left behind, which had every output OPEN.
  pll48_1 : ENTITY work.pll48
    PORT MAP (
      inclk0               => n_clock50,
      c0                   => n_clk48,
      locked               => n_usb_locked
    );

  -- ONE ENGINE PER PORT. usb_host used to drive both pin pairs from a single
  -- SIE selected by a CTRL bit, which made the fixed disk on port 0 and any
  -- device on port 1 share one set of registers -- a poll of one could repoint
  -- the pins in the middle of a transaction on the other. Two instances cost
  -- ~900 LEs on a part with roughly three quarters of its logic free, and they
  -- cannot interfere by construction.
  --
  -- The instance label `usb1` is kept for the PORT 0 engine even though `usb2`
  -- below serves port 1. Labels here are the original schematic names and are
  -- deliberately never renamed; the off-by-one is in the name only.
  usb1 : ENTITY work.usb_host
    GENERIC MAP (
      IO_BASE              => x"00E8"    -- port 0: drive C:, the fixed disk
    )
    PORT MAP (
      CLK                  => n_cpuclk,
      CLK48                => n_clk48,
      LOCKED               => n_usb_locked,
      RESET                => n_rst_out,
      DATAIN               => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAOUT              => n_periph_rdata,
      IRQ                  => OPEN,       -- the disk is polled, not driven
      USB_DP               => USB0_DP,
      USB_DM               => USB0_DM
    );

  -- Port 1: the hybrid port -- HID, or a USB floppy, or whatever is plugged in.
  -- 0xA8..0xAF is clear of everything this board decodes and, unlike the
  -- adjacent 0xF0..0xFF, is not the 8087 window that real software probes.
  usb2 : ENTITY work.usb_host
    GENERIC MAP (
      IO_BASE              => x"00A8",
      AUDIO                => true
    )
    PORT MAP (
      CLK                  => n_cpuclk,
      CLK48                => n_clk48,
      LOCKED               => n_usb_locked,
      RESET                => n_rst_out,
      DATAIN               => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAOUT              => n_periph_rdata,
      IRQ                  => n_irq2,
      USB_DP               => USB1_DP,
      USB_DM               => USB1_DM,
      AUD_PCM              => n_sb_pcm,
      AUD_STB              => n_sb_pcm_stb,
      AUD_EN               => n_aud_en,
      AUD_ADDR             => n_aud_addr,
      AUD_ENDP             => n_aud_endp,
      AUD_NSMP             => n_aud_nsmp,
      AUD_GAIN             => n_aud_gain,
      AUD_UNDER            => n_aud_under
    );

  -- Audio streams on the hybrid port, so this is where the streamer is built.
  -- usb1 leaves every AUD_* port open and its generic false: the disk port
  -- cannot be an audio device, and unbuilt logic costs nothing.
  usbaud1 : ENTITY work.usb_audio
    GENERIC MAP (
      IO_BASE              => x"00A0"
    )
    PORT MAP (
      CLK                  => n_cpuclk,
      RESET                => n_rst_out,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAOUT              => n_periph_rdata,
      AUD_EN               => n_aud_en,
      AUD_ADDR             => n_aud_addr,
      AUD_ENDP             => n_aud_endp,
      AUD_NSMP             => n_aud_nsmp,
      AUD_GAIN             => n_aud_gain,
      AUD_UNDER            => n_aud_under
    );

  inst3 : ENTITY work.ps2_kbd_ppi
    -- clk here is c3 = 50 MHz (not the entity's 5 MHz default): the PS/2 glitch
    -- filter, frame watchdog and KB_HOLD timeout are all derived from this.
    GENERIC MAP (
      CLK_FREQ_HZ          => 50000000
    )
    PORT MAP (
      clk                  => n_c3,
      reset                => n_rst_out,
      ps2_clk              => n_ps2clk,
      ps2_dat              => n_ps2dat,
      kbd_clr              => n_kbd_clear,
      pa_data              => n_pa_data,
      irq1                 => n_irq1,
      cad_rst              => n_cad_rst
    );

  -- constant tie-offs (GND/VCC symbols in the schematic)
  -- IRQ2 is usb2's frame interrupt now. It was tied low; on a PC/XT with a
  -- single 8259 this line is genuinely free (it is the AT that uses it as the
  -- slave cascade), and this board implements neither the EGA nor the network
  -- cards that were the other XT claimants.
  n_iochk_n <= '0';
  n_cpu_nmi <= '0';
  n_g0 <= '1';

  -- top-level pin connections
  -- The CPU gets the DELAYED copy, never n_cpuclk. That 5 ns is READY's
  -- aperture -- see cpuclk.vhd. Peripherals keep the undelayed clock.
  CPU_CLK <= n_cpuclk_pad;
  CPU_RST <= n_rst_out;
  VGA_HS <= n_hs;
  VGA_VS <= n_vs;
  VGA_RGB <= n_rgb;
  -- clkgen's RESET is active LOW, so pulling it low forces the reset sequence.
  -- Either the reset button or a hardware Ctrl+Alt+Del does it. Because this is
  -- a real reset, bootrom re-arms its overlay and the BIOS is re-fetched from
  -- the host, video returns to text mode and ctrl_reg reloads its safe default.
  -- NOTHING RUNS BEFORE THE CLOCKS ARE REAL.
  --
  -- n_reset is the whole machine's "released" signal: clkgen gates the CPU with
  -- it and n_mem_rst is its inverse, so this one AND term also holds psram_ctrl.
  -- Until pll1 locks, c0..c3 are not clocks -- they ramp -- and psram_ctrl left
  -- reset immediately and began a TIMED QPI init against c3 anyway. The 0x66 /
  -- 0x99 / 0x35 sequence went out at a rate the PSRAM never saw, so it stayed in
  -- SPI mode and every subsequent read returned rubbish.
  --
  -- Which is why the machine booted over JTAG and not from flash: reconfiguring
  -- a board that has been powered for minutes re-locks almost at once AND finds
  -- a PSRAM already left in QPI by the previous run, so a botched init costs
  -- nothing. Cold from the config flash it costs everything -- the loader's own
  -- first `call`, pushing a return address into PSRAM at 0x7C00, hung with
  -- nothing driving READY and the 7-seg stopped on POST 02.
  --
  -- It only became reachable when the bus clock moved into cpuclk, because that
  -- took c0 from 50/6 to 50*2 and changed the PLL's operating point, and so its
  -- lock time. The hazard was always here; the reconfiguration made the window
  -- wide enough to land in. Proved by an A/B of two builds three minutes apart:
  -- cpuclk removed boots from flash, cpuclk present stops on 02.
  -- Was: n_reset <= RESET AND NOT n_cad_rst AND n_pll_locked;
  --
  -- That put the raw button pin into a combinational term sampled by TWO
  -- clock domains -- clkgen on the CPU clock, and n_mem_rst on c3 -- with no
  -- synchroniser between the contact and either of them. A mechanical button
  -- bounces for milliseconds, so one press is tens of edges, and a transition
  -- near a clock edge can leave the two domains disagreeing about whether a
  -- reset happened at all. The CPU restarts and the memory controller does
  -- not, or the reverse. See resetsync.vhd.
  resetsync1 : ENTITY work.resetsync
    PORT MAP (
      CLK      => n_c3,
      LOCKED   => n_pll_locked,
      BTN_N    => RESET,
      CAD_RST  => n_cad_rst,
      RESET_N  => n_reset
    );
  -- n_reset is active low; the memory controller wants active high, and must
  -- NOT be gated by clkgen's RST_OUT (see the mem_hybrid instantiation).
  n_mem_rst <= NOT n_reset;
  n_fl_miso <= FL_MISO;
  FL_SCK <= n_fl_sck;
  FL_CS <= n_fl_cs;
  FL_MOSI <= n_fl_do;
  SEG_A <= n_seg_a;
  SEG_B <= n_seg_b;
  SEG_C <= n_seg_c;
  SEG_D <= n_seg_d;
  SEG_E <= n_seg_e;
  SEG_F <= n_seg_f;
  SEG_G <= n_seg_g;
  -- DMA requests, one bit per channel. ch1 is the Sound Blaster DSP asking for
  -- its next sample, ch2 the floppy -- the two assignments the real machine
  -- made, and what every game's SET BLASTER line already says.
  n_drq_v <= (2 => n_drq, 1 => n_sb_drq, OTHERS => '0');

  n_cpu_hlda <= CPU_HLDA;
  CPU_HLD <= n_hrq;
  CPU_NMI <= n_cpu_nmi;
  n_cpu_inta <= CPU_INTA;
  CPU_INTR <= n_int;
  n_cpu_a <= CPU_A;
  n_cpu_rd <= CPU_RD;
  n_cpu_wr <= CPU_WR;
  n_cpu_ale <= CPU_ALE;
  n_cpu_den <= CPU_DEN;
  n_cpu_dtr <= CPU_DTR;
  n_cpu_iom <= CPU_IOM;
  CPU_RDY <= n_ready_1;
  n_clock50 <= CLOCK50;
  RAM_SCK <= n_ram_sck;
  RAM_CS <= n_ram_cs;
  n_uart_rxd <= UART_RXD;
  UART_TXD <= n_uart_tx;
  n_ps2clk <= PS2CLK;
  DBG(0) <= n_ps2clk;
  n_ps2dat <= PS2DAT;
  DBG(1) <= n_ps2dat;

  -- undriven outputs (matches the schematic's stuck-at-GND / high-Z pins)
  -- PC speaker: 8255 port B bit 1 (SPEAKER_DATA, I/O 61h.1) gated with 8253
  -- counter-2 OUT. This is the AND2 the schematic drew as "and_speaker" and left
  -- with its output dangling, which is why BUZ used to sit at GND.
  -- Software drives it the standard XT way: program counter 2 for the tone, then
  -- set 61h bits 0+1 to open the gate and let it through.
  -- The AdLib mixes in by OR rather than by summing into its PWM, so the
  -- speaker path above is bit-for-bit what it was: when nothing is keyed on the
  -- OPL's mix is zero and n_opl_snd sits at '0', making the OR transparent.
  -- Both sounding at once distorts, which is rare and audible rather than
  -- silent -- the right way round for a fault.
  BUZ <= '0' WHEN SPEAKER_MUTE = '1'
         ELSE ((n_speaker_data AND n_out2) OR n_opl_snd);
  DBG(2) <= '0';
  DBG(3) <= '0';
  DBG(6) <= '0';
  DBG(7) <= '0';
  DBG(4) <= '0';
  DBG(5) <= '0';
  -- USB0_DP/DM and USB1_DP/DM are driven by their own usb_host instance now.

END structural;
