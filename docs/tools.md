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

### USBSOAK — sustained write / read / verify

The instrument that found the bit-stuffing bug. Every failure in the storage stack looks
identical from DOS — "disk error" — and has been a different bug each time, so this one
is built to tell them apart.

```
usbsoak            one pass, write/read/verify  (destroys data on C:, asks first)
usbsoak 5          five passes
usbsoak r          read-only
```

Five phases per pass at 1, 2, 8, 64 and 127 sectors per command. Three design choices
matter:

- **The verify pattern is derived from each sector's own LBA**, so a read that returns a
  valid sector *from the wrong place* fails. With a constant pattern it would pass, and
  that is exactly the class of bug behind "sector not found".
- **`do_io` has no retries.** The existing retry logic is what hides raw failure rates.
- **A verify failure re-reads the sector once**, which separates corruption on the disk
  from corruption in the read path.

Every failing command prints its own line: LBA, byte offset, expected and actual, and
what that one command cost in NAKs and timeouts. `got − expected = 0x1234 × k` means the
data is *k* sectors stale — the signature that cracked the write bug.

127 is not arbitrary: it is the largest transfer one CBW can carry.

### USBSTAT — controller event counters

Reads the diagnostic window at `0xEF`: frames, CRC/PID errors, timeouts, NAKs, STALLs,
packets in and out, transactions accepted, and software BUSY stalls. `usbstat r` samples
them around a 64-sector read so the deltas can be attributed.

CRC errors against packets moved is the link error rate. NAKs are normal — a device
saying "not yet".

### USBHD / USBWIPE — enumeration state, and clearing a stick

`USBHD` shows how far enumeration got, dumps the descriptors, and probes `INT 13h`
directly. `USBWIPE` zeroes the first 64 sectors so `FDISK` accepts a stick that arrived
with GPT — DOS reads the existing table, does not understand it, and refuses.

### SPIDUMP — read the flash the way the boot ROM does

```
spidump            one continuous burst, as the boot ROM used to
spidump c          a fresh command every 512 bytes
spidump n / s      no gap / a long gap after each write
spidump d          hex-dump the 128 bytes at image offset C000
```

Drives the SPI engine directly at ports `0x98`–`0x9A` and compares 64 KB against the
running BIOS. It counts mismatches at **three alignments** — aligned, lagging by one,
leading by one — so a byte-shift race is distinguishable from genuinely different data,
and the timing variants let a settle-time theory be tested rather than argued.

