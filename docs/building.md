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
bash tools/mkfpga.sh
```

Output: `output_files/gertieboard.sof` (JTAG, volatile) **and**
`output_files/gertieboard.jic` (EPCS16, survives a power cycle).

Use the script rather than the four commands below it. It runs the same flow and then
**refuses** on three things: a stage that did not report success, any negative slack, and
a `.sof` older than the newest source file. If it prints `BUILD OK`, the bitstream on
disk really is the design in the working tree and it really does meet timing.

Each refusal is there because the corresponding mistake was made, more than once:

- `quartus_map` failed on a VHDL error, the `&&` chain stopped correctly — and
  `output_files/` still held the reports and `.sof` from the *previous* run. Every number
  read from them was real, current-looking, and about a different design. The only tell
  was a resource count that had not changed after adding a port, a synchroniser and reset
  gating. So the script **deletes** the artefacts before claiming to produce them.
- A `.sof` was programmed that was two clock rates out of date, and an hour went into
  testing 8.333 MHz while believing it was 6.25.
- A build closed timing at −0.037 ns and nobody noticed, because the summary was read for
  the frequency and not for the slack.

The `.jic` is produced in the same run, by calling `mkjic.sh` rather than repeating it.
That is the copy the board *boots* from, so leaving it a build behind is the same stale
artefact trap — only surviving a power cycle.

<details>
<summary>The underlying commands</summary>

```bash
cd /c/altera/gertieboard
/c/altera/25.1std/quartus/bin64/quartus_map.exe gertieboard    # analysis & synthesis
/c/altera/25.1std/quartus/bin64/quartus_fit.exe gertieboard    # place & route
/c/altera/25.1std/quartus/bin64/quartus_asm.exe gertieboard    # bitstream
/c/altera/25.1std/quartus/bin64/quartus_sta.exe gertieboard    # timing analysis
```
</details>

Target: **Cyclone IV E `EP4CE22F17C6`**. Top-level entity `gertieboard`, sources listed
in [`gertieboard.qsf`](../gertieboard.qsf).

### Expected results

| Metric | Value |
|---|---|
| Logic elements | 8 588 / 22 320 (38 %) |
| Memory bits | 300 160 / 608 256 (49 %) |
| PLLs | 2 / 4 |
| Pins | 78 / 154 |
| Worst-case setup slack | +1.68 ns |
| Worst-case hold slack | +0.29 ns |
| Worst slack of any kind | +0.14 ns |
| Fitter warnings | 7 |

Where the logic goes, largest first: `vga` 2132, `psram_ctrl` 1899, `usb_host` 884,
`opl2_lite` 731, `dma8237` 723, `fdc8272` 548, `ps2_kbd_ppi` 411, `timer8253` 407,
`bootrom` 312.

> The totals dropped sharply — from 13 450 LEs and 70 % of the M9K — when conventional
> memory moved wholly into PSRAM and the [memory map was unified](../memmap.vhd). The
> memory bits follow directly from that. The **logic** drop is larger than that change
> accounts for and has not been explained; every module is present and the per-module
> figures sum to the total, so it is recorded here as an open question rather than a
> result to rely on.

`mkfpga.sh` refuses on *any* negative slack, so "worst slack of any kind" is the number
that gates a build — it includes minimum-pulse-width and recovery/removal checks, not
just setup and hold.

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

Do not run the steps by hand. The script chains check → assemble → link → expand →
verify under `set -e`, and checks that the `.bin` is exactly 16384 bytes, the `.64k` is
65536, the image sits at F-segment offset `0xC000`, the reset vector at `0xFFF0` is a far
jump into segment `F000`, and everything below `0xC000` is `0xFF` fill. It prints
`BUILD OK` only if the `.64k` was genuinely built from that `.bin`.

It runs [`tools_equcheck.py`](../tools/tools_equcheck.py) over the source **first**, and
refuses to build if any `.equ` is used above its definition — GNU `as` assembles such a
symbol as a memory operand rather than an immediate, silently, and that has cost two
hardware debugging sessions. It currently reports 51 symbols, all defined before first
use.

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
./nasm.exe -f bin speed.asm -o speed.com
```

Getting a `.COM` onto the boot floppy: there is no `mtools` here, so use
[`tools/fatput.py`](../tools/fatput.py).

```bash
python tools/fatput.py tools/dos33-xtpro.img tools/hdtest.com
python tools/fatput.py tools/dos33-xtpro.img tools/hdtest.com --as HDTEST.COM
python tools/fatput.py tools/dos33-xtpro.img --list
```

Everything comes from the BPB in the boot sector, so it works on a 360K, 720K or
1.44M image without being told which. An existing file of the same name is replaced
and its old cluster chain freed, so a rebuild loop does not leak space. After writing
it **reads the file back through the directory entry and cluster chain** and compares
— a silent mis-write here would otherwise look exactly like a bug in the program being
tested. `GertieBoardLoader`'s own editor works too.

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
