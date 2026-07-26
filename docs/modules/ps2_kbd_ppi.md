# ps2_kbd_ppi

Source: [`ps2_kbd_ppi.vhd`](../../ps2_kbd_ppi.vhd) · Instance `inst3` · Clock `c3` (50 MHz)

Reads a standard PS/2 keyboard, translates Scan Code Set 2 into the Set 1 the XT
BIOS expects, and presents the result exactly the way a 5160 keyboard interface did.
It also implements Ctrl+Alt+Del **in hardware**.

## Generic map

```vhdl
inst3 : ps2_kbd_ppi GENERIC MAP (CLK_FREQ_HZ => 50000000)
```

> ⚠️ Must be overridden. The entity default is 5 MHz; on the 50 MHz `c3` clock that
> makes the glitch filter, the frame watchdog and the keyboard-hold timeout all 10×
> too short. It fails subtly rather than obviously.

Derived constants:

```vhdl
FILT     = CLK_FREQ_HZ / 625000    -- input glitch filter
WD_MAX   = CLK_FREQ_HZ / 4000      -- ~250 us frame watchdog
HOLD_MAX = CLK_FREQ_HZ / 500       -- ~2 ms KB_HOLD timeout (AT fallback)
CAD_TICKS = CLK_FREQ_HZ / 1000     -- ~1 ms Ctrl+Alt+Del reset pulse
```

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `clk` | IN | 1 | 50 MHz (`c3`) |
| `reset` | IN | 1 | Synchronous, active high |
| `ps2_clk` | IN | 1 | ← `PS2CLK` pin |
| `ps2_dat` | IN | 1 | ← `PS2DAT` pin |
| `pa_data` | OUT | 8 | → `ppi8255.KBD_DATA` (8255 port A, I/O `0x60`) |
| `irq1` | OUT | 1 | → `int8259.IRQ1` |
| `kbd_clr` | IN | 1 | ← `ppi8255.KBD_CLEAR` (port B bit 7, I/O `0x61.7`) |
| `cad_rst` | OUT | 1 | → top-level reset — hardware Ctrl+Alt+Del |
| `dbg_raw` | OUT | 8 | Last raw Set 2 byte received — `OPEN` in the top level |
| `dbg_s1` | OUT | 8 | Last Set 1 byte queued — `OPEN` |

This module occupies no I/O ports of its own; software sees it through
[`ppi8255`](ppi8255.md) and [`int8259`](int8259.md).

## PS/2 frame

Device-to-host, 11 bits, sampled on the **falling** edge of `ps2_clk`:

```
start(0)  d0 d1 d2 d3 d4 d5 d6 d7  parity(odd)  stop(1)      LSB first
```

**Receive only** — the FPGA never drives clock or data, so there is no host-to-device
command path. No "set Scan Code Set 1" command is needed: the keyboard powers up in
Set 2 and this module translates.

## Set 2 → Set 1 translation

| Input | Output |
|---|---|
| make: `code` | `set1` |
| break: `F0 code` | `set1 OR 0x80` |
| extended: `E0 code` | `E0 set1` |
| extended break: `E0 F0 code` | `E0 set1|0x80` |

The keyboard's power-on `0xAA` (BAT ok) and stray `FA`/`EE`/`FE`/`FF`/`00` are ignored.
Translated bytes go into a small FIFO.

## Handshake with the BIOS

The XT acknowledges each scancode by pulsing port `0x61` bit 7, and the state machine
follows that:

```
KB_IDLE -> present a byte on pa_data, raise irq1        -> KB_HOLD
KB_HOLD -> wait for the PB7 RISING edge, drop irq1      -> KB_CLR
KB_CLR  -> wait for the PB7 FALLING edge                -> KB_IDLE
```

### The AT-style fallback

> The PB7 pulse is how a real PC/XT acknowledges a scancode, and the BIOS's `INT 09h`
> does it — which is why typing at the DOS prompt works. But a game that installs its
> **own** `INT 09h` usually just reads port `0x60` and sends EOI, because an AT's 8042
> needs no PB7. Waiting for a pulse that never comes parked the machine in `KB_HOLD`
> forever: `irq1` stayed high, no new edge ever reached the edge-triggered 8259, and
> **the keyboard went dead after exactly one key**.

So `KB_HOLD` also times out after ~2 ms. The first timeout latches `at_mode`, and from
then on the PB7 gating is bypassed entirely, so AT-style handlers keep receiving
scancodes. XT-style software still pulses PB7 and takes the original fast path,
never reaching the timeout.

2 ms is orders of magnitude longer than any keyboard ISR, so a byte is never replaced
before it has been read, yet it still allows ~500 scancodes per second.

## Hardware Ctrl+Alt+Del

The BIOS implements Ctrl+Alt+Del in `INT 09h`, but any program that hooks that vector
silently takes it away — leaving no escape from a wedged game. So this module also
watches the translated stream:

```
Set 1 codes: 0x1D = Ctrl, 0x38 = Alt, 0x53 = Del
(the E0-prefixed right-hand Ctrl/Alt and the dedicated Del map to the same values,
 so both sides of the keyboard work)
```

On a Del **make** with both held, `cad_rst` asserts for ~1 ms. Because that drives a
real reset, the effect is a genuine cold boot: the boot ROM overlay re-arms and the
BIOS is fetched again, video returns to text mode, and `ctrl_reg` reloads its safe
default.

> `cad_cnt` is deliberately **not** cleared by `reset` — it is what *causes* that
> reset, so clearing it there would cut its own pulse short.

## Electrical note

PS/2 is 5 V open-collector, idle high via pull-ups. **A Cyclone IV input is not 5 V
tolerant** — level-shift both lines (a BSS138, or for receive-only a ~1 kΩ series
resistor plus a 3V3 pull-up so the line swings 0–3.3 V). Many FPGA boards already
condition their PS/2 port. Power the keyboard from +5 V (mini-DIN pin 4), GND pin 3,
DATA pin 1, CLK pin 5.

## Related

- [ppi8255](ppi8255.md) — port A and the PB7 acknowledge
- [int8259](int8259.md) — IRQ1
- [BIOS](../bios.md) — `INT 09h` and `INT 16h`, including the DOS 5/6 enhanced calls
