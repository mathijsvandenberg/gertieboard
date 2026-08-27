# The voice engine — hardware sample playback

Eight sample-playback voices in fabric, mixing without the CPU. This is the
Paula/Ultrasound idea rather than the Sound Blaster one: the CPU says *what to
play* and the hardware does the playing.

The Sound Blaster stays exactly as it is. It is what games talk to, it works,
and it is a different thing — a DAC with a DMA engine, doing no mixing at all.
That is precisely why software mixing costs what it does, and why this exists
alongside it rather than in place of it.

## Why this is worth building

MODPLAY measured 50–100% of the CPU mixing four channels at 11 kHz, saturating
on dense passages. The cost is not arithmetic — it is memory. Every output
sample needs a sample byte, a volume-table byte and an accumulator
read-modify-write, and on a V20's eight-bit bus each of those is several
cycles. Roughly 19 bus cycles per sample per channel, and no amount of
instruction-level cleverness changes that; the remaining tricks were measured at
single-digit percentages against a shortfall of fifty.

In fabric the same work is one memory read per voice per output sample, done in
parallel with everything else the machine is doing, at a rate the SDRAM does
not notice. The CPU's involvement drops to a few register writes per note.

## What it is not

Not a Gravis Ultrasound. The GF1's architecture is right and its *compatibility*
is a much larger project: an indirect register file, DRAM peek/poke because
samples live in card RAM, timers, its own interrupt scheme, and volume-ramp
hardware across 32 voices. Emulating an upload path for samples that are
already sitting in SDRAM would be work spent to arrive back where we started.

So: the shape of a voice engine, with a register set chosen to be easy to drive
from 8086 assembly, and no claim to be any real chip.

## Register map

**Base 0x300.** The IBM technical reference set 0x300-0x31F aside as the
prototype-card range -- the addresses reserved for hardware someone built
themselves -- which is exactly what this is. It also stays clear of everything
already decoded here (0x20, 0xA0, 0xA8, 0xE8, 0x220) and of the Sound Blaster
alternate bases at 0x230-0x280, so a game probing for a second card never finds
this one and mistakes it for one.

Sixteen ports on a 16-byte boundary, one voice visible at a time. A voice window
rather than 8×16 ports because I/O space is scarce and a tracker writes a whole
voice at once anyway — select once, write the fields, key on.

    0x300   VOICESEL  W   [2:0] which voice the window below refers to
            ID0       R   0x47 'G'
    0x301   ID1       R   0x56 'V'
    0x302   NVOICES   R   how many voices this build has
    0x301   CTL       W   [0] RUN    1 = playing, 0 = silent
                           [1] LOOP   1 = wrap to LOOP on reaching END
                           [2] KEYON  write 1 to restart from START
    0x302   VOL       W   [6:0] 0..64, linear
    0x303   START_L   W   sample start, physical byte address, bits 7:0
    0x304   START_M   W                                        bits 15:8
    0x305   START_H   W                                        bits 19:16
    0x306   END_L     W   one past the last byte
    0x307   END_M     W
    0x308   END_H     W
    0x309   LOOP_L    W   where a looping voice resumes
    0x30A   LOOP_M    W
    0x30B   LOOP_H    W
    0x30C   STEP_L    W   phase increment, 8.16 fixed point, fraction 7:0
    0x30D   STEP_M    W                                      fraction 15:8
    0x30E   STEP_H    W                                      integer 7:0
    0x30F   ACTIVE    R   bit per voice, 1 = still playing (GLOBAL, not per
                           voice: a tracker asks "which voices are free", and
                           having to select each one to ask is eight times the
                           I/O for the same answer)

### Detection

Reads and writes differ on the first three ports, which is ordinary for I/O and
buys a probe that cannot be fooled:

    0x300 -> 'G'    0x301 -> 'V'    0x302 -> voice count

A machine without this reads 0xFF from an open bus or 0x00 from a decoded-but-
empty one, and neither spells GV. Probing by "did something answer" is what the
BIOS flash tool nearly did with drive 2 -- the floppy path answers AH=08 for any
drive number with carry clear, so a positive signature is the only honest test.

NVOICES is read rather than assumed so software written against eight voices
still works if a build has four, and gains nothing to fix if a build has
sixteen.

Addresses are **physical byte addresses**, 20 bits, exactly what a real-mode
program computes as `segment*16 + offset`. No upload step and no separate
address space: the samples stay where DOS loaded them.

STEP is 8.16 rather than 16.16. The integer part is how many sample bytes
advance per output sample; at 48 kHz output the highest MOD note is under 4, so
eight bits is generous and it saves a byte of I/O per note.

