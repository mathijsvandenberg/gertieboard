# Log 2 — Four years in a drawer, and the 14 nanoseconds that put it there

*Suggested title: "The handshake cannot govern the handshake"*

---

The top board was built in **2021**. The silkscreen still reads `MVDB 2021 REV 100`.
Then it stalled for the better part of four years, on three problems that would not give
way:

1. **Memory corruption** — writes that read back wrong, not always, not reproducibly.
2. **Timing closure** — never quite clean, and never quite explicable.
3. **Negative slack that came back** however the design was pushed around.

The symptom that made it hopeless was this: *some bitstreams booted and some did not, and
the difference survived a power cycle.* A build that booted was rock solid — it would run
games for hours. A build that did not, never did. Recompiling the same source with no
changes could flip it either way. That looks exactly like a cold solder joint or a
marginal supply, and it was neither.

A machine that boots differently every time is not a machine you can debug your way
forward on. The board went in a drawer.

## What it actually was

The timing constraints file false-pathed the entire off-chip CPU bus, in both directions,
and it explained itself:

> Correctness is governed by the READY handshake and the long (≥200 ns) bus cycle, not by
> meeting setup on a single 20 ns system-clock edge.

That sentence is *true*. It is also not true of everything it was applied to. Two signals
on that bus are referenced to the **CPU's own clock edges** and have requirements nothing
else can satisfy on their behalf — and one of them is READY, which cannot be governed by
the handshake because it **is** the handshake.

From the µPD70108 datasheet:

| | | |
|---|---|---|
| `tSRYLK` | READY setup to CLK↓ | **−8 ns** — may arrive at most 8 ns *after* the edge |
| `tSDK` | read data setup to CLK↓ | 20 ns |

Measured on the fit that was current when this was found, launch edge to pin:

```
CPU_CLK     4.442 ns
CPU_RDY    18.441 ns   <- 14.0 ns behind the clock; the part allows 8
CPU_AD     22.891 ns
```

READY had been arriving **inside the CPU's sampling aperture** rather than clear of it,
on every build, since 2021. Which side of the aperture a given bitstream landed on was
decided by placement — which is precisely why recompiling changed the answer and nothing
in the source correlated with it.

Every timing report had been green the whole time, because nobody was analysing the path.

It also spent a week impersonating a memory fault. Conventional memory was moved off the
PSRAM entirely and onto SDRAM — different chip, different bus, different controller — and
cold boot still failed four times in five. The memory was never the marginal thing.

## The fix, in three parts

Only the first is a constraint:

- **Bound the paths**, with numbers derived from the datasheet rather than from whatever
  today's fit happened to achieve.
- **Take the address decode out of the READY path.** The memory block was selecting
  between its two sub-blocks by decoding the address, which it does not need to do — each
  sub-block already idles at `'1'` outside its own range, so a plain AND gives the same
  answer for every address with no decode at all. A 20-bit comparator came off the
  critical path entirely.
- **Bound `CPU_CLK` at both ends**, so the time the clock spends reaching the CPU can be
  *claimed* as part of READY's budget instead of merely observed.

READY went from **18.441 ns to 10.346 ns**. Cold boot went from one attempt in five to
**five in five**.

## The part that is worth passing on

All three of the original blockers were this one fault wearing three hats. Everything that
came afterwards — CGA, the keyboard, DMA, DOS, a hard disk, a USB host controller — had
only ever been waiting on a machine that behaved the same way twice. Once it did, the
project went from stalled to booting DOS in weeks.

If you have an intermittent that survives a power cycle and moves when you recompile:
**stop looking for the flaky component and go find the path nobody is analysing.**

The full write-up, along with about thirty other lessons that cost real days, is in
[docs/gotchas.md](https://github.com/mathijsvandenberg/gertieboard/blob/main/docs/gotchas.md).
