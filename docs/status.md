# Status and roadmap

Where the machine actually is, and where it is going. Nothing here is aspirational
marketing: if something is listed as working it has been run on hardware.

## Working

| Feature | Detail |
|---|---|
| **Real CPU** | NEC V20 (µPD70108C-8) on the [top board](hardware.md), FPGA as the surrounding chipset |
| **Boots PC-DOS 3.3** | From a floppy image served over serial |
| **CGA text** | Modes 0–3, 80×25 and 40×25, 16 colours — [vga](modules/vga.md) |
| **CGA graphics** | Modes 4, 5, 6 — 320×200×4 and 640×200×2 |
| **VGA output** | 640×480 @ 60 Hz on a real monitor, CGA doubled into it |
| **PS/2 keyboard** | Translated to XT scancodes, with a hardware Ctrl+Alt+Del — [ps2_kbd_ppi](modules/ps2_kbd_ppi.md) |
| **Floppy** | Served from a host over a 1 Mbaud serial link — [fdc8272](modules/fdc8272.md) |
| **Fixed disk, 2 MB** | On the SPI flash; FDISK and FORMAT work and partitions survive a reboot — [fixed disk](fixed-disk.md) |
| **8253 PIT** | 18.2 Hz system tick and speaker tone — [timer8253](modules/timer8253.md) |
| **8259A PIC** | Timer, keyboard and floppy interrupts — [int8259](modules/int8259.md) |
| **8237A DMA** | Channel 2 for floppy transfers, channel 0 refresh — [dma8237](modules/dma8237.md) |
| **8255 PPI** | Keyboard port, speaker gate, DIP switches — [ppi8255](modules/ppi8255.md) |
| **PC speaker** | Timer channel 2 gated through the PPI |
| **640 KB RAM** | All 640 KB reported to DOS; the disk write buffer sits in M9K outside it — [mem_hybrid](modules/mem_hybrid.md) |
| **Standalone FPGA config** | `.jic` in the DE0-Nano's EPCS16, no JTAG needed at power-on — [building](building.md) |
| **Runs real software** | Alley Cat, Digger, Sopwith, the PC-DOS utilities |

## Not working yet

