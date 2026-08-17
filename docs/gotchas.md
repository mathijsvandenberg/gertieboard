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

## A constant that is really a property of the device

A USB control data stage ends when a packet arrives that is **shorter than the
endpoint's max packet size**. The BIOS's `u_ctl` wrote that test as `cmp cx, 64`.

That is right for every device this board has ever talked to, because mass-storage
sticks use a 64-byte control endpoint — and wrong for anything with a smaller one. A
Logitech Unifying receiver reports `bMaxPacketSize0 = 8`, so on that device the **first
full packet already looks short**: the data stage ends after 8 bytes and returns success.
An 18-byte device descriptor comes back as 8 valid bytes followed by 10 bytes of
whatever was in the buffer, with `CF` clear.

Nothing about that failure points at the short-packet test. The transfer succeeded, the
first eight bytes are correct, and `bLength` in byte 0 is right — so the *header* of
every descriptor reads fine and only the tail is garbage.

The number 64 was never a constant of the protocol. It was a property of the one device
in front of us, promoted to a constant because it never varied. Modelling the two rules
against a reconstructed `046D:C52B` descriptor set:

| short-packet test | device descriptor | configuration descriptor |
|---|---|---|
| `64` | 8 of 18 bytes | 8 of 84 bytes |
| `bMaxPacketSize0` | 18 of 18 | 84 of 84 |

**When a value is read from the device during enumeration, using it is not optional —
and a literal that happens to match every device you own is a constant waiting to
expire.**

The sharpest detail: `bMaxPacketSize0` was *already being stored* in BDA `0xC7` at
enumeration stage 3, and nothing ever read it. The right value was present the whole
time and the constant was used anyway. `u_ctl` now copies `0xC7` per call and tests
against that, and `u_enum` resets `0xC7` to 8 before stage 3 — that byte is RAM, so a
warm boot would otherwise inherit the *previous* device's size.

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

## "Ready" meant the init finished, not that the next access would work

The CPU is held in reset until main memory reports `MEM_READY`. That signal says
*the initialisation sequence has completed*. `clkgen` treated it as *the next
access will succeed*, and dropped `RST_OUT` on the very next clock — so the
CPU's first fetch raced the first cycle the memory controller had ever run for
real.

It failed about **one cold boot in seven**, and only from flash, never from a
JTAG load. That combination is what made it so hard: a JTAG reload leaves the
memory already initialised by the previous bitstream, so the race does not
exist there.

### The three numbers that solved it

The boot loader's memory probe reports a code, a count, a value, **and the OR of
every differing bit**. That last number is the one that mattered:

```
E3  1C  00  7F
```

The probe writes `offset XOR 0x5A`, so the expected value's bit 7 equals the
offset's bit 7. `7F` means bit 7 *never* differed — so every one of the 28
failures lay in the **first 128 bytes** of the block, and they read back `00`.

**Early writes lost, later writes fine.** That is the shape of memory that is not
quite awake. It is not the shape of broken memory, a wrong address decode, or a
marginal data path — all of which scatter their errors across the block.

Without that bit-mask the evidence pointed nowhere: the count and the value
alone are consistent with half a dozen causes, and roughly that many were
proposed and disproved before the mask was read properly.

### What did not work, and why it is instructive

`clkgen` already had a ten-clock reset stretch, and lengthening it changes
nothing — `MEM_READY` dominates it by two orders of magnitude, so the stretch
expires long before memory is up. **The gap was specifically *after* ready.**
"Make the reset longer" is only useful once you know which part of it is short.

The fix is 8192 bus clocks — about 1 ms, invisible against the second the FPGA
already spends configuring from EPCS.

### The general shape

**A ready signal is a claim about the past, not a promise about the next
cycle.** Anything that reports "initialised" deserves the question: does it mean
the sequence finished, or that the device will answer correctly right now? On
this board the two differ by about a millisecond, and one boot in seven found it.

---

## A constraint that is met, against a premise that is wrong

