# Log 1 — Why there is a real CPU in the socket

*Suggested title: "The FPGA is the chipset, not the computer"*

---

The easy version of this project is a soft core. Put an 8088-compatible CPU in the
fabric with everything else, and you have a PC on one chip, with a debugger, single-step,
signal taps, and timing you control completely.

That is not this. There is a **NEC V20 (µPD70108C-8)** in a 40-pin socket on the top
board, and it is doing the actual work. The FPGA underneath plays exactly the role the
surrounding chips played in 1983 — bus decode, memory controller, video, PIC, PIT, PPI,
DMA, FDC, keyboard controller, boot ROM — and nothing more.

The difference is not philosophical, it is a schedule. With a real CPU:

- **Every bus cycle is a negotiation with a part you cannot change.** The V20 puts out a
  multiplexed address/data bus and expects READY inside a window measured in nanoseconds
  from *its own* clock edge. Miss it and there is no error message; the machine simply
  does not boot, or boots differently each time.
- **The datasheet is the specification.** Not the simulator, not the timing report. Half
  the work in this project has been translating a 1984 µPD70108 datasheet into constraints
  a modern fitter will honour.
- **You cannot single-step it.** The debugging instruments are a seven-segment digit,
  a serial link, and whatever the video output is willing to show you.

What you get back is that the machine is a real one. It is not "a PC/XT if you squint" —
it is a V20 executing 8088 code out of memory that an FPGA happens to be pretending to be,
at 10 MHz, and software from 1983 cannot tell the difference.

The other thing that shaped the design: **it had to be solderable by hand.** Almost
every part on the top board is through-hole — the CPU in a socket, the VGA and PS/2
connectors, both USB ports, the seven-segment display, the buzzer, the reset button, both
40-pin headers. Only two parts are surface-mount and both are SOIC-8, which is a pitch an
ordinary iron still reaches.

That is also why the FPGA is a stock **Terasic DE0-Nano** on headers rather than a
Cyclone IV soldered to the board. Nobody should need a reflow oven to own one of these.

The person who was going to solder it is my father. More on that in a later log.
