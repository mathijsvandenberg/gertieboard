------------------------------------------------------------------------------
-- gertieboard.vhdl  --  structural top level (converted from gertieboard.bdf)
--
-- 1:1 translation of the former schematic top level: same component
-- instances, same net connectivity, same pin names. Buses connect whole
-- (no bit-ripping in the original); bit splitting happens inside modules.
--
-- Faithful to the schematic, including its quirks:
--   * the speaker AND-gate output and BUZ were never wired -> BUZ = '0'
--   * DBG(7..2), USB0_DP/DM are undriven (were 'stuck at GND'/high-Z)
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
    RAM_SIO        : INOUT std_logic_vector(3 downto 0);
    DBG            : OUT   std_logic_vector(7 downto 0)
  );
END gertieboard;

ARCHITECTURE structural OF gertieboard IS
  SIGNAL n_c0                   : std_logic;
  SIGNAL n_c1                   : std_logic;
  SIGNAL n_c2                   : std_logic;
  SIGNAL n_c3                   : std_logic;
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
  SIGNAL n_dack                 : std_logic;
  SIGNAL n_dma_addr             : std_logic_vector(15 downto 0);
  SIGNAL n_dma_dout             : std_logic_vector(7 downto 0);
  SIGNAL n_dma_memr             : std_logic;
  SIGNAL n_dma_memw             : std_logic;
  SIGNAL n_drq                  : std_logic;
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
  SIGNAL n_irq2                 : std_logic;
  SIGNAL n_kbd_clear            : std_logic;
  SIGNAL n_mem_addr             : std_logic_vector(19 downto 0);
  SIGNAL n_mem_rd               : std_logic;
  SIGNAL n_mem_wr               : std_logic;
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
BEGIN

  vga1 : ENTITY work.vga
    PORT MAP (
      CLK_VGA              => n_c1,
      CLK_CPU              => n_c0,
      RESET                => n_rst_out,
      WR                   => n_mem_wr,
      RD                   => n_mem_rd,
      ADDR                 => n_mem_addr,
      DATAIN               => n_cpu_wdata,
      IOWR                 => n_io_wr,
      IOADDR               => n_io_addr,
      HS                   => n_hs,
      VS                   => n_vs,
      RGB                  => n_rgb,
      DEBUG                => OPEN,
      DATAOUT              => n_periph_rdata
    );

  clkgen1 : ENTITY work.clkgen
    PORT MAP (
      CLK                  => n_c0,
      RESET                => n_reset,
      RST_OUT              => n_rst_out
    );

  flash1 : ENTITY work.flash
    PORT MAP (
      CLK                  => n_c0,
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
      CLK                  => n_c0,
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

  timer1 : ENTITY work.timer8253
    PORT MAP (
      CLK                  => n_c2,
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
      CLK                  => n_c0,
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
      CLK                  => n_c0,
      RESET                => n_rst_out,
      IO_ADDR              => n_io_addr,
      IO_RD                => n_io_rd,
      IO_WR                => n_io_wr,
      DATAIN               => n_cpu_wdata,
      DREQ                 => n_drq,
      HLDA                 => n_cpu_hlda,
      RAM_READY            => n_ready,
      DACK                 => n_dack,
      HRQ                  => n_hrq,
      DMA_ADDR             => n_dma_addr,
      DMA_MEMR             => n_dma_memr,
      DMA_MEMW             => n_dma_memw,
      DMA_IOR              => OPEN,
      DMA_IOW              => OPEN,
      TC                   => n_tc,
      DATAOUT              => n_periph_rdata
    );

  int1 : ENTITY work.int8259
    PORT MAP (
      CLK                  => n_c0,
      RESET                => n_rst_out,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      INTA                 => n_cpu_inta,
      IRQ0                 => n_out0,
      IRQ1                 => n_irq1,
      IRQ2                 => n_irq2,
      IRQ6                 => n_irq,
      DATAOUT              => n_periph_rdata,
      INT                  => n_int
    );

  busdecode1 : ENTITY work.busdecode
    PORT MAP (
      CLK                  => n_c0,
      A                    => n_cpu_a,
      RD                   => n_cpu_rd,
      WR                   => n_cpu_wr,
      ALE                  => n_cpu_ale,
      DEN                  => n_cpu_den,
      DTR                  => n_cpu_dtr,
      IOM                  => n_cpu_iom,
      RAM_READY            => n_ready,
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
      CLK                  => n_c0,
      RESET                => n_rst_out,
      MEM_ADDR             => n_mem_addr,
      IO_ADDR              => n_io_addr,
      IO_WR                => n_io_wr,
      DATAIN               => n_cpu_wdata,
      ROM_DATA             => n_rom_data,
      ROM_EN               => n_rom_en
    );

  pll1 : ENTITY work.pll
    PORT MAP (
      inclk0               => n_clock50,
      c0                   => n_c0,
      c1                   => n_c1,
      c2                   => n_c2,
      c3                   => n_c3,
      c4                   => OPEN
    );

  ctrl1 : ENTITY work.ctrl_reg
    PORT MAP (
      CLK                  => n_c0,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      WR                   => n_io_wr,
      CTRL                 => n_ctrl
    );

  inst : ENTITY work.mem_hybrid
    PORT MAP (
      CLK_RAM              => n_c3,
      RESET                => n_rst_out,
      DATAIN               => n_cpu_wdata,
      ADDR                 => n_mem_addr,
      RD                   => n_mem_rd,
      WR                   => n_mem_wr,
      CTRL                 => n_ctrl,
      READY                => n_ready,
      RAM_SCK              => n_ram_sck,
      RAM_CS               => n_ram_cs,
      DATAOUT              => n_periph_rdata,
      RAM_SIO              => RAM_SIO
    );

  cgastatus1 : ENTITY work.cga_status
    PORT MAP (
      CLK                  => n_c3,
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

  fdc1 : ENTITY work.fdc8272
    -- CLK is the 5 MHz CPU-bus clock (c0), NOT the 50 MHz reference: the
    -- entity's own defaults are 50 MHz / 115200, which would divide down to
    -- ~11.5 kbaud on this clock. These were symbol parameters in the old .bdf.
    GENERIC MAP (
      CLK_FREQ             => 5000000,
      BAUD                 => 1000000
    )
    PORT MAP (
      CLK                  => n_c0,
      RESET                => n_rst_out,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAIN               => n_cpu_wdata,
      DACK                 => n_dack,
      TC                   => n_tc,
      DMA_DIN              => n_periph_rdata,
      UART_RX              => n_uart_rxd,
      DATAOUT              => n_periph_rdata,
      IRQ                  => n_irq,
      DRQ                  => n_drq,
      DMA_DOUT             => n_dma_dout,
      UART_TX              => n_uart_tx
    );

  pll2 : ENTITY work.pll
    PORT MAP (
      inclk0               => n_clock50,
      c0                   => OPEN,
      c1                   => OPEN,
      c2                   => OPEN,
      c3                   => OPEN,
      c4                   => OPEN
    );

  inst3 : ENTITY work.ps2_kbd_ppi
    -- clk here is c3 = 50 MHz (not the 5 MHz entity default): the PS/2 glitch
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
      irq1                 => n_irq1
    );

  -- constant tie-offs (GND/VCC symbols in the schematic)
  n_irq2 <= '0';
  n_iochk_n <= '0';
  n_cpu_nmi <= '0';
  n_g0 <= '1';

  -- top-level pin connections
  CPU_CLK <= n_c0;
  CPU_RST <= n_rst_out;
  VGA_HS <= n_hs;
  VGA_VS <= n_vs;
  VGA_RGB <= n_rgb;
  n_reset <= RESET;
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
  BUZ <= '0';
  DBG(2) <= '0';
  DBG(3) <= '0';
  DBG(6) <= '0';
  DBG(7) <= '0';
  DBG(4) <= '0';
  DBG(5) <= '0';
  USB0_DP <= 'Z';
  USB0_DM <= 'Z';

END structural;
