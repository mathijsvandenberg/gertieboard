# usb_audio

Source: [`usb_audio.vhd`](../../usb_audio.vhd) · Instance `usbaud1` at `0xA0`–`0xA5` ·
Clock `c0` · ~40 logic elements

The CPU-facing control registers for the **isochronous audio streamer**. The
streaming engine itself is inside [usb_host](usb_host.md), because it has to
inject a transaction into that sequencer's frame; this module only says *where*
to send audio, *how much*, *how loud*, and *whether to run*.

Together they let the [AdLib output](opl2_lite.md) come out of a **USB Audio
Class** device — a USB sound card, a USB headphone dongle, or a Bluetooth audio
transmitter that presents itself as one — instead of the one-bit buzzer.

## The CPU is not in the audio path

This is the point of the whole design, and it is what makes it work on a V20.

An isochronous endpoint has a 1 ms deadline and **no handshake**: there is no
ACK, nothing is resent, and a missed frame is simply gone. Software cannot
promise that on a machine where a DOS game owns the interrupts — and every miss
would be an audible click.

So nothing streams from the CPU. `opl2_lite` renders 48 kHz PCM in the 48 MHz
domain, straight into a double buffer in `usb_host`, and the sequencer ships one
packet per frame by itself. [`USBAUDIO`](../tools.md#usbaudio) sets four
registers and **exits** — it is not a TSR, and audio keeps playing inside
software that has taken over the machine.

## Registers

| Port | Access | Function |
|---|---|---|
| `0xA0` | W | **CTL** — `[0]` EN (stream while set) · `[1]` CLRERR (write 1 to clear the underrun flag and count) |
| | R | **STAT** — `[7:4]` = `0xA` signature · `[1]` UNDER sticky · `[0]` EN |
| `0xA1` | W | **ADDR** `[6:0]` USB device address of the audio device |
| `0xA2` | W | **ENDP** `[3:0]` its isochronous OUT endpoint number |
| `0xA3` | W | **NSMP** samples per frame — 48 |
| `0xA4` | W | **GAIN** `[2:0]` right shift applied to every sample, 0 = loudest |
| `0xA5` | R | **UNDERN** count of short frames, saturating at 255 |

The `0xA` in the top nibble of `STAT` is there so a tool can tell the difference
between *this module answering* and *an unbuilt window floating*. A bitstream
without `AUDIO => true` on `usb2` would otherwise accept every write below in
silence, which is indistinguishable from a device that will not play.

**Set ADDR, ENDP, NSMP and GAIN before setting EN.** They cross into the 48 MHz
domain unsynchronised, which is safe only because they are static by the time
anything reads them. `EN` is the one bit that moves underneath a running engine,
and `usb_host` gives that one two flops.

## Why a separate window and not four more usb_host registers

`usb_host`'s window is exactly eight registers and all eight are in use, by a
BIOS and four DOS tools that address them literally. Widening it to sixteen
would move the second instance off its 8-byte alignment — `0xA8` is not 16-byte
aligned — and stealing bits from the existing registers would change the meaning
of writes existing software already makes.

A separate window costs one decode and breaks nothing. `0xA0`–`0xA7` was free
and sits directly below USB1's `0xA8`–`0xAF`, which is the port the audio device
is on. The adjacency is the documentation.

## Underrun means a wiring fault, not a tuning problem

`UNDER` sets when the PCM writer did not fill a whole frame before the buffers
swapped. Both the 48 kHz sample clock and the 1 kHz frame clock are divided from
the **same** 48 MHz PLL output, so they cannot drift apart — 48 samples land in
every frame by construction.

So this flag is not a margin to be tuned. If it ever sets, something structural
is wrong: `CLK48` not reaching `opl2_lite`, or `PCM_STB` not arriving. That is
worth knowing in advance, because a rate mismatch is exactly what a person would
assume when audio crackles, and it would send them tuning a number that cannot
be the cause.

## Related

- [usb_host](usb_host.md#isochronous-audio) — the streamer, the double buffer, the ISO OUT
- [opl2_lite](opl2_lite.md) — the PCM tap and why it renders at 48 kHz
- [Tools](../tools.md#usbaudio) — `USBAUDIO`, and the alternate-setting trap
- [Memory map](../memory-map.md) — the I/O ports
