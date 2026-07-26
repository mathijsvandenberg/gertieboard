# Tools

## Host loader

The board has no floppy drive and no ROM, so a host program supplies both. It serves:

- the **BIOS image** on the reserved cylinder `0xFF` (see [boot flow](boot.md))
- **floppy sectors** from a disk image, using the geometry it detects from the file size

### GertieBoardLoader (current)

**<https://github.com/mathijsvandenberg/gertieboardloader>**

A C# WinForms application. It has a `FileSystemWatcher` on both the image and the BIOS
file, so **a rebuild is picked up automatically** — no restart needed. That single
detail is what makes BIOS work bearable; see the `floppy_host.py` warning below for
what the alternative costs.

### floppy_host.py (superseded)

```bash
python tools/floppy_host.py --port COM5 --image dos33-xtpro.img --bios xtbios_claude.64k
```

> ⚠️ This script reads the BIOS **once at startup** and caches it. After rebuilding the
> BIOS you must **restart it**, or you will keep serving the old image while the new one
> sits on disk looking correct. That cost two days once.

### Protocol

```
READ :  FPGA -> host : 0x33 0x01 C H R
        host -> FPGA : <512 data bytes>

WRITE:  FPGA -> host : 0x33 0x02 C H R <512 bytes>
        host -> FPGA : 0x06

C = 0xFF  ->  serve from the BIOS image at offset (R-1) * 512
```

**1 Mbaud.** If the host has to be set to 500000 to work, `c0` is running at 2.5 MHz
instead of 5 MHz — `fdc8272`'s `BAUD_DIV = CLK_FREQ / BAUD` scales the real rate
directly.

## DOS diagnostics

All are small `.COM` files on the boot floppy. Several write progress codes to port
`0x80`, which appear on the [7-segment display](modules/sevenseg.md) — useful when
output stops.

### HDTEST — fixed disk

Seven tests of the [fixed disk](fixed-disk.md). Expected: all PASS.

```
geometry C x H x S             : 31 x 4 x 32
1 read LBA 0                   : PASS
2 erased flash reads 0xFF      : PASS
3 multi-sector read, erased C30: PASS
4 same sector twice matches    : PASS
5 write 8 sectors + read back  : PASS
6 survives eviction (flushed)  : PASS
7 write committed on return    : PASS
```

