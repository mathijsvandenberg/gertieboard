# flash

Source: [`flash.vhd`](../../flash.vhd) · Instance `flash1` · Clock `c0` (5 MHz)

An SPI byte-transfer engine for the on-board serial FLASH — an **ISSI IS25LP016D**,
16 Mbit / **2 MByte**. This is the backing store for the [fixed disk](../fixed-disk.md)
and, optionally, for a copy of the BIOS.

## Ports

| Port | Dir | Width | Purpose |
|---|---|---|---|
| `CLK` | IN | 1 | 5 MHz (`c0`) |
| `ADDR` | IN | 16 | I/O address |
| `DATAIN` | IN | 8 | CPU write data |
| `RD` / `WR` | IN | 1 | I/O strobes, active low |
| `DATAOUT` | OUT | 8 | Read-back, `'Z'` when not addressed |
| `FL_SCK` | OUT | 1 | SPI clock → `FL_SCK` pin |
| `FL_CS` | OUT | 1 | Chip select, active low → `FL_CS` pin |
| `FL_DO` | OUT | 1 | MOSI → `FL_MOSI` pin |
| `FL_DI` | IN | 1 | MISO ← `FL_MISO` pin |

## Registers

| Port | Access | Function |
|---|---|---|
| `0x98` | W | Transmit byte — **writing starts an 8-bit exchange** |
| `0x98` | R | The byte received during the last exchange |
| `0x99` | R | Status: **bit 7 = BUSY**, other bits `0` |
| `0x9A` | W | Control: **bit 0 = `/CS`** (0 = assert, 1 = release) |

Usage is the ordinary SPI pattern — assert `/CS`, exchange bytes (send `0xFF` when
you only want to receive), release `/CS`. A JEDEC ID read:

```asm
        out  0x9A, 0      ; /CS low
        mov  al, 0x9F     ; RDJDID
        call xfer
        mov  al, 0xFF
        call xfer         ; -> manufacturer
        mov  al, 0xFF
        call xfer         ; -> memory type
        mov  al, 0xFF
        call xfer         ; -> capacity
        out  0x9A, 1      ; /CS high

xfer:   out  0x98, al
        mov  cx, 1000     ; also provides the settle gap -- see the warning below
.w:     in   al, 0x99
        test al, 0x80
        jz   .done
        loop .w
.done:  in   al, 0x98
        ret
```

On this board that returns **`9D 60 15`**: ISSI, IS25LP family, capacity code
`0x15` = 2²¹ = 2048 KB. The BIOS reads and decodes this at POST and prints it.

## Timing

SPI **mode 0**: `SCK` idles low, MOSI is presented while `SCK` is low, MISO is
sampled at the end of the `SCK`-high phase.

One `SCK` period takes two `CLK` cycles, so `SCK` = **2.5 MHz** and a byte takes
**3.2 µs**. That is far below the chip's 133 MHz rating, but still faster than the
CPU can feed it, and keeping the register interface in the CPU's own clock domain
avoids any clock crossing. If sector throughput ever matters, the answer is a
sector-buffer burst mode clocked from `c3`, not a faster version of this byte path.

## Two details that matter

> ⚠️ **Leave a gap between the write and the first status read.** The transmit is
> latched on the **falling edge** of the write strobe, and `BUSY` only rises after
> that. An `IN` that lands immediately after the `OUT` can see `BUSY = 0` and return
> the **previous** byte — shifting an entire transfer by one. The BIOS's loop happens
> to have two instructions in between; code that does `out` / `in` back-to-back
> corrupts data. Make the gap explicit.

> ⚠️ **Never poll `BUSY` without a bound.** A BIOS or bootloader that spins forever
> on a peripheral turns any wiring fault into a dead machine with no clue where.
> Every caller here uses a counted loop. Note that bounded loops **nest**: a bounded
> `wait_wip` calling a bounded `xfer` can still take minutes if the inner one always
> runs to its limit.

## History

This replaced a bit-banged interface where `0x98` drove `SCK`, `CS` and `MOSI` one
bit at a time — a single byte cost 16 writes plus 8 reads, so a 512-byte disk
sector would have needed roughly 12 000 bus cycles. Two bugs were fixed in the
same rewrite: the transmit trigger became a one-shot on the falling edge (a level
test re-fired on every clock the strobe was low), and read-back is now gated on `RD`
instead of driving the shared bus during write cycles too.

## Flash layout

| Range | Size | Contents |
|---|---|---|
| `0x000000`–`0x1EFFFF` | 1984 KB | Fixed disk — 31 cylinders as reported to DOS |
| `0x1F0000`–`0x1FFFFF` | 64 KB | Reserved for a BIOS image (boot fallback) |

The chip erases in **4 KB blocks** (`0x20`), programs in **256-byte pages** (`0x02`),
and needs a write-enable (`0x06`) before each. `0x05` reads the status register, whose
bit 0 is `WIP`. See [fixed disk](../fixed-disk.md) for how that is turned into a disk.

> These are **ordinary user I/O pins**, not the FPGA's dedicated active-serial
> configuration pins. This is a different chip from the one holding the bitstream, so
> writing it cannot damage the FPGA configuration.

## Related

- [Fixed disk](../fixed-disk.md) — the disk built on top of this
- [Boot flow](../boot.md) — the BIOS copy in the top 64 KB
- [Gotchas](../gotchas.md) — the timing race and unbounded-poll traps
