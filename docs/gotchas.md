# Gotchas

Failures that cost days on this project. Every one was invisible to reading the source,
and several were invisible to reading the *disassembly* too.

The common thread: **when the code, the disassembly and the tests all agree but the
hardware disagrees, stop re-reading and start measuring.**

---

## The 8088 opcode trap

**This is the one that matters most. It happened twice.**

Both assemblers silently upgrade an out-of-range conditional jump to a 386 encoding:

```asm
je  far_label          ; target beyond +/-127 bytes
```

becomes `0F 84 rel16` — `JZ rel16`, a 386 instruction. On an 8088, **opcode `0F` is
`POP CS`**. It pops garbage into the code segment and execution vanishes. Worse, it is
**not a branch at all** on this CPU, so it fires *unconditionally*, regardless of flags.

### Why it is so hard to spot

- The source looks completely correct
- `ndisasm` cheerfully prints `jz 0x16ed` — the encoding is only wrong for *this* CPU
- `MEMTEST` reports PSRAM and code fetch perfectly stable
- 7-segment markers show a straight-line routine being entered and never finishing

Every check looks at the *logic*. None looks at the *encoding*.

### The fix — pin the CPU in every assembly file

```asm
.arch i8086          ; GNU as  (tools/xtbios_src.s)
CPU 8086             ; NASM    (tools/bootldr_64k.asm, and every .COM)
```

With that set, the assembler both **errors** on newer instructions and emits the correct
long-branch pattern itself (`cmp` / `jnz skip` / `jmp target`).

### Related: shifts by an immediate greater than 1

```asm
shr al, 4            ; 80186+ !  encodes as C0 E8 04
```

Use `mov cl, 4` / `shr al, cl`, or repeated single-bit shifts if `CL` is busy. Pinning
the architecture catches this too — it found a `shr al, 4` that had been sitting in the
graphics-mode glyph renderer, meaning every character drawn in a CGA graphics mode
executed an invalid instruction.

### Checking a built image

```bash
python3 -c "
d=open('xtbios_claude.bin','rb').read()
print([hex(i) for i in range(len(d)-1) if d[i]==0x0F and 0x80<=d[i+1]<=0x8F])"
```

Beware false positives — `0F` is also a common `jnz` displacement. Confirm with
`ndisasm` before believing it.

---

## Stale build artefacts

A hand-built BIOS chain looked like this:

```bash
ld ... -o xtbios.bin 2>&1 | grep -v 'cannot find entry' && python make64k.py ...
```

The `grep` filtered every line, so it **exited non-zero**, the `&&` short-circuited, and
`make64k.py` never ran. The `.bin` was rebuilt correctly while a **two-day-old** `.64k`
kept being served. Every fix appeared to change nothing.

**A `grep` that matches nothing returns failure.** Never chain a build step after one.

Compounding it: the host loader (`floppy_host.py`) reads the BIOS **once at startup**, so
a rebuild is ignored until it is restarted. GertieBoardLoader watches the file and
reloads automatically.

**Fixes:** [`tools/mkbios.sh`](../tools/mkbios.sh) and
[`tools/mkjic.sh`](../tools/mkjic.sh) do everything under `set -e` and then *verify the
artefact* — sizes, placement, reset vector, and that the output was genuinely built from
the input.

**Make the screen tell you which build is running.** A hardcoded memory-size string once
said 632 KB while the BDA said 640, so the POST screen was useless as a version
indicator and sent an investigation down a false path.

---

## Verifying a fix by grepping for a pattern that already existed

Twice, a scripted patch silently did not apply because the anchor text had changed
(differing whitespace, or an inserted debug block). The first time, the "verification"
searched the built image for `cmp byte [0xEC],0` — which **already existed elsewhere** as
an unrelated branch. It reported PASS for a fix that was not there.

**Verify a change by checking the source for the new construct *and* disassembling the
actual call site.** Not by grepping for a byte pattern that could pre-date the edit.

---

## Instrumentation that hides information

A debug marker printed `(AH & 0x0F) | 0xA0`. Seeing `A8` was taken to mean `AH = 0x08` —
but `0x18`, `0x88` and `0x98` fold to the same thing, and those fall through to an
unsupported-function path that wrote **no marker at all**.

Combined with a hardware detail — [`sevenseg`](modules/sevenseg.md) only re-latches when
the value **changes**, so a retry loop writing one code produces a rock-steady display
indistinguishable from a halt — this pointed the investigation at entirely the wrong
half of the system for several rounds.

**Print raw values. Give every exit path a marker. A silent path is indistinguishable
from a hang.**

---

## Answering a probe half-truthfully

`INT 13h AH=08` returned **`CF=0` (success)** together with **`DL=0` (zero drives)**.
DOS took the success at face value, decided a disk at `0x80` was real, and acted on a
device that was not there — killing the boot partway through the floppy load.

A machine with no hard disk **fails** the call. Then DOS simply skips the drive.

