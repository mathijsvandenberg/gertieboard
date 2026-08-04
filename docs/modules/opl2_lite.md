# opl2_lite — AdLib front end

**I/O `0x388`–`0x389`** · instance `opl2lite1` · clocked from `c0` (8.33 MHz) ·
[`opl2_lite.vhd`](../../opl2_lite.vhd)

Answers the AdLib detection protocol honestly and turns what a game writes to the OPL2
into something audible on the one-bit buzzer. **It is not an FM synthesiser.** Each of
the nine channels contributes a square wave at the pitch the game asked for; the nine
are summed and rendered by PWM.

## Why AdLib and not Sound Blaster

A Sound Blaster is an AdLib plus a DAC, and the two halves make very different promises.

Announcing a Sound Blaster commits this board to servicing **DMA channel 1 and an
interrupt** — a game sets up a transfer and waits for a completion IRQ, and if it never
comes the game hangs. The AdLib half promises nothing: register writes, no DMA, no
interrupts, and nothing that can wedge the machine if it is imperfect. It is also the
half that carries the music in everything of this era, including Keen.

Detection-only would have been *worse than silence*: a game would find the card, select
it, and write its music into a void — trading no music for music that is missing, which
is a much harder fault to see.

## What is deliberately absent

| Missing | What it costs |
|---|---|
| Envelopes | Notes start and stop at full volume and never decay, so anything relying on a fast decay sounds sustained |
| Operators | The timbre is a square wave, not the patch the game chose |
| Rhythm mode (`0xBD`) | Percussion on channels 6–8 is silent |
| Total level (`0x40`–`0x55`) | Every channel is equally loud |

None of those can hang anything — they only affect how it sounds. The register decode
and the per-channel state are the same front end a real OPL2 core would sit behind, so
this is a foundation rather than a detour.

## Detection — the part that has to be exact

Every AdLib-aware program uses the same sequence, and it rests entirely on the two
timers, not on anything that makes sound:

```
write reg 4 = 0x60    stop and mask both timers
write reg 4 = 0x80    reset the status flags
read  0x388           status1: (status1 AND 0xE0) must be 0x00
write reg 2 = 0xFF    timer 1 preset -- one tick from overflow
write reg 4 = 0x21    start timer 1, mask timer 2
      ...wait >= 80 us...
read  0x388           status2: (status2 AND 0xE0) must be 0xC0
```

So the timers must keep real time (80 µs and 320 µs per tick), the flags must set on
overflow and clear on the reset command, and bits 4–0 must read back as zero. Both
timers count **up** from their preset and overflow past `0xFF` — which is why a preset
of `0xFF` expires in a single tick, and the detection depends on exactly that.

### Status register, read at `0x388`

| Bit | Meaning |
|---|---|
| 7 | Either unmasked timer has expired |
| 6 | Timer 1 expired |
| 5 | Timer 2 expired |
| 4–0 | Always zero |

Bits 4–0 reading zero is what makes the byte never `0xFF`, so "is anything there?" is
answerable at all. That is the same property an absent device lacks — see
[gotchas](../gotchas.md) on open-bus reads.

## Pitch

The OPL2's own model is a phase accumulator, so this uses it directly rather than
dividing anything. The chip's output frequency is

```
f = FNum * 49716 / 2^(20-Block)
```

which is exactly what a **20-bit accumulator ticked at 49716 Hz and incremented by
`FNum << Block`** produces, with bit 19 as the square wave. No division and no
multiplier — the increment is the register value shifted, which is why the arithmetic in
the source looks too simple to be doing anything.

`CLK_HZ` is a generic and every divider comes from it, in the style of `fdc8272`'s
`BAUD_DIV`, so the module does not care which clock it is wired to — but **it must
match**, because the detection timers depend on real time.

At 8.333 MHz the sample divider truncates to 167, giving 49900 Hz against the ideal
49716: **+6.4 cents**, uniform across the whole range, so nothing is out of tune with
itself even though everything is fractionally sharp.

Raising the bus clock improves this for free — a bigger divisor quantises more finely.
At the old 5 MHz the divider truncated to 100 and came out **+9.8 cents**; 10 MHz would
have given +1.2, because 10e6/49716 lands close to a whole number by luck rather than by
design. The error does not fall monotonically with clock rate, it depends on where the
truncation lands.

The timers are near-exact at this rate: `8333333/12500 = 666` gives 79.92 µs against 80,
and `8333333/3125 = 2666` gives 319.92 µs against 320 — 0.1 % short, far inside what the
detection handshake cares about.

## Output and mixing

The buzzer is one bit, so nine square waves are summed to a 0–9 value and rendered as
PWM against a 4-bit counter. At 8.333 MHz that carrier is 521 kHz — far above anything a
piezo can follow, so it hears the average.

`SND` is combined with the PC speaker **in the top level**, not here:

```vhdl
BUZ <= '0' WHEN SPEAKER_MUTE = '1'
       ELSE ((n_speaker_data AND n_out2) OR n_opl_snd);
```

When nothing is keyed on the mix is zero and `SND` sits at `'0'`, so the OR is
transparent in both directions and the speaker path is bit-for-bit what it was. Both
sounding at once distorts — rare, and audible rather than silent, which is the right way
round for a fault. `SPEAKER_MUTE` still silences everything.

## Verification

The logic was modelled independently in Python before synthesis — the same approach that
found the USB bit-stuffing bug — driving the real detection sequence and measuring the
resulting pitch:

```
=== AdLib detection handshake ===
  status1 = 0x00   (status1 & 0xE0) == 0x00 : True
  status2 = 0xC0   (status2 & 0xE0) == 0xC0 : True
  DETECTED: True
  timer 1 flag set after 76.5 us          (+ alOut's 35 trailing reads = 80)
  masked timer 1 after 500 us: status = 0x00
```

Pitch came out **+0 to +2 cents** across `FNum`/`Block` combinations from 110 Hz to
6.2 kHz when the module ran at 10 MHz, consistent with the +1.2 that divisor predicts;
the spread is the measuring window, not the hardware. An earlier run at 5 MHz showed a
*varying* error of 8–22 cents, which was a 200 ms window quantising to 5 Hz rather than a
real defect — worth knowing, because the honest-looking number was the wrong one.

**Those measurements have not been repeated at 8.333 MHz.** The divisor arithmetic above
predicts a uniform +6.4 cents, and being uniform is what matters musically, but that is a
calculation and not a measurement. Re-run the model against `CLK_HZ = 8_333_333` before
relying on it — the reason this section exists is that the figures were once assumed to
scale and did not.
