# Log 8 — Where it is now, and how to run one

*Suggested title: "v1.31 — everything is published, including the mistakes"*

---

Six releases since the end of July 2026. The current one is **v1.31**.

Each release publishes the chipset and the BIOS **separately**, and both are needed: the
FPGA bitstream is the chipset, the `.64k` is the firmware that runs on it, and updating
one does not update the other.

The same bitstream ships in four containers, differing only in what can open them:

| File | Programmer | Persists across power-off? |
|---|---|---|
| `.sof` | Quartus (`quartus_pgm`) | no — this session only |
| `.jic` | Quartus, via JTAG into the config flash | yes |
| `.rbf` | **openFPGALoader** — macOS, Linux, no Quartus needed | no |
| `.rpd` | **openFPGALoader**, written to the config flash | yes |

```
openFPGALoader -c usb-blaster gertieboard.rbf                    # this session only
openFPGALoader -c usb-blaster -f --file-type rpd gertieboard.rpd # into the config flash
```

The `.rbf` and `.rpd` exist because requiring a full Altera toolchain to try someone
else's FPGA project is a real barrier, and it is not one this project needs.

## Release history

| Version | Headline |
|---|---|
| **v1.31** | Flashing the BIOS no longer depends on which device owns `B:` |
| **v1.30** | A USB floppy as `B:`, AdLib over USB audio, and a machine that boots at 10 MHz |
| **v1.21** | Low-speed USB, and a keyboard typing into DOS |
| **v1.20** | A USB mouse in real games — and the clock fix that raised the CPU ceiling |
| **v1.10** | EGA mode 0Dh, 640 KB in SDRAM, and every off-chip interface finally timed |
| **v1.00** | First release: a machine that boots on its own |

## What is in the repository

Everything, under **MIT**:

- **VHDL** for the whole chipset — every module documented individually with its entity
  ports, its addresses and its behaviour
- **The BIOS**, in 8088 assembly, pinned to `.arch i8086` deliberately so the sources stay
  honest to the machine they claim to be — even though the V20 would accept more
- **DOS-side diagnostics**: enumerate any USB device, benchmark disk reads, check PIT
  behaviour under reprogramming, dump video state, verify EGA planes, flash the BIOS from
  DOS
- **Build and programming scripts** for both toolchain paths
- **[docs/gotchas.md](https://github.com/mathijsvandenberg/gertieboard/blob/main/docs/gotchas.md)**
  — the lessons, written down as they happened. Several cost days. One of them, an
  assembler quietly emitting a 386 instruction that is not a branch at all on this CPU,
  cost considerably more.

If you are thinking of building one, read the gotchas page first. It is the single most
useful thing in the repository.

## What is not published yet

**The top board's schematics.** They are coming; until then the hardware and pinout pages
describe what is connected to what. The FPGA half runs on a stock DE0-Nano today, so the
chipset can be examined without the top board existing.

## What is next

**USB throughput** — reads peak at 221 KB/s at 10 MHz, and the ceiling is mostly the
CPU's byte-at-a-time copy rather than the wire. Only *mostly*, though: doubling the clock
buys 1.6×, not 2×, so the bus is roughly 40 % of it now. Memory-mapping the packet buffer
into on-chip RAM turns the copy into a `rep movsb`.

**USB hubs** — one device per port today; a hub needs the hub class driver, and a
low-speed device behind a full-speed hub additionally needs `PRE` packets.

**NumLock and CapsLock** on the USB keyboard, **real OPL2 FM synthesis**, and **EGA modes
0Eh and 10h**.

Budget-wise there is room: **38 % of the logic elements** and **49 % of the M9K bits** are
committed, and 26 of the 66 memory blocks are free. Both numbers were much tighter before
conventional memory moved out of on-chip RAM.
