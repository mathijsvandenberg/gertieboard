# Files

Hackaday's Files tab is where a judge finds out whether this is a project someone else
could actually run. One archive is enough, and it is already built:

**[upload/gertieboard-v1.31.zip](upload/gertieboard-v1.31.zip)** — 0.7 MB

Contents:

| File | What it is |
|---|---|
| `gertieboard.sof` | Bitstream for Quartus, this session only |
| `gertieboard.jic` | Bitstream for Quartus, into the DE0-Nano's EPCS16 config flash |
| `gertieboard.rbf` | Bitstream for openFPGALoader — no Quartus needed |
| `gertieboard.rpd` | Same, written to the config flash |
| `gertieboard_bios.64k` | The BIOS, 64 KB F-segment image |
| `SHA256SUMS` | Checksums |
| `manifest.json` | Machine-readable asset list |
| `README.txt` | Which file goes where, and the two openFPGALoader commands |

**Description to paste into the file's description field:**

> Gertieboard v1.31 — the FPGA chipset and the BIOS. Target is a stock Terasic DE0-Nano
> (Cyclone IV E EP4CE22F17C6). Four bitstream containers so it can be programmed from
> Quartus or from macOS/Linux with openFPGALoader and no Altera toolchain at all. The
> bitstream is the chipset and the `.64k` is the BIOS that runs on it — both are needed,
> and updating one does not update the other. MIT licensed.

## Worth adding later

- **The top board schematics**, once they are published. Right now their absence is the
  one real gap between "open source" and "open hardware", and the Details page says so
  honestly rather than glossing it. A PDF of the schematic in this tab would close it.
- A **PDF of the documentation set** — `docs/` is substantial and Hackaday readers do
  browse the Files tab. Optional; the GitHub links carry it well enough.

## Do not upload

Disk images, DOS, the Philips ROM dumps, or the games. None of them are yours to
redistribute, they are gitignored in the repository for exactly that reason, and the same
reasoning applies here.
