# usb_host

Source: [`usb_host.vhd`](../../usb_host.vhd) · Instance `usb1` · Clocks `c0` (5 MHz CPU
port) and `pll48` (48 MHz USB) · 1962 logic elements

A **USB 1.1 full-speed host controller** with the serial interface engine in fabric.
Both USB ports on the top board are raw D+/D− straight to FPGA pins with the 15K
pulldowns a host is supposed to have and no host-controller chip in between, so there
was nothing else for it.

Verified on hardware: enumerates a USB mass-storage device, reads its device
descriptor, assigns it an address and reads the descriptor again at the new address.

## What is in hardware and what is not

Hardware does only what software cannot — bit-level timing at 12 Mbps:

- NRZI encode/decode, bit stuffing and unstuffing
- the SYNC pattern and EOP
- CRC5 for tokens, CRC16 for data
- a 4× oversampling receiver that resynchronises on every transition
- the response timeout
- the 1 ms SOF that stops devices suspending after 3 ms of silence

Everything above a single transaction is **software**: enumeration, descriptors,
addresses, endpoint toggles, and eventually the mass-storage transport. That is a
rebuild instead of a reflash every time something is learned, which on a bring-up like
this is the difference between an evening and a week. See [`tools/usbtest.asm`](../../tools/usbtest.asm).

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK` | IN | 1 | 5 MHz CPU I/O bus (`c0`) |
| `CLK48` | IN | 1 | 48 MHz USB domain |
| `LOCKED` | IN | 1 | 48 MHz PLL lock, reported in the LINE register |
| `RESET` | IN | 1 | active high |
| `DATAIN` | IN | 8 | CPU write data |
| `ADDR` | IN | 16 | I/O address |
| `RD` | IN | 1 | I/O read strobe, active low |
| `WR` | IN | 1 | I/O write strobe, active low |
| `DATAOUT` | INOUT | 8 | shared peripheral read bus |
| `USB0_DP` / `USB0_DM` | INOUT | 1 each | port 0 differential pair |
| `USB1_DP` / `USB1_DM` | INOUT | 1 each | port 1 differential pair |

Only the selected port is ever driven; the other stays high-Z so its pulldowns hold it
at SE0.

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
| `0xEE` | W | **CTRL** — `[0]` port select `[1]` BUSRESET `[2]` SOFEN |
| | R | **LINE** — `[0]` D+ `[1]` D− `[2]` FS device `[3]` LS device `[4]` SOF running `[5]` PLL locked |
| `0xEF` | R | **FRAME** low 8 bits of the frame counter |

Operations: `1` = SETUP (token + DATA0 + handshake), `2` = IN (token + receive + ACK),
`3` = OUT (token + DATAx + handshake), `5` = one SOF.

**RXPID is the register to reach for when something is wrong.** It says what actually
came back rather than how the status bits classified it.

## Speed

**Full speed only, 12 Mbps.** Mass storage is never low speed, and booting from a stick
is the point of the exercise. A low-speed device is reported on `LINE[3]` and otherwise
ignored.

48 MHz gives 4 samples per bit. See [clkgen / pll](clkgen-pll.md#pll48--48-mhz-for-usb)
for why that number and why it is a second PLL.

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
