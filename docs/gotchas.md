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

becomes `0F 84 rel16` — `JZ rel16`, a 386 instruction. Nothing of that era decodes it as
a jump:

| CPU | What `0F` actually is |
|---|---|
| Intel 8088 | **`POP CS`** — pops garbage into the code segment; execution vanishes |
| NEC V20 (the CPU on this board) | the **prefix for NEC's extended instructions**, and `0F 84` is not one of them |

Either way it is **not a branch**, so it "fires" *unconditionally*, regardless of flags,
and the `rel16` displacement that follows is decoded as whatever it happens to look like.

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

### Related: instructions the V20 has but an 8088 does not

```asm
shr al, 4            ; 80186+ !  encodes as C0 E8 04
push strict word 5   ; 80186+ !  no PUSH imm16 on an 8086
```

The V20 **does** implement the 80186 additions, so both run correctly on this hardware —
but neither is 8088 code, and both fail the moment the socket holds a real Intel part.

Pinning the architecture across every assembly file in `tools/` turned up **six**
instances that had been sitting there unnoticed: `shr` by an immediate in the glyph
renderer and in five diagnostics, and a `push imm16` in the three `IRQTEST` variants'
stray-vector stubs.

Fixes, both 8086-clean:

```asm
shr al, 1            ; x4 -- and no register needed, unlike mov cl,4 / shr al,cl
                     ; which matters when CL already holds something

push ax              ; the stray-vector stub saves AX itself and passes
mov  al, v           ; the vector in AL, still exactly 6 bytes per stub
jmp near stray_common
```

That last one is worth the detail: the stubs are indexed by `add bx, 6`, so the
replacement had to keep the **same stride** as `push imm16`. `50 / B0 xx / E9 xx xx` is
6 bytes exactly.

`.arch i8086` is therefore stricter than this board strictly needs. That is deliberate:
it keeps the sources honest to the machine they claim to be, and it is the same setting
that catches the trap above — which is *not* survivable on either CPU.

### Checking a built image

```bash
python3 -c "
d=open('xtbios_claude.bin','rb').read()
print([hex(i) for i in range(len(d)-1) if d[i]==0x0F and 0x80<=d[i+1]<=0x8F])"
```

Beware false positives — `0F` is also a common `jnz` displacement. Confirm with
`ndisasm` before believing it.

---

## A bus strobe is a level, not a pulse

`busdecode` hands peripherals the CPU's strobes combinationally:

```vhdl
IO_WR <= NOT(NOT WR AND IOM);
```

So `WR` stays low for the **whole** I/O write cycle -- several `CLK` edges at 5 MHz. Any
register that acts on the *level* therefore fires several times per write.

For an idempotent register that is harmless, which is why it went unnoticed for years:
writing the same value to `sevenseg` or `ctrl_reg` twice changes nothing. It is fatal for
anything with a side effect:

| Register | What repeated firing did |
|---|---|
| auto-incrementing data port | stored each byte into several slots, pointer ran away |
| a GO bit implemented as a toggle | even number of edges = transaction never starts |
| auto-incrementing read port | skipped bytes |

The USB host's 8-byte SETUP packet went out as duplicated garbage, and the device
answered **STALL** -- which is the correct response to a malformed request. The hardware
was behaving better than we were.

**`flash.vhd` had it right from the first version:**

```vhdl
IF (wr_prev = '1' AND WR = '0') THEN   -- falling edge: fires exactly once
  ...
END IF;
wr_prev <= WR;
```

Use the falling edge for writes, and the **rising** edge for a read auto-increment --
advancing on the falling edge changes the data underneath the cycle still reading it.

**The lesson that stings:** the correct pattern was already in the repository, in a
working peripheral, and the general principle was already written on this page under
"Timing races in I/O sequences". Having the answer written down is not the same as
applying it.

---

## Off-by-one-bit at the END of a serial packet

