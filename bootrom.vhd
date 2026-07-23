--------------------------------------------------------------------------------
-- bootrom.vhd  --  reset-time boot overlay (no UART of its own)
--
-- Holds the small bootloader ROM overlaid on 0xFFF00..0xFFFFF while ROM_EN='1'
-- (set at reset). The reset vector at 0xFFFF0 lands here, so the CPU starts in
-- the bootloader while the BIOS area in PSRAM is still empty.
--
-- The bootloader fetches the BIOS image by driving the EXISTING floppy
-- controller (PIO read of the reserved cylinder 0xFF), so this module needs no
-- UART and no extra serial connection. It only provides:
--   * the ROM byte for the overlay window  (ROM_DATA, muxed in busdecode)
--   * the overlay-enable flag               (ROM_EN)
--   * the control register                  (OUT 0xE2 bit0 = 1 -> ROM_EN=0)
--
-- ROM image comes from bootldr.mif (assemble bootldr.asm, convert with mkmif.py).
--------------------------------------------------------------------------------

LIBRARY IEEE;
USE  IEEE.STD_LOGIC_1164.all;
USE  IEEE.STD_LOGIC_ARITH.all;
USE  IEEE.STD_LOGIC_UNSIGNED.all;


ENTITY bootrom IS
  PORT(
        CLK      : IN    std_logic;
        RESET    : IN    std_logic;

        -- memory side: low 8 bits of the address being read (256-byte window)
        MEM_ADDR : IN    std_logic_vector(19 DOWNTO 0);
        ROM_DATA : OUT   std_logic_vector(7 DOWNTO 0);   -- -> busdecode overlay mux
        ROM_EN   : OUT   std_logic;                      -- '1' = overlay active

        -- I/O side: just the overlay-control write at 0xE2
        IO_ADDR  : IN    std_logic_vector(15 DOWNTO 0);
        IO_WR    : IN    std_logic;
        DATAIN   : IN    std_logic_vector(7 DOWNTO 0) );
END bootrom;


ARCHITECTURE behavior OF bootrom IS

  -- 256-byte boot ROM, initialised from the assembled bootloader.
  TYPE rom_t IS ARRAY (0 TO 255) OF std_logic_vector(7 DOWNTO 0);
  SIGNAL rom : rom_t;
  ATTRIBUTE ram_init_file : string;
  ATTRIBUTE ram_init_file OF rom : SIGNAL IS "bootldr.mif";

  SIGNAL rom_en_i : std_logic := '1';
  SIGNAL wr_prev  : std_logic := '1';

BEGIN

  ROM_EN   <= rom_en_i;
  ROM_DATA <= rom(conv_integer(MEM_ADDR(7 DOWNTO 0)));

  PROCESS (CLK)
  BEGIN
    IF rising_edge(CLK) THEN
      IF RESET = '1' THEN
        rom_en_i <= '1';
        wr_prev  <= '1';
      ELSE
        wr_prev <= IO_WR;
        -- control write: disable the overlay
        IF (wr_prev = '0' AND IO_WR = '1' AND IO_ADDR = x"00E2") THEN
          IF DATAIN(0) = '1' THEN
            rom_en_i <= '0';
          END IF;
        END IF;
      END IF;
    END IF;
  END PROCESS;

END;