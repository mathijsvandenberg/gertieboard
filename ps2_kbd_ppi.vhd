--==============================================================================
-- ps2_kbd_ppi.vhd
--
-- PS/2 keyboard -> IBM PC/XT 8255 PPI, single file, receive-only.
--
-- Reads a standard PS/2 keyboard on (ps2_clk, ps2_dat), decodes the 11-bit
-- frames, TRANSLATES Scan Code Set 2 (what PS/2 keyboards send by default) into
-- Scan Code Set 1 (what the XT 8255/BIOS expect), and presents the result the
-- way a 5160 keyboard interface does:
--
--      pa_data[7:0]  -> 8255 Port A inputs (CPU reads I/O 60h)
--      irq1          -> 8259 IR1 (0->1 per scancode; suits edge-trig 8259)
--      kbd_clr       <- 8255 Port B bit 7 (I/O 61h.7), BIOS read/clear line
--
-- This is RECEIVE-ONLY: we never drive clk/data, so there is no host-to-device
-- command path (no LED/Set-1 command needed -- the keyboard powers up scanning
-- in Set 2 and we translate).  ps2_clk/ps2_dat are plain inputs.
--
-- PS/2 FRAME (device->host): 11 bits, sampled on the FALLING edge of ps2_clk:
--      start(0) d0 d1 d2 d3 d4 d5 d6 d7 parity(odd) stop(1)      (LSB first)
--
-- SET 2 -> SET 1 NOTES
--   * make  : code -> set1
--   * break : F0, code -> set1 OR 0x80
--   * ext   : E0, code -> E0, set1        (break: E0, F0, code -> E0, set1|80)
--   * the keyboard's power-on 0xAA (BAT ok) and stray FA/EE/FE/FF/00 are ignored
--
-- HANDSHAKE: matches the BIOS INT 09h (read 60h; pulse PB7 0->1->0).
--
-- ELECTRICAL: PS/2 is 5 V open-collector (idle high via pull-ups).  A Cyclone IV
-- input is NOT 5 V tolerant -- level-shift both lines (e.g. BSS138, or for RX
-- only a ~1k series resistor + 3.3 V pull-up so the line swings 0..3V3).  Power
-- the keyboard from +5 V (mini-DIN pin 4), GND pin 3, DATA pin 1, CLK pin 5.
-- (Many FPGA boards already condition their PS/2 port -- connect direct there.)
--==============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ps2_kbd_ppi is
    generic (
        CLK_FREQ_HZ : integer := 5_000_000          -- PPI clock (set to actual)
    );
    port (
        clk     : in  std_logic;
        reset   : in  std_logic;                       -- sync, active high
        ps2_clk : in  std_logic;                       -- from keyboard
        ps2_dat : in  std_logic;
        pa_data : out std_logic_vector(7 downto 0);    -- -> 8255 Port A (60h)
        irq1    : out std_logic;                       -- -> 8259 IR1
        kbd_clr : in  std_logic;                       -- <- 8255 PB7 (61h.7)
        -- Ctrl+Alt+Del seen in HARDWARE -> ~1 ms active-high system reset request.
        -- The BIOS also implements Ctrl+Alt+Del in its INT 09h handler, but any
        -- program that installs its own INT 09h (most games do) takes that path
        -- away, leaving no way out of a wedged game except power-cycling. This
        -- sits in the scancode stream itself, so no software can bypass it, and
        -- because it drives a real reset the boot ROM overlay re-arms and the
        -- BIOS is re-fetched from the host -- a true cold boot, not a warm one.
        cad_rst : out std_logic;
        -- DEBUG (wire to LEDs; leave => open if unused). Latches last byte.
        dbg_raw : out std_logic_vector(7 downto 0);    -- last RAW Set2 byte rx'd
        dbg_s1  : out std_logic_vector(7 downto 0)     -- last Set1 byte queued
    );
end entity ps2_kbd_ppi;

