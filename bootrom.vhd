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
-- ROM image is baked into the constant array below, from tools/bootldr.bin -- see

-- the note on that constant. Assemble tools/bootldr_64k.asm to regenerate it.
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

  -- 1 KB boot ROM, initialised from the assembled bootloader.
  -- Was 256 bytes, which left 28 bytes free -- not enough for a bounded serial
  -- wait plus an SPI-flash fallback loader, so the overlay window grew to
  -- 0xFFC00..0xFFFFF. busdecode's in_overlay test must match this size.
  TYPE rom_t IS ARRAY (0 TO 2047) OF std_logic_vector(7 DOWNTO 0);
  -- Contents baked in from tools/bootldr.bin.
  -- NOT a .mif via ram_init_file: that path produced a ROM Quartus never
  -- reported using and never initialised (0 memory bits, and a warning that
  -- 'rom' was never assigned), which for a boot ROM is fatal and silent. A
  -- constant array always synthesises with its values.
  CONSTANT rom : rom_t := (
    x"FA", x"FC", x"31", x"C0", x"8E", x"D0", x"BC", x"00",
    x"7C", x"B0", x"01", x"E6", x"80", x"31", x"C0", x"8E",
    x"D8", x"BF", x"00", x"70", x"31", x"DB", x"B9", x"00",
    x"01", x"88", x"D8", x"34", x"5A", x"88", x"05", x"47",
    x"FE", x"C3", x"E2", x"F5", x"BF", x"00", x"70", x"31",
    x"DB", x"31", x"D2", x"31", x"F6", x"B9", x"00", x"01",
    x"88", x"D8", x"34", x"5A", x"8A", x"25", x"38", x"E0",
    x"74", x"12", x"08", x"FF", x"75", x"02", x"88", x"E2",
    x"30", x"E0", x"B4", x"00", x"09", x"C6", x"FE", x"C7",
    x"75", x"02", x"FE", x"CF", x"47", x"FE", x"C3", x"E2",
    x"DF", x"08", x"FF", x"74", x"5A", x"B0", x"E1", x"80",
    x"FF", x"10", x"72", x"09", x"B0", x"E3", x"80", x"FF",
    x"80", x"72", x"02", x"B0", x"E4", x"88", x"C6", x"88",
    x"F0", x"E6", x"80", x"BD", x"0C", x"00", x"31", x"C9",
    x"E2", x"FE", x"4D", x"75", x"F9", x"88", x"F8", x"E6",
    x"80", x"BD", x"0C", x"00", x"31", x"C9", x"E2", x"FE",
    x"4D", x"75", x"F9", x"88", x"D0", x"E6", x"80", x"BD",
    x"0C", x"00", x"31", x"C9", x"E2", x"FE", x"4D", x"75",
    x"F9", x"89", x"F0", x"E6", x"80", x"BD", x"0C", x"00",
    x"31", x"C9", x"E2", x"FE", x"4D", x"75", x"F9", x"B0",
    x"E0", x"E6", x"80", x"BD", x"0C", x"00", x"31", x"C9",
    x"E2", x"FE", x"4D", x"75", x"F9", x"EB", x"B8", x"B0",
    x"E2", x"E6", x"80", x"BA", x"F2", x"03", x"B0", x"04",
    x"EE", x"B0", x"02", x"E6", x"80", x"B0", x"03", x"E8",
    x"BB", x"01", x"B0", x"DF", x"E8", x"B6", x"01", x"B0",
    x"03", x"E8", x"B1", x"01", x"B0", x"03", x"E6", x"80",
    x"B0", x"46", x"E8", x"A8", x"01", x"B0", x"00", x"E8",
    x"A3", x"01", x"B0", x"FF", x"E8", x"9E", x"01", x"B0",
    x"00", x"E8", x"99", x"01", x"B0", x"01", x"E8", x"94",
    x"01", x"B0", x"02", x"E8", x"8F", x"01", x"B0", x"80",
    x"E8", x"8A", x"01", x"B0", x"1B", x"E8", x"85", x"01",
    x"B0", x"FF", x"E8", x"80", x"01", x"B0", x"04", x"E6",
    x"80", x"B8", x"00", x"F0", x"8E", x"C0", x"31", x"FF",
    x"E8", x"62", x"00", x"73", x"03", x"E9", x"9A", x"00",
    x"AA", x"B0", x"05", x"E6", x"80", x"B9", x"FF", x"FF",
    x"E8", x"8E", x"01", x"AA", x"E2", x"FA", x"B0", x"06",
    x"E6", x"80", x"BA", x"F4", x"03", x"EC", x"A8", x"10",
    x"74", x"0A", x"A8", x"80", x"74", x"F4", x"BA", x"F5",
    x"03", x"EC", x"EB", x"EE", x"B2", x"01", x"E8", x"F1",
    x"00", x"81", x"FD", x"00", x"D0", x"75", x"03", x"E9",
    x"CE", x"00", x"BB", x"01", x"00", x"E8", x"F8", x"00",
    x"B0", x"07", x"E6", x"80", x"B8", x"60", x"00", x"8E",
    x"C0", x"31", x"FF", x"0E", x"1F", x"BE", x"62", x"F9",
    x"B9", x"0B", x"00", x"F3", x"A4", x"EA", x"00", x"00",
    x"60", x"00", x"BA", x"E2", x"00", x"B0", x"01", x"EE",
    x"EA", x"F0", x"FF", x"00", x"F0", x"52", x"51", x"53",
    x"BB", x"04", x"00", x"31", x"C9", x"BA", x"F4", x"03",
    x"EC", x"24", x"C0", x"3C", x"C0", x"74", x"08", x"E2",
    x"F4", x"4B", x"75", x"EF", x"F9", x"EB", x"05", x"BA",
    x"F5", x"03", x"EC", x"F8", x"5B", x"59", x"5A", x"C3",
    x"E6", x"98", x"EB", x"00", x"EB", x"00", x"53", x"BB",
    x"00", x"10", x"E4", x"99", x"A8", x"80", x"74", x"06",
    x"4B", x"75", x"F7", x"5B", x"EB", x"5C", x"5B", x"E4",
    x"98", x"C3", x"B0", x"0A", x"E6", x"80", x"BA", x"F2",
    x"03", x"30", x"C0", x"EE", x"EB", x"00", x"EB", x"00",
    x"B0", x"04", x"EE", x"B8", x"00", x"F0", x"8E", x"C0",
    x"31", x"FF", x"30", x"C0", x"E6", x"9A", x"B0", x"03",
    x"E8", x"C5", x"FF", x"B0", x"1F", x"E8", x"C0", x"FF",
    x"89", x"F8", x"88", x"E0", x"E8", x"B9", x"FF", x"30",
    x"C0", x"E8", x"B4", x"FF", x"B9", x"00", x"02", x"B0",
    x"FF", x"E8", x"AC", x"FF", x"AA", x"E2", x"F8", x"B0",
    x"01", x"E6", x"9A", x"81", x"FF", x"00", x"02", x"75",
    x"04", x"B0", x"0C", x"E6", x"80", x"85", x"FF", x"75",
    x"C9", x"B0", x"0B", x"E6", x"80", x"B2", x"02", x"E9",
    x"34", x"FF", x"B0", x"C0", x"E6", x"80", x"B2", x"04",
    x"BB", x"04", x"00", x"E8", x"32", x"00", x"EB", x"F2",
    x"B0", x"EF", x"E6", x"80", x"B2", x"03", x"BB", x"04",
    x"00", x"E8", x"24", x"00", x"89", x"E8", x"86", x"C4",
    x"E8", x"4D", x"00", x"89", x"E8", x"E8", x"48", x"00",
    x"EB", x"E6", x"B8", x"00", x"F0", x"8E", x"C0", x"BE",
    x"00", x"C0", x"B9", x"00", x"30", x"31", x"ED", x"30",
    x"E4", x"26", x"AC", x"01", x"C5", x"E2", x"FA", x"C3",
    x"B0", x"B6", x"E6", x"43", x"B0", x"A6", x"E6", x"42",
    x"B0", x"04", x"E6", x"42", x"53", x"E4", x"61", x"0C",
    x"03", x"E6", x"61", x"E8", x"12", x"00", x"E4", x"61",
    x"24", x"FC", x"E6", x"61", x"BB", x"01", x"00", x"E8",
    x"06", x"00", x"5B", x"FE", x"CA", x"75", x"E5", x"C3",
    x"31", x"C9", x"E2", x"FE", x"4B", x"75", x"F9", x"C3",
    x"E6", x"80", x"BB", x"14", x"00", x"31", x"C9", x"E2",
    x"FE", x"4B", x"75", x"F9", x"C3", x"52", x"51", x"53",
    x"88", x"C4", x"BB", x"04", x"00", x"31", x"C9", x"BA",
    x"F4", x"03", x"EC", x"24", x"C0", x"3C", x"80", x"74",
    x"0E", x"E2", x"F4", x"4B", x"75", x"EF", x"5B", x"59",
    x"5A", x"83", x"C4", x"02", x"E9", x"0B", x"FF", x"BA",
    x"F5", x"03", x"88", x"E0", x"EE", x"5B", x"59", x"5A",
    x"C3", x"52", x"51", x"53", x"BB", x"04", x"00", x"31",
    x"C9", x"BA", x"F4", x"03", x"EC", x"24", x"C0", x"3C",
    x"C0", x"74", x"0E", x"E2", x"F4", x"4B", x"75", x"EF",
    x"5B", x"59", x"5A", x"83", x"C4", x"02", x"E9", x"E1",
    x"FE", x"BA", x"F5", x"03", x"EC", x"5B", x"59", x"5A",
    x"C3", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"90", x"90", x"90", x"90", x"90", x"90", x"90", x"90",
    x"EA", x"00", x"F8", x"00", x"F0", x"FF", x"FF", x"FF",
    x"FF", x"FF", x"FF", x"FF", x"FF", x"FF", x"FF", x"FF"
  );

  SIGNAL rom_en_i : std_logic := '1';
  SIGNAL wr_prev  : std_logic := '1';

BEGIN

  ROM_EN   <= rom_en_i;
  ROM_DATA <= rom(conv_integer(MEM_ADDR(10 DOWNTO 0)));

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