Adding a second USB engine stopped the machine booting. It was not the engine. Every
report was clean — 0 errors, positive slack at every corner, no unmatched constraint —
and the board would not fetch its BIOS over serial. **Putting a finger on `CPU_CLK` made
it work.**

A fingertip is tens of picofarads: a few hundred picoseconds of extra delay on the
clock. Delaying the CPU's clock hands that time straight to READY, which is the lever
the SDC already pulls deliberately with its pad minimum. So the hardware was saying the
READY aperture was too narrow — while the analyser insisted the constraint was met.

Both were right. The constraint *was* met. It was derived from `tSRYLK = 8 ns`, and that
figure is the µPD70108 datasheet's **at 4.5–5.5 V**. [This part runs at
3.33 V](hardware.md). Undervolted CMOS is slower by an amount no datasheet for this
operating point states, so the real allowance is smaller than 8 ns and the budget built
on it was too generous.

**This fails differently from a violated path, and that is the whole lesson.** A
violation is red in a report and someone eventually looks at it. A constraint met
against a wrong premise is green forever. It presents as:

- every timing report clean, across every corner
- the machine dead, or intermittently dead
- unrelated edits deciding whether it boots, because they shift placement inside a
  margin that was never really there
- **a finger fixing it**

If touching a pin changes behaviour, stop reasoning about logic. That is an analogue
measurement, and it outranks the reports — the reports are only as good as the numbers
they were derived from, and a datasheet figure quoted outside its supply range is not a
number, it is an assumption.

The repair was to stop asking a pad to supply the skew. `cpuclk` re-registers the bus
clock on the falling edge of the 100 MHz master, so `CPU_CLK` runs exactly 5 ns behind —
a clock edge, identical at every step, corner and build, where the pad minimum was
2.5 ns that the fitter would only ever promise 2.722 of. The internal bus clock is
untouched, so peripheral edges stay on `c3`'s 20 ns grid.

Three sub-traps came with it, each of which failed the build on its own:

- **Slowing the pad is the wrong lever, twice over.** 4 mA bought 0.225 ns and pushed
  the pad to 6.037 ns against a 6.000 ceiling — and the V20 measures its clock high time
  at 3.0 V, so time spent in transition comes straight out of `tKKH`.
- **A new register lands where the fitter likes.** The delayed flop cost 1.6 ns of
  routing to the pin until `FAST_OUTPUT_REGISTER` put it in the I/O cell.
- **The old bound was load-bearing only while it was the only one.** Leaving the pad
  minimum at 2.500 failed hold by 0.676 ns once the register moved into the IOE.

And the margin that was won was **not** banked: `CPU_RDY` stays constrained at 10.35 ns
against a budget that is now 14.35, because the 4 ns is being held against `tSRYLK`
being wrong at 3.33 V. Relaxing a constraint to whatever the new number allows rebuilds
the same lottery one level up.

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

## One fact, written twice

Two of the hardest faults on this machine were the same mistake in different clothes: a
single piece of information kept in two places, where nothing forces the copies to agree.

**The memory map.** `mem_hybrid`, `psram_ctrl`, `m9k_mem` and `busdecode` each decided
independently which addresses belonged to whom, in four hand-written expressions.
Teaching one of them that low memory was PSRAM and not the others made the first stack
push route to a controller that did not claim the address. Nothing drove `READY`, and the
CPU stopped on `0x7C00` — an address that looks entirely ordinary. There was no error and
there could not be one. The fix was [`memmap.vhd`](../memmap.vhd): the boundaries live in
one package and the modules ask rather than restate.

**The scan counters.** [`cga_status`](modules/cga_status.md) kept its own 800 × 525
counters on `c3` while [`vga`](modules/vga.md) counted the same geometry on `c1`. Same
period, second copy — and they never agreed. `vga` draws the picture on lines 35–434;
`cga_status` announced vertical retrace from line 400, so every program that waits for
blanking before rewriting the screen was handed **1.1 ms of active display** as if it
were safe. The fix was to delete the counters and take both bits from the ones that
actually address the video memory.

What makes this class expensive is that the duplicate is usually *correct when written*.
It becomes wrong later, silently, when one copy is edited — and the symptom appears
nowhere near the edit.