The USB transmitter computes each bit's line level at a phase-counter wrap, and that
level then sits on the wire through the *following* bit slot. Correct everywhere except
the last bit of a packet, where jumping straight to EOP gave it **one clock instead of
four**.

Losing a single bit means the receiver never assembles the final byte. The visible
result, per packet type:

| Packet | What arrived |
|---|---|
| token | address/endpoint but no CRC5 byte |
| data | payload but only half the CRC16 |
| ACK | *nothing at all* -- the whole PID |

A `T_TAIL` state that holds the final level for its own full bit time fixes all three.

**Any bit-serial transmitter with this structure has the same trap at the tail.** The
cheap check is to decode your own output and count the bytes.

---

## Polarity of a "previous state" register

The NRZI receiver keeps `rx_prev`, the previous value of the sampled line. The sampled
line here is `k := dm` -- **D minus**. Idle J has D− **low**, so `rx_prev` seeds to `'0'`.

Seeding it to `'1'` -- thinking of it as "we came from the J state" -- made the very
first SYNC bit decode as 1. Since SYNC ends at the first decoded 1, SYNC "completed"
immediately and the entire packet shifted seven bits. The payload still arrived; it was
just misaligned, so the PID looked like a valid-but-wrong value.

**Naming a register after the abstraction (J/K) while storing the representation (a
single line level) is how this happens.** One bit of initialisation, an entire packet
wrong, and nothing in the source looks incorrect.

It was found by modelling the state machine in Python and printing the decoded bit
stream -- 40 lines of script against a rebuild-and-reflash cycle. See below.

---

## Simulate the state machine, not just the arithmetic

Every USB bug above was found in Python before it was found on hardware, and the ones
that were *not* modelled were the ones that reached the board:

- CRC5 and CRC16 were checked against reference implementations first. Both were right
  on the first hardware run, and the check caught a real bit-order error before the build.
- The receiver and transmitter were then modelled cycle-accurately and fed generated
  waveforms. That found the polarity bug and the missing tail bit.
- The first transmitter model used a *simplified* byte stream instead of the VHDL's
  actual literal-then-buffer sequencing -- so it missed the tail bug entirely on the
  first pass. Modelling the wrong thing gives false confidence.

