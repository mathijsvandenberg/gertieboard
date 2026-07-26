# com1_stub

Source: [`com1_stub.vhd`](../../com1_stub.vhd) · Instance `com1_stub1` · combinational (no clock)

There is no serial port for software to use — the UART pins are taken by the
[floppy link](fdc8272.md). This tiny module answers probes at the COM1 addresses in a
way that makes software conclude "no serial port here" and move on, instead of
hanging on an open bus.

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `RD` | IN | 1 | I/O read strobe, active low |
| `ADDR` | IN | 16 | I/O address |
| `DATAOUT` | INOUT | 8 | Answer, tri-state |

No clock and no write path: it only answers reads.

## Addresses

| Ports | Access | Answer |
|---|---|---|
| `0x3F8`–`0x3FF` except `0x3FD` | R | `0x00` |
| `0x3FD` | R | see below — the Line Status Register |

```vhdl
sel_lsr <= '1' WHEN (RD = '0' AND ADDR = x"03FD") ELSE '0';
sel_com <= '1' WHEN (RD = '0' AND ADDR >= x"03F8" AND ADDR <= x"03FF"
                              AND ADDR /= x"03FD") ELSE '0';
```

Writes are ignored entirely, and the bus is released (`"ZZZZZZZZ"`) for anything else.

## Why an open bus is not good enough

An undecoded read returns `0xFF`. For a 16450/8250 UART that is a peculiar answer:
software probing for a serial port can read a Line Status Register that claims
"transmitter holding register empty **and** data ready **and** every error bit set" at
once, and some code then waits forever for a condition that never resolves.

Answering `0x00` for the register block, with a deliberate value at the LSR, gives a
consistent "nothing here" picture. The same reasoning is why
[`cga_status`](cga_status.md) keeps its upper bits at zero — a byte that is never
`0xFF` is how software distinguishes a real device from an empty socket.

## Related

- [fdc8272](fdc8272.md) — what the serial pins are actually doing
- [Memory map](../memory-map.md#deliberately-absent) — other deliberately-absent ranges
