# usb_host

Source: [`usb_host.vhd`](../../usb_host.vhd) · Instances `usb1` (port 0, `0xE8`) and
`usb2` (port 1, `0xA8`) · Clocks `c0` (8.33 MHz CPU port) and `pll48` (48 MHz USB) ·
~900 logic elements each

A **USB 1.1 host controller** — full speed and low speed — with the serial interface
engine in fabric.
Both USB ports on the top board are raw D+/D− straight to FPGA pins with the 15K
pulldowns a host is supposed to have and no host-controller chip in between, so there
was nothing else for it.

**One instance drives one port.** It used to drive both, muxed by a port-select bit in
CTRL, which meant the fixed disk on port 0 and anything on port 1 shared a single
engine — a poll of one could repoint the pins in the middle of a transaction on the
other. The top level now instantiates the entity twice, at two I/O windows chosen by
the `IO_BASE` generic, so the two ports cannot interfere by construction. Measured cost
of the second engine: **+826 logic elements** and **+1024 memory bits** (the second
pair of 64-byte packet buffers), with the binding `c3` setup slack unchanged at
0.249 ns.

Verified on hardware: enumerates a USB mass-storage device, reads its device
descriptor, assigns it an address and reads the descriptor again at the new address.

## What is in hardware and what is not

Hardware does only what software cannot — bit-level timing at 12 Mbps, or 1.5:

- NRZI encode/decode, bit stuffing and unstuffing
- the SYNC pattern and EOP
- CRC5 for tokens, CRC16 for data
- an oversampling receiver that resynchronises on every transition — 4× at full
  speed, 32× at low
- the response timeout
- the 1 ms SOF that stops devices suspending after 3 ms of silence

