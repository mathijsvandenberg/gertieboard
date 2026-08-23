# Hackaday.io page material

Paste-ready content for
<https://hackaday.io/project/206479-gertieboard-pc-xt-8088-cpu-board-fpga-chipset>
and for the **[Retrocomputing Contest](https://hackaday.io/contest/206399-retrocomputing-contest)**
(deadline **Tuesday 27 October 2026, 22:00 PDT**).

| File | Goes where on Hackaday |
|---|---|
| [summary.md](summary.md) | The one-line **project summary** under the title (Edit project → Summary) |
| [details.md](details.md) | The **Details** body |
| [components.md](components.md) | **Components** tab — one row each |
| [logs/](logs/) | **Build logs**, oldest first |
| [gallery.md](gallery.md) | Image **gallery** captions, in order — resized images in [gallery/](gallery/) |
| [files.md](files.md) | **Files** tab uploads — archive built in [upload/](upload/) |

## The build logs

Publish them oldest-first so the page reads as a chronology. Hackaday timestamps a log
when you publish it, so posting all eight in one sitting is fine.

| # | Log | What it carries |
|---|---|---|
| 1 | [Why there is a real CPU in the socket](logs/01-why-a-real-cpu.md) | The premise, and why it is hard on purpose |
| 2 | [Four years in a drawer, and the 14 nanoseconds](logs/02-fourteen-nanoseconds.md) | **The flagship log.** READY arriving inside the sampling aperture. Post this one even if you post nothing else |
| 3 | [A USB host controller with no host controller](logs/03-usb-host-in-fabric.md) | SIE in fabric, the three error-path bugs, the pulldown range |
| 4 | [EGA mode 0Dh and Commander Keen 4](logs/04-ega-and-commander-keen.md) | Planes, latch/ALU, the row-stride finding, the wrong theory |
| 5 | [Three drives, and a DOS 4.01 install](logs/05-three-drives-and-a-dos-install.md) | Serial `A:`, flash/USB `B:`, USB `C:` |
| 6 | [The boot screen is my father's actual PC](logs/06-my-fathers-actual-pc.md) | The P2120, the retirement, 10 MHz four decades apart |
| 7 | [AdLib with the CPU nowhere near it](logs/07-adlib-over-usb-audio.md) | OPL2 → 48 kHz PCM → isochronous USB |
| 8 | [Where it is now](logs/08-where-it-is-now.md) | v1.31, the four bitstream containers, what is next |

Logs 2 and 6 are the two that make this project memorable rather than merely impressive:
one is a debugging story with a real technical payoff, the other is why the board exists.

## Contest checklist

- [ ] Summary replaced (the current one reads machine-generated)
- [ ] Details body filled in — right now it is only a GitHub link
- [ ] At least 4–5 build logs published *(judging is "document your project as well as you can")*
- [ ] Components list populated
- [ ] Files attached (bitstream + BIOS, so somebody can actually run it)
- [ ] Gallery captioned and ordered — board photo first
- [ ] Project set **public** and marked **complete-ish / ongoing**
- [ ] Submitted to the contest from the project page ("Submit project to..." on the project's own page)
- [ ] Entrant agrees the design may be published on Hackaday — it is MIT, so this is already true

**Category:** the contest has four honourable-mention categories and the judges assign
them; this project sits across **Modern Retro** (the chipset is an FPGA) and **Old Iron**
(the CPU is a real NEC V20 doing the actual work). Say so plainly in the Details rather
than picking one — the real-CPU split *is* the hook.
