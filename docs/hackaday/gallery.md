# Gallery

All 26 development photos plus the board shot have been resized to 1600 px and are in
**[gallery/](gallery/)**, ready to upload — the originals are 4032×3024 and 2–3 MB each,
which is more than the page needs.

The gallery is the first thing a judge scrolls through, so the order matters more than
the count.

## Recommended order

| # | File | Caption to use |
|---|---|---|
| 1 | `00-gertieboard-rev100.jpg` | **The Gertieboard Mini XT**, `MVDB 2021 REV 100`, with a POST code on the seven-segment digit. The NEC V20 is the 40-pin DIP in the socket; the DE0-Nano carrying the chipset sits underneath on the two 40-pin headers |
| 2 | `12-keen4-ega-gameplay-vines.jpg` | **Commander Keen 4 in EGA mode 0Dh** — 320×200×16, four bit planes in SDRAM, on a machine whose entire video adapter is FPGA fabric |
| 3 | `09-keen4-title-screen-ega.jpg` | Keen 4's title screen, EGA |
| 4 | `10-keen4-border-village-story-a.jpg` | The story screens — text and graphics in the same planar mode |
| 5 | `18-kq1-castle-ega-a.jpg` | **King's Quest I**, EGA. Sierra's AGI interpreter is a good stress test: it mixes drawing modes constantly |
| 6 | `25-kq1-restore-game-dialog.jpg` | KQ1's restore dialog — text overlays working after a long fight with them |
| 7 | `01-prince-of-persia-cga-gameplay.jpg` | **Prince of Persia** in CGA. It runs — around 4–5 fps, and it refused to start at all until the 6845 CRTC registers answered at `0x3D4`/`0x3D5` so it could *detect* the card |
| 8 | `14-kq1-title-mono.jpg` | KQ1 early on: running, but very slow, and the music slower still |
| 9 | `08-keen4-setup-screen-ega.jpg` | **Debugging EGA.** Keen is underneath and running — the diagonal tearing is the plane addressing not yet right |
| 10 | `05-keen4-id-software-intro-glitch.jpg` | The id Software intro drawing itself twice. The row stride is whatever the Offset register says, not a hardcoded 40 — that one number explained a whole class of these |
| 11 | `03-keen4-title-screen-cga.jpg` | A regression, caught on the title screen: the image overlaps itself |
| 12 | `17-kq1-credits-screen.jpg` | Corruption on the KQ1 credits screen, mid-hunt |

## Notes

- **Include the failures.** Roughly half these photos are glitches, and that is a
  feature — the contest asks entrants to document the project so others can follow along,
  and a gallery that goes *broken → less broken → working* tells the story that a row of
  finished screenshots cannot.
- **Two photos still worth taking**, and both would strengthen the page a lot:
  1. **The Philips P2120 boot screen** — the reproduction of your father's actual machine,
     P2120 font and all, is one of the most distinctive things about this project and it
     is not in the gallery at all. This should arguably be image #2.
  2. **A wider shot of the machine running** — board, VGA monitor, keyboard, USB stick,
     all on the bench, DOS at the prompt. It is the "this is a real computer" photo, and
     the page currently has nothing that shows the whole thing at once.
- A short **video** of DOS booting — the P2120 screen, the memory count, then `C:\>` —
  would be worth more than any still. Hackaday.io embeds YouTube.
- The remaining photos in `gallery/` (`02`, `04`, `06`, `07`, `11`, `13`, `15`, `16`,
  `19`–`24`, `26`) are more of the same debugging sequences; add them if you want the
  gallery deep, leave them out if you want it sharp.

The original captions from `docs/photos/games/manifest.json` are development notes to
yourself ("still corruption", "getting closer now!"). They are charming but read as
private shorthand — the versions above say what the reader is looking at.