`VOL` is 0..64 to match MOD's own range, so software never rescales.

## Sample rate and pitch

The engine runs at **48 kHz**, the same clock the USB audio path already uses,
divided from CLK48. That matters: the output rate is then a crystal and not the
CPU clock, so pitch does not move when the speed ladder does — the same reason
`sb_dsp` takes its sample clock from CLK48.

Software converts an Amiga period to a step:

    rate = 3546895 / period          (PAL clock / 2)
    step = rate / 48000, as 8.16

One divide per note, in software, where it belongs.

## Memory

Each voice holds a phase accumulator and one prefetched byte. On each 48 kHz
tick a voice advances its phase; when the integer part changes it needs a new
byte.

    worst case   8 voices x 48000 = 384,000 reads/second

The SDRAM at 50 MHz manages several million random reads a second, so this is
under a tenth of it. **Bandwidth is not the question — arbitration is.** This
needs a new read port on `sdram_arb`, and that is the one part of this touching
something that currently works.

Two things make the port easy to satisfy:

* it is **read-only**, so no write-ordering hazards with the CPU or the DMA
* it can be given **lowest priority**. A voice fetches the byte it will need
  next, not the one it needs now, so it tolerates tens of microseconds of
  latency. Audio glitches when a fetch never arrives, not when it arrives late.

If arbitration proves awkward, the fallback is a small M9K prefetch buffer per
voice filled in bursts — more logic, less arbiter pressure. Worth knowing the
escape route exists before starting.

## Mixing and output

Volume is a real multiply. The EP4CE22 has 66 embedded 18x18 multipliers and
this design uses none of them, so the software mixer's volume-lookup trick is
unnecessary here — and a multiply is more accurate than a table quantised to
±31.

    voice_out = sample(signed 8) * vol(0..64)     -> +/-8128
    sum of 8                                      -> +/-65024, 17 bits
    >> 9                                          -> +/-127

The sum saturates rather than wraps, for the reason the existing mixer does: an
overflowing signed sum does not become quiet, it becomes the loudest possible
noise with the sign inverted.

Output joins the existing chain, which is already a pass-through pipeline:

    opl2_lite --> sb_dsp --> voices --> usb_host

Each stage takes `PCM_IN`/`PCM_STB_IN` and emits the sum. Adding a stage needs
no mixer module and no change to `usb_host`, and AdLib, Sound Blaster and the
voices arrive as one signal.

## What the software looks like

MODPLAY loses its entire mixer, its accumulator, its volume tables and its
double buffer. What remains is the part that was never the problem:

    per row:   read the pattern, and for each channel that has a new note,
               work out the step, then write START/END/LOOP/STEP/VOL and key on
    per tick:  apply effects by writing VOL or STEP

That is a few dozen I/O writes every 20 ms against 44,100 sample operations a
second. The `busy` figure should become unmeasurable, and eight voices should
cost no more than four.

MODPLAY probes for 'GV' at startup and uses the voices when it finds them,
falling back to the software mixer when it does not. Both paths stay in the
binary: the same executable plays a module on a board with this bitstream and
on one without, and `-s` forces the software path so the two can be compared on
the same module in the same session.

Tick timing differs between the paths and this is easy to get wrong. In software
mode the sequencer advances by samples MIXED, which is self-clocking. With the
mixing gone there is nothing to count, so the hardware path derives ticks from
PIT channel 0 -- polled, not reprogrammed, because DOS owns that timer. Mode 3
decrements it by two, so it spans 32768 clocks and wraps every 27.5 ms, while a
tick at 125 BPM is 20 ms: comfortably inside one span provided the loop polls
more than twice per wrap, which it does with nothing else to do.

## Cost

    8 voices, ~200 LE each                ~1600
    fetch engine and arbiter port          ~400
    mixer and output stage                 ~300
                                          ------
                                          ~2300 LE

Against 10,300 free, taking utilisation from 54% to roughly 64%. Memory bits
are untouched unless the prefetch fallback is needed.

The channel count is a **generic**. Eight is the number chosen, four is what a
ProTracker module uses, and the difference is one line — so the decision is
reversible if the fetch rate or the fitter says otherwise.

## Order of work

1. `voices.vhd` with the register file and phase accumulators, fetching from a
   stub that returns a fixed value. Proves the register interface and the
   pitch arithmetic with no arbiter involvement at all.
2. The `sdram_arb` read port, with one voice reading real samples.
3. All eight, and the mixer.
4. MODPLAY's `-h` flag to use the hardware, keeping the software mixer so the
   two can be compared on the same module in the same session.

Step 1 is testable from DOS before anything touches the memory controller,
which is where the risk is concentrated.
