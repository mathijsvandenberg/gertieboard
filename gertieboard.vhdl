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
    DBG            : OUT   std_logic_vector(7 downto 0)
  );
END gertieboard;

ARCHITECTURE structural OF gertieboard IS

  -- Set to '1' to silence the PC speaker without changing anything else -- handy
  -- when working at night. '0' = normal working buzzer.
  CONSTANT SPEAKER_MUTE : std_logic := '0';

  SIGNAL n_c0                   : std_logic;
  SIGNAL n_c1                   : std_logic;
  SIGNAL n_c2                   : std_logic;
  SIGNAL n_c3                   : std_logic;
  SIGNAL n_clk48       : std_logic;
  SIGNAL n_usb_locked  : std_logic;
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
      CURSOR               => n_cur_addr,
      CUR_TOP              => n_cur_top,
      CUR_BOT              => n_cur_bot,
      CUR_MOD              => n_cur_mod,
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
      MEM_READY            => n_mem_ready,
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

  -- CLK is the BUS clock so the register interface can see an I/O cycle;
  -- CNT_TICK carries the 1.1905 MHz counting rate. Driving CLK from c2, as
  -- this did, left the PIT sampling strobes on an 840 ns clock.
  timer1 : ENTITY work.timer8253
    PORT MAP (
      CLK                  => n_c0,
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
      READY                => n_ready,
      MEM_READY            => n_mem_ready,
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

  -- The 6845 register file. vga.vhd still generates fixed timing and ignores
  -- these values -- this exists so the card can be DETECTED, which is done by
  -- writing a CRTC register and reading it back. START and CURSOR are left
  -- OPEN until vga.vhd can use them for hardware scrolling and a text cursor.
  crtc1 : ENTITY work.crtc6845
    PORT MAP (
      CLK                  => n_c0,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAOUT              => n_periph_rdata,
      START                => OPEN,
      CURSOR               => n_cur_addr,
      CUR_TOP              => n_cur_top,
      CUR_BOT              => n_cur_bot,
      CUR_MOD              => n_cur_mod
    );

  -- AdLib at 0x388/0x389. CLK_HZ must match the clock wired to CLK: every
  -- period inside the module is derived from it, and the detection protocol
  -- depends on the two timers keeping real time.
  opl2lite1 : ENTITY work.opl2_lite
    GENERIC MAP (
      CLK_HZ               => 8_333_333
    )
    PORT MAP (
      CLK                  => n_c0,
      DATA                 => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAOUT              => n_periph_rdata,
      SND                  => n_opl_snd
    );

  fdc1 : ENTITY work.fdc8272
    -- CLK is the 5 MHz CPU-bus clock (c0), NOT the 50 MHz reference: the
    -- entity's own defaults are 50 MHz / 115200, which would divide down to
    -- ~11.5 kbaud on this clock. These were symbol parameters in the old .bdf.
    GENERIC MAP (
      CLK_FREQ             => 8333333,
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

  -- 48 MHz for the USB SIE. This replaces the dead `pll2` the schematic
  -- conversion left behind, which had every output OPEN.
  pll48_1 : ENTITY work.pll48
    PORT MAP (
      inclk0               => n_clock50,
      c0                   => n_clk48,
      locked               => n_usb_locked
    );

  usb1 : ENTITY work.usb_host
    PORT MAP (
      CLK                  => n_c0,
      CLK48                => n_clk48,
      LOCKED               => n_usb_locked,
      RESET                => n_rst_out,
      DATAIN               => n_cpu_wdata,
      ADDR                 => n_io_addr,
      RD                   => n_io_rd,
      WR                   => n_io_wr,
      DATAOUT              => n_periph_rdata,
      USB0_DP              => USB0_DP,
      USB0_DM              => USB0_DM,
      USB1_DP              => USB1_DP,
      USB1_DM              => USB1_DM
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
      irq1                 => n_irq1,
      cad_rst              => n_cad_rst
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
  -- clkgen's RESET is active LOW, so pulling it low forces the reset sequence.
  -- Either the reset button or a hardware Ctrl+Alt+Del does it. Because this is
  -- a real reset, bootrom re-arms its overlay and the BIOS is re-fetched from
  -- the host, video returns to text mode and ctrl_reg reloads its safe default.
  n_reset <= RESET AND NOT n_cad_rst;
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
  -- USB0_DP/DM and USB1_DP/DM are driven by usb_host now.

END structural;