> The `cga_status` header had already recorded the risk: *"the PHASE is arbitrary … wire
> `vga`'s `VS` in here instead if that ever matters."* It sat there for months. **A known
> limitation that stays written down is a bug with a disclaimer on it** — and the
> disclaimer underestimated it, because it framed the cost as tearing when the real cost
> was software being told the wrong thing about when it could draw.

**The speed ceiling.** `MAX_IDX` in `gertieboard.vhdl` sets the fastest step
[`cpuclk`](modules/clkgen-pll.md#cpuclk--the-programmable-bus-clock) will accept;
`-divide_by` on `CPU_CLK_INT` in `gertieboard.sdc` sets the step the timing report
analyses. They are one setting written in two places and **nothing checks that they
agree**. Raise the generic alone and the machine can be commanded into a step no one
ever timed; raise the SDC alone and the report describes a step the hardware refuses.
This one is at least loud in the right direction — `tools/mkfpga.sh` fails the build on
negative slack — but only for the half that the SDC covers.

**Lesson:** when two modules must agree about a fact, make one of them the source and
have the other ask. If that is genuinely impractical, the second-best is a single
assertion that fails loudly when they diverge — not a comment saying they might.

## A peripheral's registers do not have to run at the peripheral's rate

[`timer8253`](modules/timer8253.md) was clocked entirely from `c2`, its 1.19 MHz counting
rate, which is the obvious reading of "the PIT runs at 1.193 MHz". It is also the reason
the machine could not go faster than 5 MHz.

A register interface on a 1.19 MHz clock has ~840 ns between edges. At 5 MHz the CPU's
I/O write strobe was wide enough to be caught anyway. Every attempt to raise the bus
clock narrowed the strobe relative to that window, until writes to the PIT started being
missed — a game reprogramming counter 0 would have some of its bytes accepted and some
dropped.

**The symptom was games crashing during play at 6.25 MHz and above**, which reads as a
CPU speed limit or a memory timing problem, and was chased as both for a long time. The
CPU and the memory were fine.

The separation is the fix: the register interface runs on the bus clock so it can see an
I/O cycle, and the counting rate comes in as *data*, sampled through a synchroniser and
used as a count enable. The rate stays exact; only the phase of each tick moves, which no
8253 user can observe.

**Lesson:** a peripheral has two clocks in it — the rate it *models* and the rate it must
*be talked to at*. Wiring both to the slow one works until the bus gets faster than the
model, and then it fails as a bus problem.

## A check that reads through its own shadow

The loader's flash path tested whether the flash held a BIOS at all:

```asm
cmp byte [es:0xFFF0], 0xEA      ; reset vector must be a far jump
jne .nobios
```

`0xFFFF0` is **inside the boot ROM overlay window**, and the overlay was still enabled at
that point — so the read returned the boot ROM's own reset vector, which is
`EA 00 FC 00 F0`. It saw `0xEA` every time. The check passed unconditionally, the
`.nobios` path and its `EF` marker were unreachable, and a blank flash would have booted
into nothing with no indication.

The overlay is a *read* shadow: writes pass through to PSRAM. So the loader could write
the image into that window and never read back what it had written — it would always see
itself. The blank test now works off the checksum of `0xC000`–`0xEFFF`, a range the
overlay does not cover.

**Lesson:** when a device shadows part of an address space, every read in that range is
answering a different question than it looks like. Verifying what you just wrote requires
reading somewhere the shadow does not reach — or turning the shadow off first.

## A measurement nobody can read is not a measurement

The boot loader has always checksummed the BIOS image **in PSRAM, immediately before
jumping to it** — the exact bytes about to run — and shown it on the 7-segment display,
high byte then low byte, before marker 7. It is the ideal instrument: it distinguishes
"the transfer corrupted" from "the image is fine and the fault is elsewhere", with no
BIOS involved at all.

It has never been legible. `show_byte` held each value for **0.27 s** at the 8.333 MHz
the loader actually runs at, while [`sevenseg`](modules/sevenseg.md) needs **2.0 s** to
walk both nibbles of a byte — and a new write restarts that cycle from the high nibble.
So every boot displayed a flicker of two high nibbles and then marker 7 wrote over them.

The delay constant was sized as "~0.45 s at 5 MHz", which is a real calculation about a
loop and says nothing about the display it was feeding. Two full debugging rounds were
spent on a stalling boot with the answer being computed, correctly, on every attempt.

**Lesson:** when instrumentation feeds a display, the display's own timing is part of the
instrument. A number that is right and invisible is worth exactly as much as one that is
wrong — and it is more expensive, because it looks like the check is being done.

## An exception that outlived the reason for it

`gertieboard.sdc` put the pixel clock `c1` in its own asynchronous clock group, and said
why:

> The VGA pixel clock is the one exception: it meets the system clock only inside the
> dual-port framebuffer BRAM, so it is its own async group.

That was true when it was written. It stopped being true the day the EGA planes moved to
SDRAM, because [`ega_mem`](../ega_mem.vhd) carries `row_addr` — a **sixteen-bit bus** —
from `c1` to `c3`, with `fill_tgt` beside it, and none of that is inside a BRAM. The
comment stayed correct-looking and the constraint stayed in force.

Declaring clocks asynchronous does not relax those paths. It **deletes** them from the
analysis. Seventeen wires were placed by luck, and nothing anywhere would say so:

```
PAIR clk[1] -> clk[3] : 0        PAIR clk[3] -> clk[1] : 0
PAIR clk[1] -> clk[0] : 0        PAIR clk[0] -> clk[1] : 0
```

The symptom was that **the build became a lottery**. Identical logic closed at `-0.040`,
`+0.056`, `+0.200` or `+0.327` ns depending only on the fitter seed, and whether the
machine booted tracked that number and not the source. An edit confined to the EGA
prefetch could stop DOS finding `COMMAND.COM`, a bitstream could boot on the third
attempt having failed twice, and every one of those builds passed timing. Hours went into
theories — the seed, an arithmetic rewrite, the PSRAM capture window — each of which fit
the evidence and each of which was wrong, because the evidence was a proxy for placement
quality rather than a cause.

`c1` is 25 MHz from the same PLL as `c3`'s 50 MHz: integer-related and phase-aligned, like
every other output here. The header of that file already says the others are timed
together *for exactly this reason*, and calls the previous version of the same mistake
"the original bug that left the `busdecode`↔PSRAM paths unanalyzed". So the exception was
removed and `c1` timed with the rest. The newly visible paths pass with 16–18 ns to spare
— they were never tight, they were merely **unexamined**.

Two things fell out of that which are worth noting separately:

- The `EGA_START` bus (CRTC `R12`/`R13` → the pixel clock) is crossed by two flops *per
  bit*. That resolves metastability per bit but does **not** make a bus coherent: bits can
  resolve on different clocks and yield a value that was never written. A handshake was
  about to be written for it. None was needed — once the clocks are timed together the
  transfer meets setup and all sixteen bits land on one edge by construction. **The
  synchronisers were compensating for a constraint, not for the hardware.**
- With analysis finally covering the design, the real critical path could be found and
  paid for: the PSRAM cache tag compare. Halving `NLINES` from 8 to 4 took setup at
  slow/85 °C from `+0.150` to `+0.487` ns and cost **nothing measurable** — `RAMSPEED`
  reads 18 ticks either way. The margin had been spent on cache lines the workload never
  used.

**Lesson:** a timing exception is a claim about the design, and claims rot. `set_false_path`
and `set_clock_groups -asynchronous` are the only constructs here that can make a build
pass by *not looking*, so each one needs a reason recorded next to it — and the reason
needs re-reading whenever the thing it describes is touched. When a design starts
behaving differently per fitter seed, suspect the constraints before the logic: **"it
closes timing" means nothing until you know what is being timed.**

### And the same was true of every pin off the chip

The clock groups were only half of it. `RAM_*`, `DRAM_*` and `FL_*` had **no
`set_input_delay` or `set_output_delay` at all** — the SDRAM holding the EGA planes, the
PSRAM every instruction is fetched from, and the flash the BIOS boots out of, none of them
examined. 29 constraint lines for the whole design.

Constraining them turned up the thing worth knowing: **the SDRAM read capture was the
tightest path on the board, at +0.26 ns**, and nothing had ever looked at it. Its 10 ns
half-cycle goes 2.45 ns on `DRAM_CLK` reaching the pin, 6.2 ns on the part's own access
time, 0.73 ns in the input buffer — and only 0.94 ns on routing.

That last figure is the point. Because the worst path is now made almost entirely of
silicon and datasheet, **it stopped moving**: the same netlist closes at +0.260, +0.260,
+0.260 and +0.258 across four fitter seeds, where before the interfaces were constrained
the same four seeds gave −0.040 … +0.327. A critical path built from physics behaves the
same on every build; one built from routing is a coin toss dressed up as a number.

Note also what happened to the *headline* figure: setup at slow/85 °C read +0.487 ns before
this and +0.260 after. The design did not get worse. The earlier number was an incomplete
measurement that had never included the interface, and **a margin you have not measured is
not margin you have.**

**Lesson:** an unconstrained pin is not a relaxed one, it is an unexamined one, and the
tightest path in a design is exactly where nobody is looking. Constrain every external
interface even when it demonstrably works — the value is not that the fitter tries harder,
it is that the number becomes *repeatable*.

## A test that certified the memory that used to exist

[`EGAVFY`](tools.md) writes a pattern through the whole EGA write path and reads it back
through the SDRAM window at `0x300`, which is the only way to tell "the CPU wrote the
wrong thing" from "the display reads the wrong thing". It opened with:

```asm
NOFFS   equ 8000                ; one full 320x200 page, in pixel offsets
```

8000 bytes *was* the whole of a plane, back when a plane was 16 KB and the CPU window
folded four times into it. When the planes grew to 64 KB the constant stayed, so the tool
swept the first eighth of the memory and printed **CLEAN** — while the addresses Keen 4
actually uses for its second and third display pages, and for the off-screen latch area,
had never been read by anything.

The failure mode is the bad one: not a wrong answer, a *confident* one. A tool whose only
job is to say whether memory is sound will happily certify the memory it was told about
years ago.

**Lesson:** a test's coverage is a constant somewhere, and constants do not follow the
hardware. When a size changes, grep the *tools* for it too — and prefer a bound derived
from the thing under test over a number typed in once. Extended here to all 65536
offsets, plus a third pass that reads back **through the CPU**, since reading through the
diagnostic window deliberately bypasses the display path and therefore also bypasses the
CPU's own read path — the one every latch load in a blitter depends on.

## The handshake cannot govern the handshake

`gertieboard.sdc` false-pathed the whole off-chip V20 bus, both directions, and said why:

> Correctness is governed by the READY handshake and the long (>=200 ns) bus cycle, not by
> meeting setup on a single 20 ns system-clock edge.

That is right for address and command, and it is the same shape of mistake as
[the pixel clock's async group](#an-exception-that-outlived-the-reason-for-it): the
sentence is true, and it does not cover everything it was applied to. Two signals on that
bus are referenced to the CPU's **own clock edges**, with requirements nothing else can
satisfy on their behalf — and one of them is READY itself, which cannot be governed by the
handshake because it *is* the handshake:

| µPD70108 | | |
|---|---|---|
| `tSRYLK` | READY setup to CLK↓ | **−8 ns** — may arrive 8 ns *after* it |
| `tSRYHK` | READY setup to CLK↑ | `tKKL − 8` — the same instant |
| `tSDK` | read data setup to CLK↓ | 20 ns (−8 part) |

Measured on the fit that was current when this was found, launch edge to pin:

```
CPU_CLK    4.442 ns
CPU_RDY   18.441 ns     <- 14.0 ns behind the clock; the part allows 8
CPU_AD    22.891 ns
```

So READY had been arriving **inside the CPU's sampling aperture** rather than clear of it,
and which side of the aperture a given bitstream landed on was decided by placement.
That produces a very specific and very misleading symptom: builds that boot are *stable* —
they run games for hours — and builds that do not, never do, and the difference survives a
power cycle and does not correlate with anything in the source. It looks like a bad
soldering joint or a marginal supply, and it was neither.

It also masqueraded as a memory fault for a week. Conventional memory was moved off the
PSRAM entirely and onto SDRAM — a different chip, a different bus, a different controller
— and cold boot still failed four times in five, because the memory was never the thing
that was marginal.

The fix was three parts, and only the first is a constraint:

- **Bound the paths**, deriving the numbers from the datasheet rather than from what
  today's fit happens to achieve.
- **Take the address decode out of the READY path.** [`mem_hybrid`](../mem_hybrid.vhd)
  selected between its two sub-blocks by decoding the address; it does not need to, because
  each block already idles at `'1'` outside its own range, so `ready_ps AND ready_m9k` is
  the same answer for every address with no decode at all.
  [`busdecode`](../busdecode.vhd) now decodes `needs_ram_handshake` at the ALE edge from
  the address arriving on the pins, which costs nothing because that edge already latches
  the address.
- **Bound `CPU_CLK` at both ends**, so the time the clock spends reaching the CPU can be
  *claimed* as part of READY's budget instead of merely observed.

READY went from 18.441 ns to 10.346 ns, and cold boot went from one attempt in five to
five in five.

Two cautions for anyone editing this. The bound closes with **4 ps** of margin, so the
next change to that path will fail the build — that is the mechanism working, and the
answer is to shorten the path, not to raise the number. And if it ever needs real margin
rather than a hair's breadth, register `CPU_RDY` in the output pad: pin timing becomes
about 3 ns permanently, at the cost of one wait state per bus cycle — but the memory
clause must then be gated at `T >= 2`, because a naively registered READY lets the CPU's
end-of-T2 sample see a value computed before the strobe asserted, which is a false ready.

## Currently open

Nothing broken. The last entry — the BIOS not booting from SPI flash — closed when the
boot ROM stopped reading the image as
[one 64 KB burst](#a-long-spi-read-does-not-come-back-intact).

Two things are *unfinished* rather than wrong, and are recorded here so they are not
rediscovered as bugs:

- **CRTC `START` (R12/R13) is used by EGA and still ignored by CGA.** In mode 0Dh the
  start address is latched once a field into the prefetch base, so page flipping works and
  Keen 4 relies on it. The CGA path still ignores it, so anything that scrolls a *text* or
  mode 4/5/6 screen by moving the register will not scroll. That half was wired in once
  and reverted — it shifted Arkanoid's text screen, which rules out the word-versus-cell
  doubling that graphics mode makes the obvious suspect and leaves the hardcoded 80-byte
  row length as the likely candidate.
  [`SCROLLTST`](tools.md#scrolltst--does-the-display-start-address-land-where-it-should)
  exists to settle it; run that before wiring in the CGA half, rather than reading the
  screen.
- ~~**10 MHz does not boot.**~~ **RESOLVED.** It was READY after all, and the fix was to
  stop asking a pad to supply the skew: `cpuclk` now re-registers the bus clock on the
  falling edge of the 100 MHz master, so `CPU_CLK` runs exactly 5 ns behind the internal
  clock and that time goes straight to READY's aperture. The machine runs at **10 MHz**.
  The supply was never the cause here, though it remains out of spec and worth stating:
  pin 40 measures **3.33 V** on a part rated 4.5–5.5 V, with no droop during reset
  (scope-verified), and the part is a `-8` being run at 10. Note also that the clock input is the one pin with a raised threshold —
  `VKH` is 3.9 V at 5 V VDD, 78 % of the rail where ordinary `VIH` is 44 % — and `tKKH` is
  measured at an **absolute** 3.0 V, which a 3.3 V LVTTL swing clears by very little. A
  single buffer on the clock line powered from the CPU's own rail would settle that
  question far more cheaply than raising VDD, which would need series resistors on ~20
  CPU→FPGA lines because Cyclone IV E inputs are not 5 V tolerant.
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