| Issue | Status |
|---|---|
| **BIOS boot from SPI flash** | `BIOSFLSH` writes and verifies the copy byte-for-byte, but booting from it produces a corrupted image. The serial path is unaffected. See [gotchas](gotchas.md#currently-open). |

Until that is solved the board still needs a host at power-on for the BIOS, and always
needs one for the floppy.

## Planned

Roughly in the order they are likely to happen. Two budgets to keep in mind: **52 % of
the logic elements** and **70 % of the 608 Kbit of M9K** are already committed. Memory is
the tighter of the two, so several of these are memory problems before they are logic
problems.

### USB keyboard

Both USB ports on the top board are wired **straight to FPGA pins** as raw `D+`/`D-`
pairs — [`USB0_DP`/`USB0_DM`](pinout.md#assigned-but-unused) and `USB1_*`. There is no
host-controller chip, so this means a soft USB host in fabric.

A low-speed (1.5 Mbps) host doing nothing but enumerate one HID boot-protocol keyboard
is the tractable version: fixed 8-byte reports, a single interrupt endpoint, polled at
10 ms. The existing [`ps2_kbd_ppi`](modules/ps2_kbd_ppi.md) already does the hard part
downstream — HID usage codes to XT scancodes is the same class of translation it does
now, and the PPI-side interface would not change.

Needs: a 12 MHz-domain bit-level SIE, NRZI and bit-stuffing, CRC5/CRC16, and enough of
the enumeration state machine to reach `SET_PROTOCOL(boot)`.

### Sound Blaster / AdLib

The pieces this needs are mostly already on the board. [`dma8237`](modules/dma8237.md)
exists and is proven with the floppy, so single-cycle DMA playback has somewhere to
come from, and [`int8259`](modules/int8259.md) can raise IRQ 5.

- **AdLib (OPL2/YM3812)** at I/O `0x388`–`0x389` is the bigger win for the era and is
  self-contained: nine channels of two-operator FM, an exponential/log sine table in
  M9K, and no DMA involved. Many games detect AdLib alone.
- **Sound Blaster DSP** at `0x220` adds the command interface, 8-bit DMA playback on
  channel 1, and the IRQ acknowledge at `0x22E`.

Output would be a sigma-delta or PWM pin on the top board rather than a real DAC.

### EGA

The awkward one, and the reason it is last.

EGA's 640×350×16 needs **four bit planes of 64 KB each — 256 KB, or 2 Mbit**. The whole
device has 608 Kbit of M9K and 70 % of it is spoken for, so planar video memory cannot
live on-chip the way the current [16 KB of CGA VRAM](modules/vga.md) does. It has to be
PSRAM-backed, which puts the scan-out fetch in direct competition with CPU accesses on
the same controller — and the [read cache](modules/mem_hybrid.md) is tuned for CPU
access patterns, not for a raster that streams linearly and must never miss a deadline.

Beyond memory: the sequencer, graphics controller and attribute controller at
`0x3C0`–`0x3CF`, the latch/ALU read-modify-write path that makes planar writes fast,
and a 350-line CRTC mode.

A useful intermediate step is **EGA's 640×200×16 mode alone** (128 KB, two planes'
worth of pressure rather than four) or a plane-per-M9K-block layout at reduced colour
depth, to get the register model and the latch path proven before taking on the
bandwidth problem.

### USB mass storage

Listed for completeness, but this is the hardest item here and the one with the least
favourable ratio of effort to payoff.

A USB HDD or stick is full-speed at minimum (12 Mbps), needs bulk-only transport, SCSI
command wrapping (`INQUIRY`, `READ CAPACITY`, `READ(10)`, `WRITE(10)`), and a real
enumeration stack — a considerably larger soft host than a HID keyboard, driven from
raw pins with no PHY. The 2 MB SPI-flash [fixed disk](fixed-disk.md) already covers the
"storage that survives a reboot" case, so the honest motivation is capacity and the
convenience of moving files on a stick, not capability.

If it happens, doing the USB keyboard first is the right order: it builds the SIE, the
CRCs and the enumeration machinery that this would reuse.

### Publish the schematics

Planned. The board is meant to be built by hand — see
[hardware](hardware.md#built-to-be-soldered-by-hand) — which is only true in practice once the
schematics are in the repository. They will be licensed separately from the code, most
likely under CERN-OHL-P, since MIT does not really fit a PCB.

## Ideas, unscheduled

- **Serial port that actually works** — [`com1_stub`](modules/com1_stub.md) currently
  answers COM1 probes as "absent" on purpose. The board's UART is committed to the host
  link, so a real 8250 would need the second one.
- **Move the erase/program sequence into VHDL** — a ~300-line state machine would make
  block loads roughly tenfold faster, at the cost of every bug meaning a reflash instead
  of a rebuild. The buffer itself is already in M9K; this is the remaining half of that
  idea. Reasoning in [fixed disk](fixed-disk.md#where-the-buffer-lives).
- **Real floppy drive** on a physical connector, instead of serving images.
- **Faster CPU clock** — `c0` is 5 MHz; the PSRAM path is the limit, not the CPU.
- **Composite/RGBI output** alongside VGA, for a period-correct monitor.
- **CP/M-80 software**, using the V20's 8080 emulation mode (`BRKEM`). Needs a host
  program on the DOS side rather than anything in the FPGA — a curiosity the CPU
  happens to make possible. See [hardware](hardware.md#about-the-cpu).

## Related

- [Architecture](architecture.md) — what a new subsystem has to fit into
- [Memory map](memory-map.md) — the address space these would claim
- [Gotchas](gotchas.md) — read before writing any 8088 code
