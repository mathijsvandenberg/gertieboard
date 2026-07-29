# Status and roadmap

Where the machine actually is, and where it is going. Nothing here is aspirational
marketing: if something is listed as working it has been run on hardware.

## Working

| Feature | Detail |
|---|---|
| **Real CPU** | NEC V20 (µPD70108C-8) on the [top board](hardware.md), FPGA as the surrounding chipset |
| **Runs standalone** | FPGA configures from its own flash, BIOS from the on-board SPI flash, DOS from the USB disk — nothing attached but power and a monitor — [boot](boot.md) |
| **Boots MS-DOS 4.01** | The Dutch release shipped with the Philips P2120, **installed onto `C:` from its original install floppies** — see [storage](storage.md#installing-an-operating-system-onto-it). PC-DOS 3.30 runs too, from a served floppy image |
| **USB hard disk, `C:`** | Bulk-Only Transport and SCSI in the BIOS over the fabric host controller. `FDISK`, `FORMAT`, `CHKDSK` pass; 504 MB addressable — [storage](storage.md) |
| **CGA text** | Modes 0–3, 80×25 and 40×25, 16 colours — [vga](modules/vga.md) |
| **CGA graphics** | Modes 4, 5, 6 — 320×200×4 and 640×200×2 |
| **VGA output** | 640×480 @ 60 Hz on a real monitor, CGA doubled into it |
| **PS/2 keyboard** | Translated to XT scancodes, with a hardware Ctrl+Alt+Del — [ps2_kbd_ppi](modules/ps2_kbd_ppi.md) |
| **Floppy `A:`** | Served from a host over a 1 Mbaud serial link. Absent or muted, it reports NOT READY and the boot moves on — [fdc8272](modules/fdc8272.md) |
| **Floppy `B:`, 1.44 MB** | On the SPI flash; `FORMAT B:` works and the contents survive a reboot — [fixed disk](fixed-disk.md) |
| **8253 PIT** | 18.2 Hz system tick and speaker tone — [timer8253](modules/timer8253.md) |
| **8259A PIC** | Timer, keyboard and floppy interrupts — [int8259](modules/int8259.md) |
| **8237A DMA** | Channel 2 for floppy transfers, channel 0 refresh — [dma8237](modules/dma8237.md) |
| **8255 PPI** | Keyboard port, speaker gate, DIP switches — [ppi8255](modules/ppi8255.md) |
| **PC speaker** | Timer channel 2 gated through the PPI |
| **640 KB RAM** | All 640 KB reported to DOS; the disk write buffer sits in M9K outside it — [mem_hybrid](modules/mem_hybrid.md) |
| **Standalone FPGA config** | `.jic` in the DE0-Nano's EPCS16, no JTAG needed at power-on — [building](building.md) |
| **USB host, full speed** | NRZI, bit stuffing, CRC5/CRC16, SOF, enumeration and bulk transfers, with event counters for diagnosis — [usb_host](modules/usb_host.md) |
| **Keyboard, extended keys** | Arrows, Home/End/PgUp/PgDn, Insert/Delete, right Ctrl, AltGr, keypad Enter — [ps2_kbd_ppi](modules/ps2_kbd_ppi.md) |
| **Runs real software** | Alley Cat, Digger, Sopwith, Pacman, the DOS utilities |

Nothing is currently known-broken. The last open item — booting the BIOS from SPI
flash — closed when the boot ROM stopped reading the image as one 64 KB burst; see
[gotchas](gotchas.md#a-long-spi-read-does-not-come-back-intact).

## Planned

Roughly in the order they are likely to happen. Two budgets to keep in mind: **60 % of
the logic elements** and **70 % of the 608 Kbit of M9K** are already committed. Memory is
still the tighter of the two, so several of these are memory problems before they are
logic problems.

### USB throughput

**Reads are 1.66× faster than they were**, and the remaining work is known. Measured
with [`USBPERF`](tools.md#usbperf--read-benchmark-and-regression-check), which reads a
fixed 256 KB at each transfer size:

| per call | before | after |
|---|---|---|
| 512 B | 49 KB/s | **69 KB/s** |
| 1 KB | 56 | **83** |
| 4 KB | 63 | **101** |
| 32 KB | 65 | **108** |
| 63.5 KB | 65 | **107** |

The gain came from replacing the per-byte `IN`/`STOSB`/`LOOP` copy with a single
`REP INSB` — see [storage](storage.md#the-80186-fast-path). Nothing changed on the
wire: transactions went 22157 → 22164, and the seven extra are exactly the seven extra
NAKs, with the integrity checksum unchanged.

That the numbers converge at 107–108 KB/s says the bottleneck is still the CPU rather
than the bus. What is left, in rough order of return:

1. **Memory-map the packet buffer** into M9K, so the copy becomes `REP MOVSB` from
   memory instead of a port read per byte
2. **A 512-byte hardware buffer**, so one command moves a whole sector rather than
   eight 64-byte packets
3. **DMA**, last — [`dma8237`](modules/dma8237.md) exists, but it is the biggest change
   for the smallest remaining multiple

Writes still use the byte loop. `REP OUTSB` is the same one-line change, but wants a
[`USBSOAK`](tools.md#usbsoak--sustained-write--read--verify) pass on a scratch stick
first, not on the disk with DOS installed on it.

### USB keyboard

The easy one now that the SIE exists. A HID boot-protocol keyboard is one interrupt
endpoint polled every 10 ms with fixed 8-byte reports, and
[`ps2_kbd_ppi`](modules/ps2_kbd_ppi.md) already does the hard part downstream — HID usage
codes to XT scancodes is the same class of translation it performs today, and the
PPI-side interface would not change.

One caveat: most keyboards are **low speed** (1.5 Mbps) and `usb_host` is full-speed
only. So this needs either a low-speed mode in the SIE — a different bit rate, and
keep-alive instead of SOF — or a full-speed keyboard.

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
- **Faster CPU clock.** `c0` is 5 MHz and the socket will take an 8088-2 (8 MHz) or
  8088-1 (10 MHz), so there is headroom on paper. Two things make it a project rather
  than a PLL edit, and neither is optional:

  **Nothing can detect the speed grade.** An 8088, 8088-2 and 8088-1 are electrically
  identical; the grade is a marking on the package and a promise from Intel, exposed
  through no register and no pin. POST can identify an
  [instruction-set class](storage.md#the-80186-fast-path) because that is a difference
  in *behaviour*, but there is no equivalent for speed. Anything here would be a
  stability *trial* — raise the clock, self-test, back off on failure — which also
  means surviving the failure well enough to do the backing off.

  **`c0` is not just the CPU.** [`busdecode`](modules/busdecode.md), the DMA, PIC, PPI,
  FDC, `vga.CLK_CPU`, [`sevenseg`](modules/sevenseg.md), `ctrl_reg` and the boot ROM all
  run on it, and two carry it as a generic: `fdc8272`'s `CLK_FREQ` sets the host link's
  baud divider, so a changed clock silently breaks drive `A:`. Timing would need
  re-closing at the new rate, and the PSRAM path is already the limit at 5 MHz.

  A sensible first step is making `c0` one parameter that every dependent generic
  derives from, so the rate is a single edit rather than six places to keep in step.
- **Composite/RGBI output** alongside VGA, for a period-correct monitor.
- **CP/M-80 software**, using the V20's 8080 emulation mode (`BRKEM`). Needs a host
  program on the DOS side rather than anything in the FPGA — a curiosity the CPU
  happens to make possible. See [hardware](hardware.md#about-the-cpu).

## Related

- [Architecture](architecture.md) — what a new subsystem has to fit into
- [Memory map](memory-map.md) — the address space these would claim
- [Gotchas](gotchas.md) — read before writing any 8088 code
