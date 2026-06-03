--------------------------------------------------------------------------------
-- ppi8255.vhd
--
-- Simplified Intel 8255 PPI as used on the IBM 5160 (XT) motherboard.
-- Only the functions actually wired up on the XT are implemented:
--
--   Port A (0x60) : INPUT  - keyboard scancode (from KB shift register)
--   Port B (0x61) : OUTPUT - speaker / parity / IOCHK / keyboard control
--   Port C (0x62) : INPUT  - SW1 switches (nibble-selected) + NMI sources
--   Ctrl   (0x63) : control word (BIOS writes 0x99 to set mode-0 A/C in, B out)
--
-- Notes:
--   * RD / WR are assumed active HIGH I/O strobes (invert externally if your
--     bus uses /IOR /IOW).
--   * The mode register is accepted but the chip is HARD-WIRED to the XT
--     direction setup (A in, B out, C in).  Bit-set/reset of port C is a
--     no-op since port C is all inputs on the XT.
--   * SW1 read value is exposed AS SEEN BY SOFTWARE; on the real board the
--     switches are inverted by the buffer, so encode the value you want the
--     BIOS to read directly into the SW1 constant below.
--   * Cassette-data-in (PC4 on the 5150) is unused on the 5160; tied to '0'.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ppi8255 is
    port (
        -- System bus -----------------------------------------------------------
        CLK             : in  std_logic;
        RESET           : in  std_logic;                       -- async, active high
        DATA            : in  std_logic_vector(7 downto 0);    -- CPU -> PPI
        DATA_OUT        : out std_logic_vector(7 downto 0);    -- PPI -> CPU, 'Z' when not addressed
        ADDR            : in  std_logic_vector(15 downto 0);
        RD              : in  std_logic;                       -- active high I/O read
        WR              : in  std_logic;                       -- active high I/O write

        -- Port A : keyboard scancode latch -------------------------------------
        KBD_DATA        : in  std_logic_vector(7 downto 0);    -- from 74LS322 shifter

        -- Port B : broken-out outputs (XT functions) ---------------------------
        TIMER2_GATE     : out std_logic;   -- PB0 -> 8253 GATE2 (speaker timer)
        SPEAKER_DATA    : out std_logic;   -- PB1 -> AND'd with TIMER2_OUT to drive spkr
        ENABLE_PARITY_N : out std_logic;   -- PB4 -> '0' enables RAM parity check
        ENABLE_IOCHK_N  : out std_logic;   -- PB5 -> '0' enables I/O channel check
        KBD_CLOCK_HOLD  : out std_logic;   -- PB6 -> '0' holds KB clock low (disable)
        KBD_CLEAR       : out std_logic;   -- PB7 -> '1' clears+holds KB shift reg,
                                           --        '0' enables data onto port A

        -- Port C : status / NMI sources ----------------------------------------
        TIMER2_OUT      : in  std_logic;   -- PC5 readback of 8253 counter-2 OUT
        IOCHK_N         : in  std_logic;   -- PC6 -I/O channel check (NMI source)
        PARITY_ERR_N    : in  std_logic    -- PC7 -RAM parity error  (NMI source)
    );
end entity ppi8255;

architecture rtl of ppi8255 is

    ----------------------------------------------------------------------------
    -- SW1 DIP switches (read via port C, nibble-selected by PB3)
    --
    -- Bit ordering in this constant: SW1(0) = SW1-1, SW1(7) = SW1-8
    -- The value below is what software will SEE on port C, not the physical
    -- switch position. Example configuration:
    --
    --   SW1-1     : POST manufacturing loop      -> 0  (normal boot)
    --   SW1-2     : 8087 coprocessor present     -> 0  (no FPU)
    --   SW1-3..4  : motherboard RAM banks        -> "11" = all 4 banks populated
    --                                                      (256 KB on 256-640 board)
    --   SW1-5..6  : initial display              -> "10" = colour 80x25 (CGA)
    --   SW1-7..8  : floppy drive count           -> "01" = 2 drives
    --
    -- Encoded LSB-first:   SW1(7..0) = "01 10 11 0 0"  ->  x"6C"
    ----------------------------------------------------------------------------
    constant SW1 : std_logic_vector(7 downto 0) := x"6C";

    ----------------------------------------------------------------------------
    -- Internal state
    ----------------------------------------------------------------------------
    signal port_b_reg : std_logic_vector(7 downto 0);
    signal ctrl_reg   : std_logic_vector(7 downto 0);

    signal cs         : std_logic;                  -- 0x60..0x63 chip select
    signal port_c_in  : std_logic_vector(7 downto 0);
	 
	  -- Active-HIGH internal versions of the active-low RD / WR inputs.
    signal rd_act, wr_act : std_logic;