architecture rtl of ps2_kbd_ppi is

    ----------------------------------------------------------------------------
    -- Set 2 -> Set 1 translation (non-extended keys).  Returns 0x00 for codes
    -- we do not map (those are dropped).
    ----------------------------------------------------------------------------
    function s2_to_s1(b : std_logic_vector(7 downto 0)) return std_logic_vector is
    begin
        case b is
            -- letters
            when x"1C" => return x"1E"; -- A
            when x"32" => return x"30"; -- B
            when x"21" => return x"2E"; -- C
            when x"23" => return x"20"; -- D
            when x"24" => return x"12"; -- E
            when x"2B" => return x"21"; -- F
            when x"34" => return x"22"; -- G
            when x"33" => return x"23"; -- H
            when x"43" => return x"17"; -- I
            when x"3B" => return x"24"; -- J
            when x"42" => return x"25"; -- K
            when x"4B" => return x"26"; -- L
            when x"3A" => return x"32"; -- M
            when x"31" => return x"31"; -- N
            when x"44" => return x"18"; -- O
            when x"4D" => return x"19"; -- P
            when x"15" => return x"10"; -- Q
            when x"2D" => return x"13"; -- R
            when x"1B" => return x"1F"; -- S
            when x"2C" => return x"14"; -- T
            when x"3C" => return x"16"; -- U
            when x"2A" => return x"2F"; -- V
            when x"1D" => return x"11"; -- W
            when x"22" => return x"2D"; -- X
            when x"35" => return x"15"; -- Y
            when x"1A" => return x"2C"; -- Z
            -- digits
            when x"16" => return x"02"; -- 1
            when x"1E" => return x"03"; -- 2
            when x"26" => return x"04"; -- 3
            when x"25" => return x"05"; -- 4
            when x"2E" => return x"06"; -- 5
            when x"36" => return x"07"; -- 6
            when x"3D" => return x"08"; -- 7
            when x"3E" => return x"09"; -- 8
            when x"46" => return x"0A"; -- 9
            when x"45" => return x"0B"; -- 0
            -- punctuation
            when x"4E" => return x"0C"; -- - _
            when x"55" => return x"0D"; -- = +
            when x"54" => return x"1A"; -- [ {
            when x"5B" => return x"1B"; -- ] }
            when x"5D" => return x"2B"; -- \ |
            when x"4C" => return x"27"; -- ; :
            when x"52" => return x"28"; -- ' "
            when x"41" => return x"33"; -- , <
            when x"49" => return x"34"; -- . >
            when x"4A" => return x"35"; -- / ?
            when x"0E" => return x"29"; -- ` ~
            -- whitespace / control
            when x"29" => return x"39"; -- space
            when x"0D" => return x"0F"; -- tab
            when x"5A" => return x"1C"; -- enter
            when x"66" => return x"0E"; -- backspace
            when x"76" => return x"01"; -- esc
            -- modifiers / locks
            when x"12" => return x"2A"; -- left shift
            when x"59" => return x"36"; -- right shift
            when x"14" => return x"1D"; -- left ctrl
            when x"11" => return x"38"; -- left alt
            when x"58" => return x"3A"; -- caps lock
            when x"77" => return x"45"; -- num lock
            when x"7E" => return x"46"; -- scroll lock
            -- function keys
            when x"05" => return x"3B"; -- F1
            when x"06" => return x"3C"; -- F2
            when x"04" => return x"3D"; -- F3
            when x"0C" => return x"3E"; -- F4
            when x"03" => return x"3F"; -- F5
            when x"0B" => return x"40"; -- F6
            when x"83" => return x"41"; -- F7
            when x"0A" => return x"42"; -- F8
            when x"01" => return x"43"; -- F9
            when x"09" => return x"44"; -- F10
            when x"78" => return x"57"; -- F11
            when x"07" => return x"58"; -- F12
            -- keypad (non-extended)
            when x"7C" => return x"37"; -- KP *
            when x"7B" => return x"4A"; -- KP -
            when x"79" => return x"4E"; -- KP +
            when x"71" => return x"53"; -- KP .
            when x"70" => return x"52"; -- KP 0
            when x"69" => return x"4F"; -- KP 1
            when x"72" => return x"50"; -- KP 2
            when x"7A" => return x"51"; -- KP 3
            when x"6B" => return x"4B"; -- KP 4
            when x"73" => return x"4C"; -- KP 5
            when x"74" => return x"4D"; -- KP 6
            when x"6C" => return x"47"; -- KP 7
            when x"75" => return x"48"; -- KP 8
            when x"7D" => return x"49"; -- KP 9
            when others => return x"00";
        end case;
    end function;

    ----------------------------------------------------------------------------
    -- Set 2 -> Set 1 translation for E0-extended keys (returned WITHOUT the E0;
    -- the caller emits E0 then this).  0x00 => unmapped / dropped.
    ----------------------------------------------------------------------------
    function s2_to_s1_ext(b : std_logic_vector(7 downto 0)) return std_logic_vector is
    begin
        case b is
            when x"75" => return x"48"; -- up
            when x"72" => return x"50"; -- down
            when x"6B" => return x"4B"; -- left
            when x"74" => return x"4D"; -- right
            when x"70" => return x"52"; -- insert
            when x"71" => return x"53"; -- delete
            when x"6C" => return x"47"; -- home
            when x"69" => return x"4F"; -- end
            when x"7D" => return x"49"; -- page up
            when x"7A" => return x"51"; -- page down
            when x"14" => return x"1D"; -- right ctrl
            when x"11" => return x"38"; -- right alt
            when x"4A" => return x"35"; -- KP /
            when x"5A" => return x"1C"; -- KP enter
            when x"1F" => return x"5B"; -- left GUI
            when x"27" => return x"5C"; -- right GUI
            when x"2F" => return x"5D"; -- menu
            when others => return x"00";
        end case;
    end function;

    ----------------------------------------------------------------------------
    -- PS/2 receiver: 2-FF metastability sync -> glitch filter -> edge detect
    ----------------------------------------------------------------------------
    signal clk_sync : std_logic_vector(1 downto 0) := (others => '1');
    signal dat_sync : std_logic_vector(1 downto 0) := (others => '1');
    -- glitch filter (integrator): a line must hold its new level for FILT
    -- consecutive cycles before the filtered output follows.  This rejects the
    -- ringing/glitches on real PS/2 clock lines that would otherwise inject
    -- false edges and corrupt the frame.  ~1.6 us at any clock.
    constant FILT   : integer := CLK_FREQ_HZ / 625_000;
    signal clk_f    : std_logic := '1';      -- filtered clock
    signal dat_f    : std_logic := '1';      -- filtered data
    signal clk_f_d  : std_logic := '1';      -- filtered clock, delayed (edge det)
    signal clk_cnt  : integer range 0 to FILT := 0;
    signal dat_cnt  : integer range 0 to FILT := 0;
    signal ps2_sr   : std_logic_vector(10 downto 0) := (others => '0');
    signal bit_cnt  : integer range 0 to 11 := 0;
    constant WD_MAX : integer := CLK_FREQ_HZ / 4000;   -- ~250 us frame watchdog
    signal wd_cnt   : integer range 0 to WD_MAX := 0;
    signal rx_byte  : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_valid : std_logic := '0';
    signal dbg_raw_r : std_logic_vector(7 downto 0) := (others => '0');
    signal dbg_s1_r  : std_logic_vector(7 downto 0) := (others => '0');

    ----------------------------------------------------------------------------
    -- translator context (persist across frames)
    ----------------------------------------------------------------------------
    signal f0_pending : std_logic := '0';   -- next code is a break
    signal e0_pending : std_logic := '0';   -- next code is E0-extended

    ----------------------------------------------------------------------------
    -- scancode FIFO (dual-pointer, one extra wrap bit; no shared count)
    ----------------------------------------------------------------------------
    constant FD : integer := 16;
    constant FW : integer := 4;             -- log2(FD)
    type fifo_t is array (0 to FD-1) of std_logic_vector(7 downto 0);
    signal fifo    : fifo_t := (others => (others => '0'));
    signal wptr    : unsigned(FW downto 0) := (others => '0');

    -- Ctrl+Alt+Del detector (Set-1 codes: ctrl 1D, alt 38, Del 53; the extended
    -- E0-prefixed right-hand ctrl/alt and the dedicated Del map to the same
    -- values, so both sides of the keyboard work).
    constant CAD_TICKS : integer := CLK_FREQ_HZ / 1000;   -- ~1 ms assertion
    signal ctrl_held : std_logic := '0';
    signal alt_held  : std_logic := '0';
    -- NOTE: cad_cnt is deliberately NOT cleared by `reset`. It is what CAUSES
    -- the reset, so clearing it there would cut its own pulse short.
    signal cad_cnt   : integer range 0 to CAD_TICKS := 0;
    signal rptr    : unsigned(FW downto 0) := (others => '0');
    signal f_empty : std_logic;

    ----------------------------------------------------------------------------
    -- output handshake (PA byte + IRQ1 + PB7)
    ----------------------------------------------------------------------------
    type kb_t is (KB_IDLE, KB_HOLD, KB_CLR);
    signal kb_state : kb_t := KB_IDLE;
    signal pa_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal irq_r    : std_logic := '0';
    signal clr_sync : std_logic_vector(2 downto 0) := (others => '0');

    -- AT-style fallback ------------------------------------------------------
    -- The PB7 pulse is how a real PC/XT acknowledges a scancode, and the BIOS
    -- INT 09h does it, which is why typing at the DOS prompt works.  But a game
    -- that installs its OWN INT 09h usually only reads port 60h and sends EOI
    -- (the AT 8042 needs no PB7).  Waiting for a PB7 edge that never comes
    -- parks us in KB_HOLD forever: IRQ1 stays high, no new edge ever reaches
    -- the edge-triggered 8259, and the keyboard goes dead after ONE key.
    --
    -- So KB_HOLD also times out.  The first timeout latches at_mode, and from
    -- then on the PB7 gating is bypassed entirely, so AT-style handlers keep
    -- receiving scancodes.  XT-style software still pulses PB7 and takes the
    -- fast path exactly as before -- it never hits the timeout at all.
    --
    -- HOLD_MAX is ~2 ms: orders of magnitude longer than any keyboard ISR (so
    -- the byte is never replaced before it has been read), yet still allows
    -- ~500 scancodes/s, far more than typing or gameplay needs.
    constant HOLD_MAX : integer := CLK_FREQ_HZ / 500;         -- ~2 ms
    signal hold_cnt   : integer range 0 to HOLD_MAX := 0;
    signal at_mode    : std_logic := '0';

begin

    --==========================================================================
    -- concurrent outputs / flags
    --==========================================================================
    pa_data <= pa_reg;
    irq1    <= irq_r;
    cad_rst <= '1' when cad_cnt /= 0 else '0';
    dbg_raw <= dbg_raw_r;
    dbg_s1  <= dbg_s1_r;
    f_empty <= '1' when wptr = rptr else '0';

    --==========================================================================
    -- PS/2 receive: synchronise, shift on falling clk, validate frame
    --==========================================================================
    rx_proc : process(clk)
        variable data_byte : std_logic_vector(7 downto 0);
        variable parity_ok : std_logic;
        variable fall      : std_logic;
    begin
        if rising_edge(clk) then
            clk_sync <= clk_sync(0) & ps2_clk;     -- 2-FF metastability sync
            dat_sync <= dat_sync(0) & ps2_dat;
            rx_valid <= '0';

            if reset = '1' then
                clk_f   <= '1'; dat_f <= '1'; clk_f_d <= '1';
                clk_cnt <= 0;   dat_cnt <= 0;
                bit_cnt <= 0;   wd_cnt  <= 0;
                ps2_sr  <= (others => '0');
            else
                -- glitch filter on clock: flip clk_f only after FILT stable cycles
                if clk_sync(1) = clk_f then
                    clk_cnt <= 0;
                elsif clk_cnt = FILT-1 then
                    clk_f   <= clk_sync(1);
                    clk_cnt <= 0;
                else
                    clk_cnt <= clk_cnt + 1;
                end if;

                -- glitch filter on data
                if dat_sync(1) = dat_f then
                    dat_cnt <= 0;
                elsif dat_cnt = FILT-1 then
                    dat_f   <= dat_sync(1);
                    dat_cnt <= 0;
                else
                    dat_cnt <= dat_cnt + 1;
                end if;

                -- falling-edge detect on the FILTERED clock
                clk_f_d <= clk_f;
                fall := '0';
                if clk_f_d = '1' and clk_f = '0' then
                    fall := '1';
                end if;

                -- frame watchdog (resync if a frame stalls mid-way)
                if bit_cnt = 0 then
                    wd_cnt <= 0;
                elsif wd_cnt = WD_MAX then
                    bit_cnt <= 0;
                    wd_cnt  <= 0;
                else
                    wd_cnt <= wd_cnt + 1;
                end if;

                if fall = '1' then
                    wd_cnt <= 0;
                    ps2_sr <= dat_f & ps2_sr(10 downto 1);   -- sr(0) ends = start

                    if bit_cnt = 10 then
                        bit_cnt <= 0;
                        -- pre-shift positions: sr(1)=start sr(2..9)=d0..d7
                        -- sr(10)=parity ; stop bit = dat_f (sampled now)
                        data_byte := ps2_sr(9 downto 2);
                        parity_ok := ps2_sr(2) xor ps2_sr(3) xor ps2_sr(4) xor
                                     ps2_sr(5) xor ps2_sr(6) xor ps2_sr(7) xor
                                     ps2_sr(8) xor ps2_sr(9) xor ps2_sr(10);
                        if ps2_sr(1) = '0'        -- start
                           and dat_f = '1'        -- stop
                           and parity_ok = '1'    -- odd parity
                        then
                            rx_byte  <= data_byte;
                            rx_valid <= '1';
                            dbg_raw_r <= data_byte;   -- debug: last raw Set2 byte
                        end if;
                    else
                        bit_cnt <= bit_cnt + 1;
                    end if;
                end if;
            end if;
        end if;
    end process rx_proc;

    --==========================================================================
    -- translate Set2 -> Set1 and push bytes into the FIFO.
    -- Uses a variable write pointer so an E0 prefix + code (two bytes) can be
    -- enqueued in the same clock.
    --==========================================================================
    xlat_proc : process(clk)
        variable wrp_v : unsigned(FW downto 0);
        variable s1    : std_logic_vector(7 downto 0);

        procedure push(b : std_logic_vector(7 downto 0)) is
            variable full_v : boolean;
        begin
            full_v := (wrp_v(FW-1 downto 0) = rptr(FW-1 downto 0))
                      and (wrp_v(FW) /= rptr(FW));
            if not full_v then
                fifo(to_integer(wrp_v(FW-1 downto 0))) <= b;
                wrp_v := wrp_v + 1;
            end if;
        end procedure;
    begin
        if rising_edge(clk) then
            -- self-timed Ctrl+Alt+Del pulse, outside the reset branch on purpose
            if cad_cnt /= 0 then
                cad_cnt <= cad_cnt - 1;
            end if;

            if reset = '1' then
                wptr       <= (others => '0');
                f0_pending <= '0';
                e0_pending <= '0';
                ctrl_held  <= '0';
                alt_held   <= '0';
            else
                wrp_v := wptr;
                if rx_valid = '1' then
                    case rx_byte is
                        when x"F0" =>                 -- break prefix
                            f0_pending <= '1';
                        when x"E0" =>                 -- extended prefix
                            e0_pending <= '1';
                        when x"AA" | x"FA" | x"EE" |  -- BAT-ok / ACK / echo /
                             x"FE" | x"FF" | x"00" => -- resend / error / overrun
                            f0_pending <= '0';
                            e0_pending <= '0';
                        when others =>
                            if e0_pending = '1' then
                                s1 := s2_to_s1_ext(rx_byte);
                            else
                                s1 := s2_to_s1(rx_byte);
                            end if;
                            if s1 /= x"00" then
                                if e0_pending = '1' then
                                    push(x"E0");
                                end if;
                                if f0_pending = '1' then
                                    push(s1 or x"80");   -- break
                                    dbg_s1_r <= s1 or x"80";
                                    -- release of ctrl / alt
                                    if s1 = x"1D" then ctrl_held <= '0'; end if;
                                    if s1 = x"38" then alt_held  <= '0'; end if;
                                else
                                    push(s1);            -- make
                                    dbg_s1_r <= s1;
                                    if s1 = x"1D" then ctrl_held <= '1'; end if;
                                    if s1 = x"38" then alt_held  <= '1'; end if;
                                    -- Del pressed while both are down -> reset
                                    if s1 = x"53" and ctrl_held = '1'
                                                  and alt_held  = '1' then
                                        cad_cnt <= CAD_TICKS;
                                    end if;
                                end if;
                            end if;
                            f0_pending <= '0';
                            e0_pending <= '0';
                    end case;
                end if;
                wptr <= wrp_v;
            end if;
        end if;
    end process xlat_proc;

    --==========================================================================
    -- OUTPUT STAGE: FIFO -> Port A + IRQ1, with the BIOS PB7 handshake.
    --   KB_IDLE: when FIFO non-empty and PB7 low, present byte, raise IRQ1.
    --   KB_HOLD: wait for PB7 rising edge (BIOS read+clear) -> drop IRQ1.
    --   KB_CLR : wait for PB7 falling edge (BIOS re-enable) -> serve next.
    --==========================================================================
    kbout_proc : process(clk)
        variable clr_rise, clr_fall : std_logic;
    begin
        if rising_edge(clk) then
            clr_sync <= clr_sync(1 downto 0) & kbd_clr;
            clr_rise := '0';
            clr_fall := '0';
            if clr_sync(2 downto 1) = "01" then clr_rise := '1'; end if;
            if clr_sync(2 downto 1) = "10" then clr_fall := '1'; end if;

            if reset = '1' then
                kb_state <= KB_IDLE;
                rptr     <= (others => '0');
                irq_r    <= '0';
                pa_reg   <= (others => '0');
                hold_cnt <= 0;
                at_mode  <= '0';
            else
                case kb_state is
                    when KB_IDLE =>
                        irq_r <= '0';
                        -- Once at_mode is latched the PB7 level no longer gates
                        -- us, otherwise software that parks PB7 high would stall
                        -- here just as surely as it stalled in KB_HOLD.
                        if f_empty = '0'
                           and (clr_sync(2) = '0' or at_mode = '1') then
                            pa_reg <= fifo(to_integer(rptr(FW-1 downto 0)));
                            rptr   <= rptr + 1;
                            irq_r  <= '1';
                            hold_cnt <= 0;
                            kb_state <= KB_HOLD;
                        end if;
                    when KB_HOLD =>
                        irq_r <= '1';
                        if clr_rise = '1' then          -- XT: BIOS-style ack
                            irq_r    <= '0';
                            kb_state <= KB_CLR;
                        elsif hold_cnt = HOLD_MAX then  -- AT: no PB7 ever came
                            at_mode  <= '1';
                            irq_r    <= '0';
                            kb_state <= KB_IDLE;
                        else
                            hold_cnt <= hold_cnt + 1;
                        end if;
                    when KB_CLR =>
                        irq_r <= '0';
                        if clr_fall = '1' then
                            kb_state <= KB_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process kbout_proc;

end architecture rtl;