The same principle explains [`com1_stub`](modules/com1_stub.md) and
[`cga_status`](modules/cga_status.md): a byte that is never `0xFF` is how software
distinguishes a real device from an empty socket. Answer consistently, or not at all.

---

## Contracts that only look satisfied

`INT 13h AH=03` is expected to have **committed** when it returns. A write-back cache
that defers across calls is invisible to DOS — right up until the power goes. FDISK
wrote a partition table, never issued `AH=00`, and the still-dirty block was lost at
reboot: **the partition vanished**.

Worse, the existing tests passed anyway, because they forced an eviction themselves. The
test that catches it asserts the contract directly: after `AH=03` returns, the dirty flag
must already be clear.

**Test the contract, not just the mechanism.**

---

## Timing races in I/O sequences

The [`flash`](modules/flash.md) SPI engine latches its transmit on the **falling edge**
of the write strobe, and `BUSY` only rises after that. Code doing

```asm
out 0x98, al
in  al, 0x99        ; may sample BEFORE BUSY rises
```

sees `BUSY = 0` and returns the **previous** byte, shifting an entire transfer by one.
The BIOS's loop works only because two incidental instructions (`push cx` / `mov cx,...`)
sit between them. Copying the *logic* without that accidental delay produced a corrupted
64 KB read.

**Make required delays explicit, never incidental.**

---

## Unbounded polls, and bounded ones that nest

A BIOS or bootloader that spins forever on a peripheral turns any wiring fault into a
dead machine with no clue where. Every poll here is counted.

But bounds **multiply**: a `wait_wip` bounded at 0x3000 iterations, each calling a `xfer`
bounded at 1000, can take *minutes* when the inner loop always runs to its limit —
indistinguishable from a hang. Bounding each loop individually did not bound the total.

**Bound the whole operation, not just each loop, and size the bound against the real
worst case** (a 4 KB flash erase can take 300 ms).

---

## Constraints and initialisation that silently do nothing

**SDC filters that match nothing.** `gertieboard.sdc` referenced port names from an older
revision (`CPU_READY`, `HS`, `VS`, `RGB`, `DEBUG`). Quartus dropped those filters with a
warning nobody read — one entire `set_false_path` was constraining **nothing**. Renaming
top-level instances does the same to the PLL clock definitions, leaving timing
"passing" but under-constrained.

```bash
quartus_sta gertieboard 2>&1 | grep "could not be matched"     # must be empty
```

**ROMs that are never initialised.** `bootrom.vhd` used `ram_init_file` with a `.mif`.
Quartus reported **0 memory bits**, never listed the MIF as a used source, and warned
that `rom` "was never assigned a value". For a boot ROM that is silent and fatal. It is
now a VHDL `CONSTANT` array, which always synthesises with its values.

---

## READY backstops are not timing parameters

`busdecode`'s `T >= 64` clause exists to recover from a wedged memory controller. It was
originally `T >= 10`, which aborted every PSRAM cache-line fill and released the CPU
before the data bus was driven — silent corruption on every miss. It also made slower
`SCK_DIV` settings look like signal-integrity problems when they were nothing of the
kind.

**A backstop must always be longer than the slowest legitimate operation.**

---

## Misreading a datasheet field

`altpll`'s `inclk0_input_frequency` is a **period in picoseconds**. `20000` means 20 ns,
i.e. 50 MHz — not 20 kHz. Misreading it produced a confident, entirely wrong conclusion
that the 8253 was running at 476 kHz, and a plan to "fix" a timer that was already
correct.

**Sanity-check a derived number against something independent.** `c1` landing on exactly
25 MHz — the standard VGA pixel clock — would have settled it immediately.

---

## Software is not always the suspect

Two "hardware" bugs were not hardware at all:

- **Digger's blank screen** was Digger *Remastered*, a multi-adapter port that
  auto-selected a non-CGA driver and drew to `0xA0000` — while its main loop ran happily.
  The fix was a command-line switch. The BIOS instrumentation that distinguished "hung"
  from "alive but drawing nowhere" is what found it.
- **The keyboard dying after one key** in games was authentic PC behaviour: a game
  installing its own `INT 09h` never pulses the XT's PB7 acknowledge. See
  [`ps2_kbd_ppi`](modules/ps2_kbd_ppi.md).

**Establish whether the machine is hung or merely doing the wrong thing before assuming
the hardware is broken.**

---

## Currently open

**The SPI-flash BIOS fallback.** With the host loader disabled, the boot ROM reaches POST
`B` (64 KB read from flash) and loads an image that renders as corrupted, flashing text
and then stalls — even though `BIOSFLSH` verifies the flash contents byte-for-byte
against the running BIOS. The serial path is unaffected. Suspicion remains on the boot
ROM's SPI read timing; the explicit settle gap did not resolve it.

The next thing to try is having the bootloader checksum what it read and display it,
then compare against `BIOSFLSH`'s verify — that would say definitively whether the read
or the write side is at fault.

## Related

- [Building](building.md) — the scripts and guards these lessons produced
- [Tools](tools.md) — the diagnostics
- [Architecture](architecture.md)