Everything above a single transaction is **software**: enumeration, descriptors,
addresses, endpoint toggles, and eventually the mass-storage transport. That is a
rebuild instead of a reflash every time something is learned, which on a bring-up like
this is the difference between an evening and a week. See [`tools/usbtest.asm`](../../tools/usbtest.asm).

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK` | IN | 1 | 8.33 MHz CPU I/O bus (`c0`) |
| `CLK48` | IN | 1 | 48 MHz USB domain |
| `LOCKED` | IN | 1 | 48 MHz PLL lock, reported in the LINE register |
| `RESET` | IN | 1 | active high |
| `DATAIN` | IN | 8 | CPU write data |
| `ADDR` | IN | 16 | I/O address |
| `RD` | IN | 1 | I/O read strobe, active low |
| `WR` | IN | 1 | I/O write strobe, active low |
| `DATAOUT` | INOUT | 8 | shared peripheral read bus |
| `IRQ` | OUT | 1 | one-clock pulse every 8th frame while `CTRL[3]` is set. Leave `OPEN` on an instance that does not need it |
| `USB_DP` / `USB_DM` | INOUT | 1 each | this instance's differential pair |

The pair is driven only while transmitting and stays high-Z otherwise, so the pulldowns
hold it at SE0.

## Generic

| Generic | Default | Purpose |
|---|---|---|
| `IO_BASE` | `0x00E8` | base of this instance's 8-register window |

`IO_BASE` **must be 8-byte aligned**: the decode compares `ADDR(15 DOWNTO 3)` and
indexes with `ADDR(2 DOWNTO 0)`, so a misaligned base would silently answer at the
wrong eight addresses rather than fail the build. The register table below is written
with port 0's addresses because that is what the BIOS and every tool use literally; for
port 1 substitute `0xA8`–`0xAF`.

## Registers

| Port | Access | Function |
|---|---|---|
| `0xE8` | W | **CMD** — `[2:0]` op, `[3]` DATA1, `[7]` GO |
| | R | **STATUS** — `[0]` BUSY `[1]` ACK `[2]` NAK `[3]` STALL `[4]` TIMEOUT `[5]` ERROR `[6]` RXDATA1 `[7]` RXVALID |
| `0xE9` | W | **DEVADDR** `[6:0]` |
| `0xEA` | W | **ENDP** `[3:0]` |
| | R | **RXPID** — the raw PID of the last packet received |
| `0xEB` | W | **TXLEN** bytes to send (0..64) |
| | R | **RXLEN** bytes received |
| `0xEC` | W | **DATA** → TX buffer, pointer auto-increments |
| | R | **DATA** ← RX buffer, pointer auto-increments |
| `0xED` | W | **PTR** set both buffer pointers |
| | R | current TX pointer |
| `0xEE` | W | **CTRL** — `[0]` reserved (was port select) `[1]` BUSRESET `[2]` SOFEN `[3]` IRQEN `[4]` LOWSPEED |
| | R | **LINE** — `[0]` D+ `[1]` D− `[2]` FS device `[3]` LS device `[4]` SOF running `[5]` PLL locked |
| `0xEF` | W | **DIAG** select which counter the next read returns |
| | R | **FRAME** low 8 bits of the frame counter (index `0x00`), or the selected counter |

Operations: `1` = SETUP (token + DATA0 + handshake), `2` = IN (token + receive + ACK),
`3` = OUT (token + DATAx + handshake), `4` = ISO OUT (token + DATA0, **no
handshake**), `5` = one SOF.

**RXPID is the register to reach for when something is wrong.** It says what actually
came back rather than how the status bits classified it.

Two diagnostic indices are identity rather than measurement. `0x0F` reads back `0xA5`,
the build signature, so software can refuse to blame USB when the bitstream is stale.
`0x0E` reads back the low byte of `IO_BASE` — with two engines answering at two
windows, a tool pointed at the wrong one reads plausible registers and draws confident
wrong conclusions, so it can assert which port it is holding.

## Speed

**Both: full speed (12 Mbps) and low speed (1.5 Mbps)**, selected by `CTRL[4]`. Software
reads `LINE[2]` or `LINE[3]` to see which kind of device is attached and sets the bit to
match **before** resetting the bus.

Low speed is the same engine with two differences and no second state machine — NRZI,
bit stuffing, SYNC, CRC5, CRC16 and every packet format are identical at 1.5 Mbps:

| | |
|---|---|
| **Bit time** | 48 MHz ÷ 1.5 Mbps = **32 clocks per bit** against full speed's 4. Both divide 48 MHz exactly, which is why that PLL frequency was chosen. Everything expressed in *bit times* scales with it — the response timeout and the receive guard included, or they would be 8× too short and report `TIMEOUT` for a device answering perfectly |
| **Polarity** | J and K are named by which line is high, and low speed swaps them. The swap happens **once, at the pads**, so NRZI, the EOP detector and the idle checks are bit-for-bit the code that was already debugged. `SE0` is both lines low and survives the swap untouched, so bus reset and disconnect need no special case |

The 1 ms marker differs too: full speed sends a SOF packet, low speed a bare **keep-alive
EOP**, because a low-speed device never sees SOF — a hub does not forward it, so a SOF at
1.5 Mbps would be a malformed packet rather than a frame marker. The frame counter
advances either way, so `FRAME` and the interrupt read the same at both speeds.

> `LINE` reports the **engine's** view of the pins, and low-speed mode swaps them. So a
> low-speed device reads as `LINE[3]` *before* `CTRL[4]` is set and as `LINE[2]` — idle J
> — *after*. Detect on bit 3, then use bit 2 downstream. `CTRL` also persists across
> programs, so anything that cares must clear it before trusting `LINE`.

**Not supported:** a low-speed device behind a full-speed hub. That needs `PRE` packets
and a hub driver; directly attached needs neither.

48 MHz gives 4 samples per bit at full speed, 32 at low. See
[clkgen / pll](clkgen-pll.md#pll48--48-mhz-for-usb) for why that number and why it is a
second PLL.

## Isochronous audio

`CMD` operation **4 = ISO OUT** sends an OUT token and a DATA0 and then stops:
no handshake, no retry, no status to wait for. That is the bargain isochronous
makes -- guaranteed bandwidth in exchange for guaranteed delivery -- and it is
why the op could not simply reuse `3`. Waiting for an ACK that never comes would
time out every frame and hold `BUSY` for the whole 18-bit-time window, a
thousand times a second.

With the **`AUDIO` generic** true, the instance also gains a streamer that needs
no CPU at all. On each frame, immediately behind the SOF, it sends one ISO OUT
to the device and endpoint that [usb_audio](usb_audio.md) names, carrying 48
stereo samples produced by [opl2_lite](opl2_lite.md)'s PCM tap. 192 bytes at
12 Mbps is 128 us of a 1000 us frame, so a control or bulk transaction still has
the rest of the frame. It goes *before* software gets a chance to start one,
because it is the only traffic on the port with a deadline.

Cost, measured: **+1,119 logic elements** across the whole design and **+4,096
memory bits**. `usb1` sets the generic false and pays none of it -- the disk
port cannot be an audio device.

A **double buffer, not a FIFO.** The writer fills one 256-byte bank while the
SIE transmits the other, and they swap on the frame boundary. The rates are
exact: the 48 kHz sample strobe and the 1 kHz frame tick are both divided from
`CLK48`, so every frame gets 48 samples and never 47 or 49. A FIFO would be
machinery for absorbing a drift that cannot occur, and would replace a
deterministic swap with a fill level to reason about.

> Only ONE device fits on the hybrid port. There is no hub support, so USB1
> carries a keyboard or a mouse or an audio device, not two of them. The disk on
> USB0 is unaffected.

## The frame interrupt

`CTRL[3]` pulses the `IRQ` output every 8th frame — **125 Hz** — for an 8259 input. It
needs `SOFEN`, since it counts frames. The top level wires it to **IRQ2** on the `usb2`
instance and leaves `usb1`'s `OPEN`: the disk is polled by the BIOS and has no use for it.

The point is what it is *not* derived from. A DOS mouse driver polling from `INT 08h`
changes rate underneath itself the moment a game reprograms PIT channel 0 — which is most
of the software anyone would want a mouse for. This clock cannot be touched from software.

125 Hz is chosen rather than maximal: the endpoint offers 2 ms, but an 8088 servicing 500
interrupts a second would spend a serious fraction of itself doing it, and mice of this era
reported at 40–100 Hz.

The crossing is a **toggle** in the 48 MHz domain, edge-detected in the CPU domain — never
a pulse. A pulse a few 48 MHz cycles wide is invisible to a 10 MHz sampler, which is the
lesson the `GO` handshake in this module taught three separate times.

## Bus reset is software-timed

`CTRL[1]` drives SE0 for as long as it is set. A reset has to be held at least 10 ms,
which is an eternity in fabric and trivial in a DOS program — so the hardware just
holds the line and software owns the clock.

## Things that are easy to get wrong here

Four bugs cost four hardware iterations on this module, and every one of them is the
kind that produces a plausible-looking wrong answer rather than an obvious failure.
They are written up in [gotchas](../gotchas.md); in short:

> **Register strobes must be edge-detected.** `busdecode`'s `IO_WR` is a combinational
> passthrough that stays low for the whole bus cycle — several `CLK` edges. A level-
> triggered auto-incrementing data port stores each byte several times.

> **The last bit of a packet needs its own bit time.** The `T_TAIL` state exists because
> going straight from the final bit to EOP gave it one clock instead of four, so the
> receiving device never assembled the last byte.

> **`rx_prev` seeds to `'0'`, not `'1'`.** It holds the previous value of `k`, and `k` is
> D−. Idle J has D− *low*.

> **Nothing is cleared on the way out of a packet.** `rx_done` reaches the sequencer a
> clock after `R_EOP`, so clearing the byte count in `R_IDLE` wiped it before it could
> be read.

## Clock crossing

`GO` crosses as a **toggle** through a three-stage synchroniser. Command registers are
sampled only while the engine is idle. Packet data moves through dual-port buffers that
are never touched from both sides at once — the BUSY bit is what enforces that.

The 48 MHz domain is declared asynchronous in [`gertieboard.sdc`](../../gertieboard.sdc).
It must be: it is 24/25 of the 50 MHz input and so not integer-related to anything else,
and leaving it out of the clock groups put −2.483 ns of setup slack on `c0`.

## Electrical caveat

There are **no series resistors** on D+/D−, so the lines are driven straight from 3.3 V
LVTTL pins with no source termination. USB wants ~22–33 Ω. It works on the bench, but
that is the first thing to suspect if packets get through intermittently or CRC errors
appear on a longer cable. Nothing in the FPGA can compensate for it.

## Related

- [Tools](../tools.md#usbtest--usb-host-controller) — `USBTEST` and what each test proves
- [clkgen / pll](clkgen-pll.md) — the 48 MHz domain
- [Memory map](../memory-map.md) — the I/O ports
- [Status and roadmap](../status.md) — what USB is for
- [Gotchas](../gotchas.md) — the four bugs, in full
