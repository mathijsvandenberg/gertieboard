# Log 7 — AdLib, with the CPU nowhere near the audio path

*Suggested title: "An OPL2 at 0x388 that plays out of a USB speaker"*

---

The PC speaker has worked since early on: 8253 channel 2, gated through the PPI, driving
the buzzer on the top board. That is the authentic sound and it is exactly as unpleasant
as you remember.

**AdLib** was the next step, and it started as the obvious approximation: answer the
detection handshake at `0x388` so software believes a card is present, then render the
nine channels as square waves on the same buzzer. Not FM synthesis, but enough that games
detect the card and play *something* recognisable.

Then it got a real output path, and the interesting part is where the CPU is: **nowhere**.

The OPL2 block renders **48 kHz PCM in the 48 MHz clock domain** straight into a double
buffer, and the USB serial interface engine ships one **isochronous packet per frame** on
its own, every millisecond, without being asked. The CPU writes OPL registers at `0x388`
exactly as it would to a real card and then forgets about it.

That property matters more than it sounds. DOS games take over the machine — they
reprogram the PIT, mask interrupts, and run in tight loops with no expectation that
anything else needs servicing. Any audio scheme that needs the CPU to feed it dies the
moment a game does that. This one does not have to be fed.

The engine also supports vendor-specific audio devices, inferring the format from the
packet size rather than insisting on a compliant descriptor set.

## What is honest about the current state

The tone plays and it is stable enough to be useful, but this is the least finished
subsystem on the board. Two things are still open:

- **Glitching** under some conditions, which is on the list rather than solved.
- **Real FM synthesis.** What is there now approximates the OPL2's channels; it does not
  implement the operators, envelopes and modulation that make an OPL2 sound like an OPL2.

The infrastructure that made this possible — DMA, the PIC, the USB engine — was all
already present and proven for other reasons, which is the usual pattern here: each
subsystem makes the next one cheaper.