This is what proved a long SPI read is unsafe on this board: 11256 mismatches streamed,
zero chunked. See [gotchas](gotchas.md#a-long-spi-read-does-not-come-back-intact).

### KBSCAN — raw scancodes

Hooks `INT 09h`, takes each byte straight from port `0x60`, acknowledges exactly as the
BIOS does, and prints it untranslated. Expected on a 101-key board: right arrow
`E0 4D` / `E0 CD`, keypad 6 a bare `4D` / `CD`, AltGr `E0 38` / `E0 B8`.

The arrow keys had been wrong twice, both times because the reasoning rested on an
assumed byte stream rather than a measured one. This settled it in one run.

### MEMQUIZ — memory as this machine reports it

Asks every memory question DOS and games ask, and prints the raw answer to each:
`INT 12h`, the equipment word, `INT 15h AH=88h` and `AH=C0h`, the XMS multiplex call
`INT 2Fh AX=4300h`, the `INT 67h` vector and the `EMMXXXX0` signature behind it, and
the largest block DOS will hand a program.

`MEM` printing a number nobody can explain is not a `MEM` bug — `MEM` prints what it is
told. This prints the same answers one call at a time, with nothing interpreted in
between, and it names the specific failure that produced the historical bad number:

```
INT 15h  AH=88h extended   : AX=8800  CF=0
         -> UNANSWERED: AX came back holding the 8800h we sent.
            Anything that trusts this sees 34816 KB of extended
            memory that does not exist.
```

That line is what an unimplemented `INT 15h` looks like. With the handler in place it
reads `AX=0000` and *answered: no extended memory*.

### INTSPY — unimplemented interrupts

A program that stops dead tells you nothing: it has the screen, DOS is not coming back,
and whatever it asked for last is gone.

INTSPY finds every vector still pointing at the BIOS dummy `IRET`, gives each one its
own twelve-byte stub, and has each stub write **its own vector number to port `0x80`**
before returning exactly as the dummy would have. Registers and flags are untouched, so
it is safe to leave installed.

The [7-segment display](modules/sevenseg.md) is the point. It is not memory and it is
not the screen — it keeps showing the last value written after the CPU has stopped
doing anything useful. Run the program, let it hang, read the digit:

| Display | Meaning |
|---|---|
| freezes on a value | that interrupt is the last thing the program asked for, it is unimplemented, and the program is probably waiting on the answer |
| never leaves the POST code | no unimplemented interrupt was called; the hang is elsewhere, and a whole class of cause is ruled out |

```
intspy          install
intspy d        per-vector counts, if DOS came back
intspy r        remove
```

`INT 1Ch` is deliberately left alone — the BIOS calls it 18.2 times a second, and
hooking it would peg the display at `1C` and hide everything else.

### BIOSSPY — which BIOS service, live

The follow-on question to INTSPY: not *is it stuck on a missing interrupt* but **what
did it last ask the machine for, and is it still asking for anything**.

Hooks nine BIOS services and chains every one straight through, writing one byte to
port `0x80` on the way past — **high nibble the service, low nibble a call counter**.

| High digit | Service | | High digit | Service |
|---|---|---|---|---|
| `1` | video `10h` | | `6` | system `15h` |
| `2` | equipment `11h` | | `7` | keyboard `16h` |
| `3` | memory size `12h` | | `8` | printer `17h` |
| `4` | disk `13h` | | `9` | clock `1Ah` |
| `5` | serial `14h` | | | |

The counter is what makes it readable — a frozen display and a hammered one look
identical without it, and those are opposite diagnoses:

| Display | Meaning |
|---|---|
| low digit racing, high steady | polling that one service forever |
| low digit racing, high varying | **working, just slowly** — wait before calling it a hang |
| both frozen | spinning in its own code; the high digit is the last service it used |

Sampling from a timer hook cannot do this: games take `INT 08h` and `INT 09h` and stop
chaining them. They *call* `10h`/`13h`/`16h`/`1Ah` rather than replacing them, so these
hooks cannot be bypassed.

### FILESUM — is the disk returning the right bytes

```
filesum C:\KEEN4\KEEN4C.EXE
```

Prints a length and an Adler-style checksum pair to compare against a value computed on
the host, off the original file.

USBPERF's integrity check answers a narrower question than it appears to: it reads a
fixed region every run and checks the checksum does not *change*. That catches a read
path that has become unstable, but not one that is reliably wrong — the same bad bytes
every time produce the same checksum and it passes. This compares against ground truth
instead. `s2` accumulates `s1`, so unlike a plain sum it does not forgive bytes that are
right but in the wrong order.

### WAITSTAT — what one memory read costs

`RAMSPEED` compares M9K against PSRAM and reports the difference. That answers
*"which memory is slower"* but not *"is either of them fast"* — and the second turned
out to be the question that mattered, because M9K read only 13% quicker than a serial
PSRAM, which is not what a 60 ns on-chip SRAM should look like beside one.

This times the same loop with and without a memory operand, so each difference isolates
exactly one read:

| | Loop body | Isolates |
|---|---|---|
| A | `mov al,bl` + `loop` | baseline — no data access |
| B | `mov al,[si]` + `loop`, `DS:SI` → M9K | one on-chip read |
| C | `mov al,[si]` + `loop`, PSRAM, **same address** | one guaranteed cache **hit** |
| D | `mov al,bl` + `add si,16` + `loop` | baseline for E |
| E | `mov al,[si]` + `add si,16` + `loop`, PSRAM | 16-byte stride — a guaranteed **miss** |

```
one M9K read          B-A =  6.3 clocks
one PSRAM cache hit   C-A =  6.3 clocks
one PSRAM cache miss  E-D = 36.2 clocks
```

**C is the load-bearing test.** After the first iteration that address is cached, so the
PSRAM interface is not involved at all — whatever it costs above A is overhead *around*
the memory. It came back identical to M9K, and both are below the 11 clocks an 8088
spends on `mov al,[si]` before any waiting. That killed the theory that a wait-state
handshake was taxing every access, and redirected the work to the miss rate. See
[mem_hybrid](modules/mem_hybrid.md).

Read-only throughout: the M9K address is `0000:0600` and both PSRAM addresses are inside
the program's own segment. It prints its load segment first so you can confirm it really
is above `0800h`.

> The reference figure — 11 clocks for `mov al,[si]` versus `mov al,bl` — is an 8088
> number and this is a V20, so treat it as a landmark rather than a verdict. The B-against-C
> comparison is the one that matters and it depends on no timing table at all.

### CRTCTEST — can this card be detected?

Writes CRTC registers and reads them back, which is how software decides a card is
present. Nothing here looks at the picture.

```
  R15 cursor low    readable   write 66 -> read 66   OK
  R15 cursor low    readable   write 99 -> read 99   OK
  R14 cursor high   6 bits     write 66 -> read 26   OK
  R10 cursor start  write-only write 55 -> read 00   OK
```

Two patterns go to R15 because a stuck bus can match one by luck. The `00` expected from
R10 matters as much as the values that echo — a board answering `55` there would be
answering, but not like a 6845. Before [`crtc6845`](modules/crtc6845.md) existed every
line read `FF`, and Prince of Persia and Keen 4 both refused to start.

### VIDSPY — did the video call return?

`BIOSSPY` can tell you the last service used was video. It cannot tell *"the call
returned and the program then spun"* from *"the BIOS never came back"*, because it marks
a call on the way in and chains away. This marks both ends.

Instead of chaining, the stub invokes the real handler as a subroutine — `PUSHF` then a
far `CALL` is exactly the frame an `INT` builds — so control comes back and the return
can be recorded. On the display: `00`–`1F` entering that function by its real `AH`, `Ex`
on return. Frozen on a low value means the BIOS handler for that `AH` never came back.

`vidspy t` shows the timer tick instead, in a separate run — they compete for one
display, and an 18 Hz heartbeat would overwrite the video state within a tick.

### PITTEST — does IRQ0 survive being reprogrammed?

The BIOS sets timer 0 once at 18.2 Hz and never touches it again, so this board had been
tested at exactly one divisor out of 65536 — and it is the one value no game uses. Every
id engine reprograms counter 0 to a few hundred Hz and drives its whole sense of time
from the result.

Six divisors, counted over a fixed amount of work, timers and vector restored on exit.
Every row must be non-zero; a zero is a divisor at which the board stops delivering IRQ0.

> It also turned up a real oddity: divisor **`0x8000` runs at half rate**. Not a problem
> for any game, since none picks it, but it is genuinely anomalous and unexplained.

### MEMTOP — the memory a large program actually gets

`MEMTEST` covers `0x20000`–`0x7FFFF`. The top 128 KB of conventional memory had never
been tested by anything on this board, and it is exactly what a 500 KB game fills — DOS,
`COMMAND.COM` and every utility here live below it and would not notice if it were made
of tin.

Asks DOS for the largest free block so the range is the same memory a large program
gets, and **fills everything before verifying anything**: testing chunk by chunk passes
on aliased memory, because the write that lands on top of an earlier chunk is never
checked. The pattern is the address itself, then the whole thing again inverted.

### ADLIBCHK — bench test for the AdLib

A game is a bad first test of new hardware: if it stays silent you cannot tell whether
the card was not detected, was detected but got no notes, or got notes that came out
inaudible. Four stages, so a failure says where — detection (with both status bytes
printed), a chromatic scale, a chord, and a per-channel sweep.

It writes a real OPL2 patch to registers `0x20`–`0xE0` even though
[`opl2_lite`](modules/opl2_lite.md) ignores every one of them. That is deliberate: the
same binary is then valid on a genuine AdLib card, and a tool that only works on the
thing it is testing is not a test.

### ADLIBSNG — three voices, for the things a scale hides

A scale sounds fine when the octaves are wrong and a sweep sounds fine when the timing
is. Music does not let either past. Melody, bass, and the bass doubled an octave up —
three simultaneous channels across three blocks, keeping the PWM mixer under changing
load. Listen for wrong octaves, notes that never release, and the bass dropping out when
the melody gets busy.

```
adlibsng          play once
adlibsng r        repeat until a key is pressed
```

### BIOSFLSH — write the BIOS to flash

Copies the running BIOS (`F000:0000`, 64 KB) into the reserved top of the flash through
ordinary `INT 13h` writes **to drive `B:`**, then reads it all back and compares. No
filename to get wrong, and the copy is by construction the BIOS you just booted.

Nothing is hardcoded: the reserved region comes from the chip size POST detected
(BDA `40:E4`) and the CHS for every transfer from what `INT 13h AH=08` reports. An
earlier version addressed cylinder 31 of a geometry the drive no longer had, on a drive
letter the flash no longer used — and so wrote 64 KB of BIOS onto the USB disk instead.

It also refuses to flash an image it cannot trust. The F-segment is PSRAM, not ROM, so
the running BIOS can be scribbled on between POST and running the tool. POST publishes a
checksum of the code region at BDA `40:B8`; `BIOSFLSH` recomputes it and stops if the two
disagree. See [storage](storage.md#drive-b--the-spi-flash).

### SPLASH — CGA splash screen

`Gertieboard` as graffiti on a brick wall, in CGA mode 4. Built by
`tools/mksplash.py`, which writes a run-length encoded framebuffer and a PNG preview.

Two CGA details it has to respect: black as the background colour makes the heavy black
outline free, leaving all three palette entries for the artwork; and CGA pixels are not
square, so the art is composed at 320×240 and squashed to 320×200 on export or the
lettering comes out elongated.

### USBPERF — read benchmark and regression check

```
usbperf            512 sectors per phase (256 KB)
usbperf 4          four times that, for finer resolution on a fast build
```

**Read-only** — it never issues `AH=03`, so it is safe with DOS installed on `C:`.
`USBSOAK` is the one that writes.

Three things, and the first matters most:

- **integrity** — a checksum of a fixed region, read identically every run. A faster
  driver that returns different bytes is not a faster driver, and this is what catches
  that. It must not change across builds.
- **throughput** at five transfer sizes, every phase moving the same 256 KB so the
  columns compare directly. One averaged number would hide a change that helps large
  transfers and hurts small ones; five columns show it as numbers moving in opposite
  directions.
- **cost** — controller transactions and NAKs over the whole run. These should not move
  when only the CPU-side copy changes. When `REP INSB` went in, transactions went
  22157 → 22164 and NAKs 21 → 28 — the same seven, so nothing happened on the wire.

Timing is the 18.2 Hz tick, so phases are sized to run a couple of seconds. Pass a
multiplier once reads get fast enough that they do not.

### 186BOOST — turn the 80186 fast path off

POST enables the fast path by itself when the CPU supports it, so this is not needed to
get the speed. What it is for is taking it **away**: benchmarking one path against the
other on the same boot is the only honest way to measure what a change is worth.

```
186boost           report the CPU class and which path is active
186boost off       back to the 8086-safe byte loop
186boost on        re-enable it
186boost on /f     enable without the CPU test -- hangs the machine if wrong
```

It runs the same probe POST does: execute `INSB` and see whether it happened, rather
than inferring the answer from some other behaviour. See
[storage](storage.md#the-80186-fast-path) for how that is made safe on a CPU where the
opcode means something else entirely.

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
