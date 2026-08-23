# Log 6 — The boot screen is my father's actual PC

*Suggested title: "A Philips P2120, a retirement, and 10 MHz four decades apart"*

---

This board is called **Gertieboard** after my father, **Geert** — known to everyone as
Gertie — who is, like me, an enthusiast for retro computing.

It was built for him. Not a product and not a project looking for an audience: one board,
for one person, as a gift he could solder himself. That is the reason nearly everything on
it is through-hole and the only fine-pitch device is the off-the-shelf DE0-Nano
underneath. The whole design answers one question — *can he build this at his own bench,
with his own iron?*

He soldered one.

Then the board went in a drawer for four years, because it did not work reliably and I
could not find out why. What got it out again was my father turning **67 and retiring**.
That became the deadline, and it is why the BIOS banner reads **"Gertieboard BIOS
Retirement Edition"** — I wanted the board he had soldered to actually work, and to hand
it to him now that he finally has the time for it.

## The screen

The first PC in the house was a **Philips P2120** with a Philips **7BM723** monochrome
monitor. Years later he pulled its ROM chips out for me and I dumped them.

The boot screen on this machine is a deliberate reproduction of that one: same layout,
same wording, same spacing, down to `Parity Checking Enabled` printed on a machine that
has no parity to check. The code is written from scratch; three short strings are
reproduced verbatim because that is what makes it look right.

**The characters are his machine's too.** The P2120's character generator ROM is in the
FPGA, so every letter on screen is the exact bitmap that monitor used to draw.

(For a long time I was not sure whether I was copying a P2120 or a P3105, because the ROM
calls itself `P3105 BIOS` while the machine it came out of was a P2120. It turns out there
is nothing to choose between them — the dump is byte-identical either way. Philips shipped
one BIOS across both models.)

No Philips BIOS code is in this BIOS, and the ROM dumps themselves are not in the
repository. The font bitmaps are, deliberately, and both fonts are swappable if that
distinction matters to you.

## 10 MHz, from the other direction

The P2120 left the factory at 4.77 MHz. The chip inside it was an **8088-1** — a part
rated for 10. One of the first things my father and grandfather did was enable the turbo
pin, so the family's real PC ran at **10 MHz** from early on.

**This board runs at 10 MHz too.** It arrived there from the opposite direction: the V20
in the socket is a `-8`, so it is over its rating where theirs was comfortably inside one.
And it did not get there by turning a knob — 10 MHz was written off as impossible for
months, and what was actually stopping it was
[READY arriving late](02-fourteen-nanoseconds.md), not the part.

Same number, four decades apart, for the same reason: somebody wanted to know if it would
go faster.

Worth stating plainly for anyone building one: pin 40 measures **3.33 V** on a part rated
4.5–5.5 V, with no droop during reset. It is out of spec and it works. The clock input is
the pin to watch, because its threshold is specified at an absolute 3.0 V, which a 3.3 V
LVTTL swing clears by very little — a single buffer on the clock line would settle that
question more cheaply than raising the whole rail.
