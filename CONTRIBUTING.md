# Contributing

Contributions are welcome — fixes, new peripherals, better documentation, or just a
report that something does not work on your board.

## Licensing of contributions

By opening a pull request you agree that your contribution is licensed under the
[MIT Licence](LICENSE), the same terms as the rest of the project. There is no CLA to
sign and no paperwork.

Do not contribute code you did not write or do not have the right to relicense. In
particular, **no disassemblies of commercial BIOSes, no ROM dumps and no disk images** —
see [Third-party content](README.md#third-party-content).

## Before you start

Read **[docs/gotchas.md](docs/gotchas.md)**. It is short, and it will save you days.
The first entry in particular applies to anyone writing 8088 assembly for this machine:
an assembler will silently emit a 386-form conditional jump that is not a branch at all
on this CPU, and nothing about the symptom points at the cause.

For orientation:

| You want to | Start at |
|---|---|
| Understand the machine | [docs/architecture.md](docs/architecture.md) |
| Change or add a peripheral | [docs/modules/](docs/modules/README.md) |
| Work on the BIOS | [docs/bios.md](docs/bios.md) |
| Build anything | [docs/building.md](docs/building.md) |
| Find something to work on | [docs/status.md](docs/status.md) |

## Practical notes

- **Pin the CPU architecture** in every assembly file: `.arch i8086` for GNU `as`,
  `CPU 8086` for NASM. Non-negotiable — see above.
- **Use the build scripts** (`tools/mkbios.sh`, `tools/mkjic.sh`) rather than running
  the steps by hand. They verify their output; a hand-run chain once served a two-day-old
  image while looking perfectly healthy.
- **Instance names are load-bearing.** `gertieboard.sdc` references the PLL by instance
  path, so renaming a top-level instance silently drops timing constraints. After an
  FPGA change, check that nothing was dropped:

  ```bash
  quartus_sta gertieboard 2>&1 | grep "could not be matched"
  ```

- **Say how you tested it.** This is a hardware project and most of it cannot be
  verified by reading. "Runs on my board, DOS 3.3 boots, HDTEST 1–7 pass" is worth more
  than a clean diff. If you could not test on hardware, say so — that is fine, just say
  it.
- **Update the docs in the same change.** Every module has a page under
  [docs/modules/](docs/modules/README.md); if you change ports, addresses or behaviour,
  change the page too.

## Reporting a problem

Include the **POST code** on the 7-segment display if the machine stops, what the screen
showed, and which BIOS build you were running. A steady code does not mean "halted" —
the display only restarts its cycle when the value changes, so a tight retry loop looks
identical to a hang.
