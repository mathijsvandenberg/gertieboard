# Building

Three separate build products, each with its own toolchain:

| Product | From | With |
|---|---|---|
| FPGA bitstream | `*.vhd`, `*.vhdl`, `gertieboard.qsf` | Quartus |
| BIOS image | `tools/xtbios_src.s` | GNU `as`/`ld` (via WSL), then `make64k.py` |
| DOS utilities | `tools/*.asm` | NASM |

## Toolchain

| Tool | Version used | Path |
|---|---|---|
| Quartus Prime Lite | 25.1std | `C:\altera\25.1std\quartus\bin64\` |
| GNU as / ld | binutils 2.38 (Ubuntu, under WSL) | `wsl as`, `wsl ld` |
| NASM | 3.01 | `tools/nasm.exe` |
| Python | 3.x | for the helper scripts |
| ndisasm | with NASM | `tools/ndisasm.exe` — invaluable for checking encodings |

## FPGA

```bash
cd /c/altera/gertieboard
/c/altera/25.1std/quartus/bin64/quartus_map.exe gertieboard    # analysis & synthesis
/c/altera/25.1std/quartus/bin64/quartus_fit.exe gertieboard    # place & route
/c/altera/25.1std/quartus/bin64/quartus_asm.exe gertieboard    # bitstream
/c/altera/25.1std/quartus/bin64/quartus_sta.exe gertieboard    # timing analysis
```

Output: `output_files/gertieboard.sof`.

Target: **Cyclone IV E `EP4CE22F17C6`**. Top-level entity `gertieboard`, sources listed
in [`gertieboard.qsf`](../gertieboard.qsf).

### Expected results

| Metric | Value |
|---|---|
| Logic elements | 13 450 / 22 320 (60 %) |
| Memory bits | 425 984 / 608 256 (70 %) |
| PLLs | 2 / 4 |
| Pins | 78 / 154 |
| Worst-case setup slack | +0.64 ns |
| Worst-case hold slack | +0.36 ns |
| Fitter warnings | 7 |

Where the logic goes, largest first: `fdc8272` 5881, `vga` 2047, `usb_host` 1962,
`psram_ctrl` 1114, `dma8237` 725, `bootrom` 271, `m9k_mem` 50. The serial floppy
controller and the USB host together are more than half the design.

A clean build is 0 errors with those warning counts. Every slack must be **positive** —
negative slack on this design is not a rounding detail, it is the failure mode that
stalled the project for four years. If the fitter warning count jumps,
check for new unmatched SDC filters:

```bash
quartus_sta gertieboard 2>&1 | grep "could not be matched"     # must be empty
```

### Two things that silently break the build

> **Instance names are load-bearing.** [`gertieboard.sdc`](../gertieboard.sdc)
> references the PLL by instance path (`pll1|altpll_component|...`). Renaming a
> top-level instance drops the generated clock and the async clock groups from timing
> analysis — it then "passes" while being under-constrained.

> **Two instances need generic maps.** `fdc8272` (`CLK_FREQ`, `BAUD`) and
> `ps2_kbd_ppi` (`CLK_FREQ_HZ`) have entity defaults that are wrong for this board and
> fail *quietly*. See [architecture](architecture.md#generics-that-must-match-the-clock).

## BIOS

```bash
bash tools/mkbios.sh                    # -> xtbios_claude.bin + xtbios_claude.64k
```

Do not run the steps by hand. The script chains assemble → link → expand → verify under
`set -e`, and checks that the `.bin` is exactly 8192 bytes, the `.64k` is 65536, the
image sits at F-segment offset `0xE000`, the reset vector at `0xFFF0` is a far jump into
segment `F000`, and everything below `0xE000` is `0xFF` fill. It prints `BUILD OK` only
if the `.64k` was genuinely built from that `.bin`.

> It exists because a hand-built chain failed silently once: a `grep` in the middle
> returned non-zero, the `&&` short-circuited, `make64k.py` never ran, and a two-day-old
> `.64k` kept being served while the freshly built `.bin` looked perfect. Every apparent
> fix changed nothing.

The BIOS source pins the CPU with `.arch i8086` — see [gotchas](gotchas.md).

## Boot ROM

The bootloader lives in the **bitstream**, not the BIOS image, so changing it means a
full FPGA rebuild:

```bash
cd tools
./nasm.exe -f bin bootldr_64k.asm -o bootldr.bin     # exactly 1024 bytes
# refresh the CONSTANT rom array in ../bootrom.vhd from bootldr.bin
# then rebuild the FPGA
```

`bootldr_64k.asm` uses NASM's `CPU 8086` directive for the same reason the BIOS uses
`.arch i8086`.

> Do **not** revert `bootrom.vhd` to a `.mif` via `ram_init_file`. Quartus reported 0
> memory bits for that, never listed the MIF as a used source, and warned that `rom`
> was never assigned — a silent, fatal failure for a boot ROM. See
> [bootrom](modules/bootrom.md).

## DOS utilities

```bash
cd tools
./nasm.exe -f bin hdtest.asm -o hdtest.com
```

Getting a `.COM` onto the boot floppy: there is no `mtools` here, so the repo uses a
small inline Python FAT12 writer that injects the file into
`tools/dos33-xtpro.img` — find a free cluster, write the data, set both FAT copies,
add a root-directory entry, and read it back to verify. Look at the injection snippets
in the session history, or use `GertieBoardLoader`'s own editor.

> **Add `CPU 8086` to any new DOS utility.** They run on the same 8088 and will hit the
> same opcode trap if a jump ever goes out of short range.

## Programming the board

### FPGA RAM — during development

```bash
quartus_pgm -m jtag -o "p;output_files/gertieboard.sof"
```

Lost on power-off, which is exactly what you want while iterating.

### Configuration flash — for standalone boot

```bash
bash tools/mkjic.sh                                            # -> gertieboard.jic
quartus_pgm -m jtag -o "ipv;output_files/gertieboard.jic"
```

Then **power-cycle**: the DE0-Nano loads from its EPCS16 at power-up, so no JTAG RAM
load is needed any more.

`mkjic.sh` runs `quartus_cpf -c -d EPCS16 -s EP4CE22F17C6`, and refuses to run if the
`.sof` is older than any FPGA source, or if the output size does not match the chosen
EPCS device (2 MiB for EPCS16). Pass a different device as an argument if needed:

```bash
bash tools/mkjic.sh EPCS64
```

> Both guards are deliberate. Committing a stale bitstream to configuration memory is
> the same trap as the stale BIOS image, with a slower feedback loop.

### BIOS — served or flashed

While developing, the [host loader](tools.md) serves the BIOS over serial and picks up
rebuilds automatically. To make the board standalone, run `BIOSFLSH` once to copy the
running BIOS into the flash — see [boot flow](boot.md).

## Helper scripts

| Script | Purpose |
|---|---|
| [`tools/mkbios.sh`](../tools/mkbios.sh) | Build and verify the BIOS images |
| [`tools/mkjic.sh`](../tools/mkjic.sh) | Convert `.sof` → `.jic` with staleness and size checks |
| [`tools/make64k.py`](../tools/make64k.py) | Expand a small BIOS image into a full 64 KB F-segment, top-aligned |
| [`tools/mkmif.py`](../tools/mkmif.py) | Binary → Quartus `.mif` (legacy; the boot ROM now uses a constant) |
| [`tools/mkrom.py`](../tools/mkrom.py) | Binary → VHDL constant array |
| [`tools/mkfont_p2120.py`](../tools/mkfont_p2120.py) | Philips P2120 character ROM → `font.vhd` + `tools/font8x8.bin` |
| [`tools/floppy_host.py`](../tools/floppy_host.py) | Python host loader (superseded by GertieBoardLoader) |

## Build artefacts and `.gitignore`

Ignored: `output_files/`, `db/`, `incremental_db/`, `*.sof`, `*.jic`, `*.bak`, `*.rpt`,
disk images (`*.img`, `*.IMA`), tool executables (`*.exe`), and `tools/` build outputs
(`*.bin`, `*.64k`, `*.com`). `tools/font8x8.bin` is an explicit exception — it is a build
*input*, `.incbin`'d into the BIOS.

## Related

- [Architecture](architecture.md) — what the constraints are protecting
- [Tools](tools.md) — the host loader and DOS diagnostics
- [Gotchas](gotchas.md) — the failures these guards exist to prevent