Tests 6 and 7 are the valuable ones — see
[fixed disk](fixed-disk.md#verification) for why. It sets BDA `0x40:75` on entry and
deliberately **leaves it set**.

### HDSTEP — one INT 13h call in isolation

Makes a single `AH=08` call with 7-segment markers on both sides, and prints the
returned registers. Written to resolve a contradiction where the BIOS marker said it
received `AH=08` and the disassembly said that path must return, yet it never did.

| Code | Meaning |
|---|---|
| `11` | about to enable the disk |
| `12` | about to execute `INT 13h` |
| `08` | BIOS handler entered (raw `AH`) |
| `B8` | BIOS `.h_params` about to return |
| `13` | control returned to the tool |
| `14` | finished |

The last code shown says exactly where control was lost. Expected output:

```
returned.  CF=0  AH=00  CH=1F  CL=20  DH=03  DL=01
```

### MEMTEST — memory integrity

Four tests, increasing in specificity:

| # | Test | Catches |
|---|---|---|
| 1 | Unique pattern over 384 KB (`0x20000`–`0x7FFFF`) | bit errors, address aliasing |
| 2 | Cache thrash — 8 addresses on 8 distinct 16-byte lines against a 4-line cache | broken eviction or a missing write-invalidate |
| 3 | 16-bit words straddling cache-line boundaries | operands spanning two lines |
| 4 | **BIOS checksum stable ×8** | unreliable code fetch |

Test 4 is the one to reach for when behaviour makes no sense: the F-segment is
read-only at runtime, so all eight checksums *must* match. A stable checksum (this
machine reports `D30F`) rules out PSRAM and the read cache as suspects — which is
exactly what it did once, redirecting an investigation to the real cause.

### RAMSPEED — memory latency

Times an identical `rep lodsb` sweep over 32 KB, once from on-chip M9K and once from
PSRAM. Instruction fetch and loop overhead are identical, so the **difference** isolates
the per-byte memory penalty. It then sweeps `CTRL` (I/O `0xE4`) values with an integrity
check.

Measured, with the read cache:

```
M9K   (0000:0000, on-chip) ticks = 25
PSRAM (2000:0000)          ticks = 29
extra per-byte cost        ~ 280 ns
```

Before the cache that was 43 ticks and 1260 ns — PSRAM went from 72 % slower than
on-chip RAM to 16 % slower.

> It runs **from** PSRAM, so a bad `CTRL` value hangs it. The last value printed is the
> culprit; reset recovers because [`ctrl_reg`](modules/ctrl_reg.md) reloads its default.

### CGATEST 1–5 — video

The staged tests that verified the whole CGA path:

| Tool | Tests |
|---|---|
| `CGATEST` | Direct `0x3D8`/`0x3D9` pokes — hardware only, bypassing the BIOS: solid colour, colour bars, interleave banks |
| `CGATEST2` | Same via `INT 10h` mode-set, so it exercises the BIOS instead |
| `CGATEST3` | Reprograms the PIT to ~1 kHz and hooks `INT 08h` — proves the timer still fires |
| `CGATEST4` | Digger's exact `0x3DA` retrace spin, with a timeout so a stuck bit reports instead of hanging |
| `CGATEST5` | `rep movsw` writes, VRAM read-back in graphics mode, and masked read-modify-write sprites |

`CGATEST5` matters most: earlier tests only used `rep stosb` with immediate values,
while real games use word moves from RAM and masked sprites that depend on **read-back**
in graphics mode.

> With palette 0 selected (`0x3D9 = 0x01`), the bars are green / red / brown / blue —
> **not** cyan / magenta / white. Getting that expectation wrong once caused a correct
> result to be reported as a failure.

### USBTEST — USB host controller

Nine checks, ordered by what can actually fail, stopping at the first failure rather
than reporting a cascade of consequences. Expected with a stick plugged into USB0:

```
1  registers respond            : PASS
1b buffer pointer per write     : PASS
2  48 MHz PLL locked            : PASS
3  idle line state (unplugged)  : PASS
   D+/D- read 01 — idle J: full-speed device attached
4  device detected              : PASS
5  SOF generator running        : PASS
6  bus reset, device survives   : PASS
7  GET_DESCRIPTOR at address 0  : PASS
8  SET_ADDRESS(1)               : PASS
9  full descriptor at address 1 : PASS
   VID:PID = 08EC:0008
   class   = 00 (per interface)
   ep0 max packet = 40
```

`class = 00` is correct for mass storage — the class is declared at the *interface*
level, not the device level. `ep0 max packet = 40` (64 bytes) confirms full speed.

Two of these earn their place:

**1b** writes 8 bytes and checks the buffer pointer reads exactly 8. A pure software
check of the register interface, and it fails loudly if a write fires more than once per
bus cycle — which is what corrupted the first working SETUP packet. Much better than
discovering it as a STALL five tests later.

**3** interprets the line state rather than just testing it: `00` is a bare bus, `01` a
full-speed device holding D+ up through its 1.5K, `02` the same for low speed. Only `03`
is impossible, and that is the reading that means the pulldowns or the wiring are wrong.

> When a transfer fails, the raw **PID** of whatever came back is printed next to the
> decoded status, and the message says which *stage* failed. "The SETUP stage failed" and
> "the SETUP stage was ACKed but the IN data stage failed" point at completely different
> halves of the problem.

### BIOSFLSH — write the BIOS to flash

Copies the running BIOS (`F000:0000`, 64 KB) into flash `0x1F0000` through ordinary
`INT 13h` writes to cylinder 31, then reads it all back and compares. No filename to
get wrong, and the copy is by construction the BIOS you just booted. See
[fixed disk](fixed-disk.md#writing-the-bios-copy).

### Older utilities

`IRQTEST`, `IRQTEST_CHK`, `IRQTEST_M0`, `MAPTEST` — interrupt-level and memory-map
probes from earlier bring-up. `PHILIPS.ASM` is an `ndisasm` dump of a reference BIOS
kept for comparison, not source.

## Writing your own

Two rules, both learned the hard way:

> **`CPU 8086`.** NASM will otherwise silently emit a 386 encoding for a conditional
> jump whose target is out of short range — and that encoding is not a branch on this
> CPU, nor on a real 8088. See [gotchas](gotchas.md).
>
> Every `.asm` file in `tools/` now carries it. Adding it to the sixteen that did not is
> what surfaced the six 80186 instructions described there, so put it in a new file
> before writing the code, not after.

> **Make a test's PASS mean something.** An early `HDTEST` reported PASS on tests that
> were silently falling through to the *floppy* handler, because the fixed-disk hook was
> compiled out. Check data, not just return codes — test 2 works precisely because a
> blank chip must read `0xFF`, so it verifies real data movement.

## Related

- [Building](building.md) — how to assemble these and get them onto the floppy image
- [Fixed disk](fixed-disk.md), [BIOS](bios.md) — what they test
- [Status and roadmap](status.md) — what is verified working
- [Gotchas](gotchas.md)
