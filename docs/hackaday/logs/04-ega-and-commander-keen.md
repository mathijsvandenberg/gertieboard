# Log 4 — EGA mode 0Dh, and getting Commander Keen 4 to run

*Suggested title: "Four bit planes, a latch/ALU, and a game that finds every mistake"*

---

CGA came first and was, relatively speaking, the easy one: modes 0–3 text plus graphics
modes 4, 5 and 6, scan-doubled and pushed out of the VGA connector as 640×480 at 60 Hz.
The FPGA drives the connector directly — there is no external DAC on the board.

**EGA mode 0Dh** — 320×200 in 16 colours — was a different proposition, because EGA is
not a framebuffer. It is four separate 64 KB bit planes behind a register file, with a
read-modify-write path in hardware that software depends on:

- the **latch** registers, which hold one byte from each plane from the last read
- the **ALU**, which combines written data with those latches (AND / OR / XOR / replace)
- **plane masks** and **bit masks**, so a write can touch some planes and some bits
- the **16-of-64 palette**
- **CRTC start address**, which is how the game page-flips

All four planes live in the SDRAM on the DE0-Nano, behind a scanline prefetch buffer.
That was the decision that made this possible at all: 256 KB of planar memory is not
going to fit in a Cyclone IV E's on-chip M9K, and once the planes were off-chip the
memory argument stopped being an argument.

## Commander Keen 4 is a good test and a cruel one

It is a real 1991 EGA game with a smooth-scrolling engine, and it uses essentially every
feature above. The gallery on this project is, honestly, mostly the failures — diagonal
tearing, doubled title screens, an id Software intro drawing itself twice.

Two findings were worth the trouble:

**The row stride is whatever the Offset register says, not 40.** Keen sets up three
display pages and flips between them; with a hardcoded stride all three landed on top of
each other, which on screen looks like the game overlapping itself. That single number
explained a class of glitches I had been treating as separate bugs.

**The 16 KB plane theory was wrong.** For a while the working assumption was that the
plane size was the problem. It was not — the planes were fine, and chasing that cost
several days that a more careful reading of what the CRTC was being told would have
saved. Worth writing down because the wrong theory *also* produced improvements, which is
exactly what makes a wrong theory expensive.

**`INT 43h` was never set**, so nothing could find the 8×8 font and text drawn in
graphics modes came out blank. A one-line fix at the end of a long hunt.

## Where it stands

Mode 0Dh works, Keen 4 runs on it, and King's Quest I draws its castle. Page flipping
works via the CRTC start address in EGA.

Still open, and recorded as unfinished rather than broken: **CGA ignores the start
address**, so anything that scrolls a text or mode 4/5/6 screen by moving R12/R13 will not
scroll. It was wired in once and reverted — it shifted Arkanoid's *text* screen, which
rules out the word-versus-cell doubling that graphics mode makes the obvious suspect and
leaves the hardcoded 80-byte row length as the likely culprit. There is a test program
(`SCROLLTST`) that drives R12/R13 by a known amount against a readable pattern, precisely
so the next attempt is not made with the screen as the only instrument.

**Modes 0Eh and 10h** are next: they need 64 KB and 112 KB of planar memory and a 350-line
CRTC. The planes are already in SDRAM, so what remains is mode plumbing rather than an
argument about where the memory comes from.
