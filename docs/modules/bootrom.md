# bootrom

Source: [`bootrom.vhd`](../../bootrom.vhd) · Instance `bootrom1` · Clock `c0` (8.33 MHz)
· Loader source: [`tools/bootldr_64k.asm`](../../tools/bootldr_64k.asm)

Holds the **1 KB bootloader** that is overlaid at `0xFFC00`–`0xFFFFF` at reset, and
owns the `ROM_EN` flag that controls the overlay.

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK` | IN | 1 | 8.33 MHz (`c0`) |
| `RESET` | IN | 1 | Active high — re-arms the overlay |
| `MEM_ADDR` | IN | 20 | Memory address; bits 9:0 index the ROM |
| `IO_ADDR` | IN | 16 | I/O address — watches for `0xE2` |
| `IO_WR` | IN | 1 | I/O write strobe, active low |
| `DATAIN` | IN | 8 | CPU write data |
| `ROM_DATA` | OUT | 8 | ROM byte at `MEM_ADDR(9:0)` → `busdecode` |
| `ROM_EN` | OUT | 1 | `'1'` = overlay active → `busdecode` |

## Addresses

| Address | Access | Function |
|---|---|---|
| `0xFFC00`–`0xFFFFF` | R | 1 KB boot ROM, while `ROM_EN = '1'` |
| I/O `0xE2` | W | bit 0 = 1 → clear `ROM_EN`, revealing the PSRAM underneath |

The overlay window itself is enforced by [`busdecode`](busdecode.md):

```vhdl
in_overlay <= '1' WHEN (ROM_EN = '1' AND IOM = '0'
                        AND maddr_l(19 DOWNTO 10) = "1111111111") ELSE '0';
```

**Reads only.** Writes always pass through to PSRAM, which is what lets the
bootloader fill the BIOS image underneath itself while still executing from ROM.

```vhdl
IF RESET = '1' THEN
    rom_en_i <= '1';                                   -- re-arm on every reset
ELSIF (wr_prev = '0' AND IO_WR = '1' AND IO_ADDR = x"00E2") THEN
    IF DATAIN(0) = '1' THEN rom_en_i <= '0'; END IF;   -- one-way switch off
```

Because a reset re-arms it, a hardware Ctrl+Alt+Del or the reset button always
produces a genuine cold boot, re-fetching the BIOS.

## ROM contents are a VHDL constant

```vhdl
TYPE rom_t IS ARRAY (0 TO 1023) OF std_logic_vector(7 DOWNTO 0);
CONSTANT rom : rom_t := ( x"FA", x"FC", ... );
```

> ⚠️ **Do not switch this back to a `.mif` via `ram_init_file`.** That is how it used
> to work, and Quartus reported **0 memory bits** for it, never listed `bootldr.mif`
> as a used source, and warned that `rom` "was never assigned a value". For a boot
> ROM that is a silent, fatal failure mode. A constant array always synthesises with
> its values, verifiable in the report and in the netlist.

To regenerate after editing the loader:

```bash
cd tools
./nasm.exe -f bin bootldr_64k.asm -o bootldr.bin      # 1024 bytes exactly
# then refresh the CONSTANT in bootrom.vhd from bootldr.bin, and rebuild the FPGA
```

## Why 1 KB

It was 256 bytes while the loader only had to fetch the BIOS over serial. That left
**28 free bytes** — not enough for a bounded serial wait plus an SPI-flash reader, so
the window grew to 1 KB.

> The array size in this module and the `in_overlay` test in
> [`busdecode`](busdecode.md) must always agree.

## The loader

`bootldr_64k.asm` is assembled with `CPU 8086` so the assembler cannot silently emit
a newer instruction (see [gotchas](../gotchas.md) — it did exactly that, twice).

Layout inside the 1 KB:

| Offset | Contents |
|---|---|
| `0x000` | `start:` — the loader |
| … | padded with `0x90` |
| `0x3F0` | reset vector: `jmp 0xF000:0xFC00` (physical `0xFFFF0`) |
| `0x3F5`–`0x3FF` | `0xFF` fill |

What it does, and the POST code it shows on the [7-segment](sevenseg.md) display at
each step:

| Code | Step |
|---|---|
| `1` | entered, stack set at `0x7C00` |
| `2` | about to talk to the FDC |
| `3` | `Specify` accepted (ND = 1, non-DMA so no 8237 setup is needed) |
| `4` | `Read Data` issued for cylinder `0xFF`, 128 sectors = 64 KB |
| `5` | first data byte received from the host |
| `6` | all 64 KB received into `0xF0000`–`0xFFFFF` |
| `7` | about to disable the overlay and jump to the loaded BIOS |
| `A` | **no serial host answered** — falling back to the SPI flash |
| `B` | 64 KB read from flash `0x1F0000` |
| `EF` | flash holds no BIOS (no `0xEA` at image offset `0xFFF0`) — halted |

The hand-off copies a tiny trampoline to `0x0060:0x0000` and runs it from low RAM,
because disabling the overlay pulls the ground out from under the ROM you are
executing:

```asm
trampoline:
        mov  dx, 0xE2
        mov  al, 1
        out  dx, al          ; ROM_EN <- 0; 0xFFFF0 is PSRAM now
        jmp  0xF000:0xFFF0   ; the loaded BIOS reset vector
```

See [boot flow](../boot.md) for the whole sequence, including the current state of
the flash fallback.

## Related

- [busdecode](busdecode.md) — enforces the overlay window
- [fdc8272](fdc8272.md) — cylinder `0xFF` and the host protocol
- [flash](flash.md) — the fallback source
- [Boot flow](../boot.md)