**Model what the RTL actually does, then decode its output with an independently written
decoder.** A loopback of two functions that share a misconception proves nothing.

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
a rebuild is ignored until it is restarted.
[GertieBoardLoader](https://github.com/mathijsvandenberg/gertieboardloader) watches the
file and reloads automatically.

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

## A long SPI read does not come back intact

The boot ROM fetched the 64 KB BIOS image from flash in **one `READ` command**, holding
`/CS` low throughout. The part allows that, the datasheet allows that, and it appeared
to work: the image loaded, the reset vector was intact, POST ran.

About **a sixth of the bytes were wrong.** So the machine failed in ways that looked
like anything except a bad read — a register that would not match its expected value, a
drive that printed its label and no status, a screen of debris. A long stretch of
suspicion fell on the *writer*, which had been correct the whole time.

`tools/spidump.com` settled it by performing the identical read both ways from DOS —
same port, same command, same byte-exchange routine, same comparison — with only the
burst length changed:

| Read style | Mismatches out of 65536 |
|---|---|
| One continuous burst, `/CS` low throughout | **11256** |
| A fresh command every 512 bytes | **0** |

**Never issue an SPI read longer than 512 bytes on this board.** Both long readers are
chunked now: `flash_load` in the boot ROM, and `hd_load_block` in the BIOS, which was
reading a whole 4 KB block in one command — eight times the length now known to be safe,
never verified, and worse than a bad boot because it feeds read-modify-write and would
have written the corruption back into the filesystem.

### How the alternatives were ruled out first

This is why the answer was trustworthy when it arrived. `spidump` counts mismatches at
three alignments and offers several timing variants, so each theory died on its own
evidence rather than on argument:

- **A byte-shift race** — the status read overtaking the write, so the engine returns the
  previous byte — would put one of the three alignment counts near zero. All three were
  ~11200.
- **Timing** — two filler instructions after the write versus eight gave *byte-identical*
  counts. Not a settle-time problem.
- **An erased or zeroed region** predicts a computable number of mismatches: 16265 if
  `0xFF`, 9665 if `0x00`. Observed 11256, so the bytes were real data, just not ours.

### The lesson that generalises

Two readers disagreed about the same address. The instinct was to audit the writer —
geometry, drive letter, address arithmetic, the flush, the block cache, whether PSRAM had
been scribbled on. All of it was fine, and two independent checks had already said so:
the read-back verified byte-for-byte, and a checksum proved the image in RAM was
unchanged since POST.

**When two readers disagree about the same address, enumerate how the _readers_ differ.**
The one property that separated them — burst length — was in plain sight throughout.

## Two writes to one array signal in a single clock

Legal VHDL. Simulates correctly. Does not synthesise.

The keyboard FIFO enqueued an extended key's `E0` prefix and its scancode in the same
clock using a variable write pointer, and said so in a comment as though it were a
clever economy:

```vhdl
-- Uses a variable write pointer so an E0 prefix + code (two bytes) can be
-- enqueued in the same clock.
fifo(to_integer(wrp_v(FW-1 downto 0))) <= b;   -- called twice, two indices
```

Quartus collapsed the two element writes into **a single write using the last index**.
Only the code byte landed; the prefix slot kept whatever stale scancode had been written
there on a previous trip around the ring.

The symptom was arrow keys emitting a random old key followed by the numeric-keypad code
they share. `tools/kbscan.com`, which prints raw bytes from port `0x60` with no
translation, made it unarguable — three presses of the right arrow:

```
1f 4d   2e cd
ae 4d   31 cd
1c 4d   b8 cd
```

Second byte always correct, first byte a different leftover every time. Keypad Enter read
`1c 1c 1c 9c`, where the leftover happened to be `1C` itself.

The fix is one byte per clock: the prefix now, the code from a pending register on the
next clock. PS/2 bytes are about a millisecond apart against a 50 MHz clock, so nothing
can overtake it.

**Write one element of an array signal per clock.** This is a synthesis hazard, not a
language error, so nothing warns you — and it belongs in the same family as the
[8088 opcode trap](#the-8088-opcode-trap): the source reads correctly and the machine
disagrees.

## Bit stuffing has to survive the end of the packet

USB inserts a `0` after six consecutive `1` bits. That run can end **on the packet's very
last CRC bit**, and the stuffed bit still has to go out before EOP.

The transmitter dropped it. The receiver then saw six ones against EOP — a bit-stuff
violation — and discarded the packet in silence: no ACK, no NAK, nothing to count.

Whether a packet hits this depends **only on its bytes**, so the failure is perfectly
deterministic per content and looks like anything but a wire problem. A write soak failed
at the same three sectors on every run, with `tmo` incrementing while `nak` and `crc`
stayed at zero. Roughly **one packet in 64** of random content is affected: frequent
enough to destroy a filesystem, rare enough to pass every short test.

It was found by modelling the coded transmit logic in Python and decoding it with an
independently written, by-the-spec receiver. The model named exactly those three sectors
from the pattern generator alone, before any hardware change.

Retrospectively it explains a long tail of ghost stories: any host-transmitted packet
whose CRC happened to end in six ones was undeliverable *forever*, so a `WRITE` losing
its last data packet became silent FAT corruption, and a `READ` whose CBW hit it became
"sector not found" at one specific sector for all time.

## Scratch space in the BIOS data area is not free

The floppy handler kept its parameters at BDA `40:90`–`40:99`, which looks like unclaimed
space. `40:96` and `40:97` are the **keyboard status flags 3 and 4** — the `E0`/`E1`-seen
bits, right-Ctrl, right-Alt, and the lock LED state.

So every floppy read and write wrote a buffer offset straight through them, and the
keyboard grew phantom modifier keys **after disk activity**. DOS 3.3 never reads those
bytes; DOS 4 and later, `KEYB.COM` and anything enhanced-keyboard-aware do. A bug that
appears only on some DOS versions, and only partway through a session, is very hard to
attribute to the floppy driver.

A near-repeat of the same mistake while fixing it: the first relocation aimed at `40:B0`,
which holds the floppy geometry captured from the BPB at boot — and the read path *uses*
it. That would have broken booting outright.

**This BIOS's allocations**, so the next one does not collide:

| Range | Owner |
|---|---|
| `40:A8`–`40:AF`, `40:B4`–`40:B5` | Floppy handler scratch |
| `40:B0`–`40:B2` | Floppy geometry from the BPB — the read path reads this |
| `40:B6` | FDC timeout flag |
| `40:B7` | "Drive A: answered at POST" — read by `INT 19h` only |
| `40:B8`–`40:BA` | POST code checksum and its length |
| `40:C0`–`40:DF` | USB mass storage |
| `40:E0`–`40:F5` | SPI flash disk |

## A working machine that cannot be identified

Prince of Persia refused to start with "no graphics card", on a machine that was
rendering that refusal perfectly. Commander Keen 4 hung on its startup panel.

Nothing detects a graphics card by looking at the screen. It writes a CRTC register and
reads it back. [`vga`](modules/vga.md) generates fixed timing and ignored `0x3D4`/`0x3D5`
entirely, so the read floated to open-bus `0xFF`, the test pattern never came back, and
every program that probed concluded there was no card.

**The video path was never at fault.** It had been verified on hardware by five separate
tools. What was missing was not a capability but an *answer*.

That is the general shape, and it is worth recognising because it defeats an entire
class of instrumentation. Six theories were falsified by measurement first —
[`INTSPY`](tools.md#intspy--unimplemented-interrupts) proved no unimplemented interrupt
was called, [`VIDSPY`](tools.md#vidspy--did-the-video-call-return) proved every BIOS
video call returned, [`PITTEST`](tools.md#pittest--does-irq0-survive-being-reprogrammed)
proved the timer survives reprogramming,
[`MEMTOP`](tools.md#memtop--the-memory-a-large-program-actually-gets) proved memory holds
what is written to it, and the disk was eliminated by running the same program from three
drives. Every one of those results was **true**, and none of them could see the fault,
because a machine failing to be *recognised* leaves no trace in any interrupt, any timer
or any byte of RAM.

The instrument that found it was a program complaining in plain English, and the tool
that confirmed it — [`CRTCTEST`](tools.md#crtctest--can-this-card-be-detected) — was
written afterwards.

**Lesson:** when a program refuses to run rather than running wrongly, ask what it asked
the machine about itself before asking what it tried to do. Identity is probed before
capability is used, and an unanswered probe reads as absence.

Related: [answering a probe half-truthfully](#answering-a-probe-half-truthfully), which
is the same failure with the answer present but wrong.

## Currently open

Nothing broken. The last entry — the BIOS not booting from SPI flash — closed when the
boot ROM stopped reading the image as
[one 64 KB burst](#a-long-spi-read-does-not-come-back-intact).

Two things are *unfinished* rather than wrong, and are recorded here so they are not
rediscovered as bugs:

- **CRTC `START` (R12/R13) is latched but unused.** Anything that scrolls by moving the
  display start address will not scroll. Software that redraws is unaffected.
- **Divisor `0x8000` on PIT counter 0 runs at half rate.** Found by
  [`PITTEST`](tools.md#pittest--does-irq0-survive-being-reprogrammed) and genuinely
  anomalous — neighbouring divisors are correct and the arithmetic in
  [`timer8253`](modules/timer8253.md) reads as if it should be too. No game picks that
  value, so it has not been chased.

## Related

- [Building](building.md) — the scripts and guards these lessons produced
- [Tools](tools.md) — the diagnostics that found several of these
- [Storage](storage.md) — the three drives these lessons came out of
- [Architecture](architecture.md)