begin

    rd_act <= not RD;
    wr_act <= not WR;
 
    ----------------------------------------------------------------------------
    -- Address decode : I/O 0x0060..0x0063
    ----------------------------------------------------------------------------
    cs <= '1' when ADDR(15 downto 2) = "00000000011000" else '0';
 
    ----------------------------------------------------------------------------
    -- Write path (synchronous)
    --   0x61 -> Port B latch
    --   0x63 -> control word (accepted for compatibility; direction is fixed)
    ----------------------------------------------------------------------------
    process (CLK, RESET)
    begin
        if RESET = '1' then
            -- 8255 power-on state: all ports inputs, port B latch cleared.
            -- BIOS will write 0x99 to ctrl and then initialize port B.
            port_b_reg <= (others => '0');
            ctrl_reg   <= x"9B";                    -- mode 0, A/B/C all inputs
        elsif rising_edge(CLK) then
            if cs = '1' and wr_act = '1' then
                case ADDR(1 downto 0) is
                    when "01" =>                    -- 0x61 : Port B
                        port_b_reg <= DATA;
                    when "11" =>                    -- 0x63 : control / bit-set-reset
                        if DATA(7) = '1' then
                            ctrl_reg <= DATA;       -- mode set (BIOS uses 0x99)
                        end if;
                        -- DATA(7)='0' is port-C bit set/reset; ignored because
                        -- port C is hard-wired as input on the XT.
                    when others =>                  -- 0x60, 0x62 are inputs
                        null;
                end case;
            end if;
        end if;
    end process;
 
    ----------------------------------------------------------------------------
    -- Port B fan-out
    ----------------------------------------------------------------------------
    TIMER2_GATE     <= port_b_reg(0);
    SPEAKER_DATA    <= port_b_reg(1);
    -- port_b_reg(2)  : spare on most XT revs (unused)
    -- port_b_reg(3)  : SW1 nibble select (consumed internally below)
    ENABLE_PARITY_N <= port_b_reg(4);
    ENABLE_IOCHK_N  <= port_b_reg(5);
    KBD_CLOCK_HOLD  <= port_b_reg(6);
    KBD_CLEAR       <= port_b_reg(7);
 
    ----------------------------------------------------------------------------
    -- Port C assembly
    --   PC0..PC3 : SW1 low or high nibble (selected by PB3)
    --   PC4      : cassette data-in on 5150; unused on 5160 -> '0'
    --   PC5      : 8253 counter-2 OUT readback
    --   PC6      : -IOCHK from expansion bus  (NMI source)
    --   PC7      : -PCK   from parity logic   (NMI source)
    ----------------------------------------------------------------------------
    port_c_in(3 downto 0) <= SW1(3 downto 0) when port_b_reg(3) = '0'
                                              else SW1(7 downto 4);
    port_c_in(4)          <= '0';
    port_c_in(5)          <= TIMER2_OUT;
    port_c_in(6)          <= IOCHK_N;
    port_c_in(7)          <= PARITY_ERR_N;
 
    ----------------------------------------------------------------------------
    -- Read path (combinational)
    --   DATA_OUT is high-Z when this chip isn't being read, so peripherals'
    --   read busses can be wired-OR together at the top level.
    ----------------------------------------------------------------------------
    process (cs, rd_act, ADDR, port_b_reg, ctrl_reg, KBD_DATA, port_c_in)
    begin
        if cs = '1' and rd_act = '1' then
            case ADDR(1 downto 0) is
                when "00" =>                        -- 0x60 : Port A (keyboard)
                    DATA_OUT <= KBD_DATA;
                when "01" =>                        -- 0x61 : Port B readback
                    DATA_OUT <= port_b_reg;
                when "10" =>                        -- 0x62 : Port C
                    DATA_OUT <= port_c_in;
                when "11" =>                        -- 0x63 : control readback
                    DATA_OUT <= ctrl_reg;           -- not standard 8255, handy for debug
                when others =>
                    DATA_OUT <= (others => 'Z');
            end case;
        else
            DATA_OUT <= (others => 'Z');
        end if;
    end process;

end architecture rtl;