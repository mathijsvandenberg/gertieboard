# Storage

Three drives, three completely different backing stores, one `INT 13h`.

| DOS | `DL` | Backed by | Size | Notes |
|---|---|---|---|---|
| `A:` | `0x00` | Serial link to a host program | whatever the image is | Reports NOT READY when nothing is serving it |
| `B:` | `0x01` | On-board SPI flash | 1440 KB | A 1.44 MB floppy as far as DOS is concerned |
| `C:` | `0x80` | USB mass-storage device | 504 MB addressable | Full-speed host controller in fabric |

`INT 13h` dispatches on `DL` alone: bit 7 set goes to the USB stack, `0x01` to the
flash, anything else to the serial floppy. Nothing above that layer knows the
difference, which is the whole point — `FDISK`, `FORMAT` and `CHKDSK` are unmodified
DOS utilities talking to an interface they have always talked to.

## Boot order

`A:` → `C:` → `B:`, held in a table so the order is data rather than control flow:

```asm
boot_order: .byte 0x00, 0x80, 0x01, 0xFF   # A:, C:, B:, end
```

`INT 19h` walks it. For each entry: reset the drive, read sector 1, require the
`0xAA55` signature, and jump to `0000:7C00` if it is there. Anything missing,
unreadable or unsigned simply moves to the next entry. Two entries can be skipped
before they are even tried:

- **`A:`** is skipped if POST found nothing serving it — otherwise every boot with the
  loader muted pays the FDC timeout a second time
- **`C:`** is skipped unless POST advertised a fixed disk in BDA `40:75`

Running out of entries prints what the original Philips ROM printed:

```
Boot Error.
Press Ctrl-Alt-Del to Reboot ...
```

Those are the real machine's words, at `0x25B1` and `0x258D` of the dump. It has no
"Insert disk and press any key" message — that is IBM AT wording, and the strings
`insert`, `strike`, `any key` and `when ready` appear nowhere in the ROM.

Only a floppy's boot sector is used to update the BIOS's idea of the geometry: a fixed
disk's first sector is a partition table, not a BPB, so reading `spt` and `heads` out of
it would be reading the partition entries.

## What POST reports

```
Diskette Drive A:  : Ready  720 KB
Diskette Drive B:  : Ready  1440 KB  (9D 60 15  2048 KB)
Internal Hard Disk : Ready  504 MB

Booting...
```

All three labels are 21 columns so the colons line up. `Internal Hard Disk : ` is the
original ROM's own string, at `0x1F39` of the dump — the USB disk inherits it because it
is the machine's hard disk now.

`B:` shows two sizes: **1440 KB** is the drive, and the bracket holds the flash chip's
JEDEC ID and its real capacity. A wrong or absent part reads as a different ID, or as
`FF FF FF`.

### Drive A: is a link, not a drive

"Ready" has to mean *the host is answering and serving an image*, which cannot be
inferred from a status register — the FPGA's FDC core will happily accept a command
with no host behind it. So POST reads sector 1 and sees whether the data ever arrives,
and takes the media size from the BPB in the sector it just read. A timeout here is a
normal outcome, not an error: it is precisely what NOT READY means, and it costs a
bounded ~2.5 s once.

The verdict lands in BDA `40:B7`, and **only `INT 19h` reads it.** `INT 13h` never
consults it, because a floppy drive is removable media: not ready at boot must never
become permanently unavailable. Start serving an image after POST and `DIR A:` works —
the first operation notices the previous timeout, resets the controller, and proceeds.

## Drive B: — the SPI flash

Reported as **80 cylinders × 2 heads × 18 sectors = 1440 KB**, which is the largest
format every DOS from 3.3 onward knows. The chip holds 2 MB, so the reported geometry
deliberately stops short of the physical end: the **top 64 KB is reserved** for the BIOS
image the boot ROM falls back to, and DOS cannot address it because DOS is told the
drive ends first.

Bounds checks are against the **physical** 4096 sectors rather than the reported
geometry, which is what lets [`BIOSFLSH`](tools.md#biosflsh--write-the-bios-to-flash) address the reserved region
deliberately while DOS cannot reach it by accident.

Mechanism — the 4 KB read-modify-write block buffer, the erase/program sequence, and
where the buffer lives — is in **[fixed disk](fixed-disk.md)**.

## Drive C: — USB mass storage

A full-speed host controller in fabric ([`usb_host`](modules/usb_host.md)) with the
transport and command layers in the BIOS.

### Enumeration

Staged, with the stage recorded in BDA `40:C0` so a failure says *where* it stopped
rather than just that it did:

| Stage | Meaning |
|---|---|
| `01` | No 48 MHz PLL lock — nothing in that clock domain can work |
| `02` | No full-speed device on the port |
| `03` | Device descriptor failed |
| `04` | `SET_ADDRESS` failed |
| `05` | Configuration descriptor failed |
| `06` | No mass-storage interface with bulk endpoints |
| `07` | `SET_CONFIGURATION` failed |
| `08` | Unit never became ready (`TEST UNIT READY` retried 40 times) |
| `09` | `READ CAPACITY(10)` failed |
| `0A` | Capacity unusable |
| `F0` | **Not a USB fault**: the FPGA image is older than this BIOS |
| `FF` | Success |

The order matters. The PLL lock is tested **before** the build signature, because the
diagnostic registers live in the 48 MHz domain — with no clock they return junk, and
junk compared against a signature reads as "wrong bitstream", pointing at entirely the
wrong thing.

Attach is debounced for **100 ms** before the first bus reset, per USB 2.0 §7.1.7.3. The
D+ pull-up appears as soon as the device has power, well before its controller can
answer, so resetting the moment full speed is detected hits a half-awake device — which
presents as "replug the stick and it fails at some random stage".

### Bulk-Only Transport

31-byte Command Block Wrapper out, data phase in 64-byte packets, 13-byte Command
Status Wrapper in. Three things about this implementation are worth knowing, because
each one was a bug first:

**NAK is flow control, not failure.** A flash stick programming a sector NAKs the next
packet for hundreds of milliseconds. The budget is 16 rounds of 4096 retries — seconds,
not milliseconds. Abandoning a merely-busy device mid-write makes it pad the sector from
its own stale internal buffer and report success.

**The data toggle advances only on the device's ACK.** Advancing it before the
transaction means an abandoned transfer leaves host and device disagreeing, and a bulk
endpoint receiving the wrong toggle **ACKs the packet and silently discards it** — data
loss with success status at every layer.

**A CSW is believed only when it has earned it.** `bCSWStatus = 0` answers "did I
succeed at what I received", never "did you deliver everything". So the command fails
if any of these hold, whatever the status byte says:

- the data phase recorded a failure
- `dCSWTag` does not echo the CBW's tag — an unchecked stale CSW satisfies the *next*
  command, so a retry can "succeed" without moving a byte
- `dCSWDataResidue` is non-zero on an OUT transfer

### Geometry

`READ CAPACITY(10)` gives the last LBA; the BIOS clamps it to what `INT 13h` can
express. Ten bits of cylinder, 16 heads and 63 sectors is **1024 × 16 × 63 = 1,032,192
sectors = 504 MB**, and a larger stick simply has its tail unreachable.

The clamp happens **before** the divide, not after: a 32 GB stick is 67 million sectors,
and 67e6 / 1008 does not fit in 16 bits, so `DIV` would raise a divide-overflow
interrupt rather than return a wrong answer.

One transfer is capped at **127 sectors**, because one CBW carries at most 127 × 512
bytes. A 128 KB read from DOS therefore becomes two commands, not one.

### Installing an operating system onto it

**MS-DOS 4.01** — the Dutch release that shipped with the Philips P2120 — is installed
on `C:`, put there by its own installer running from the original three 720 KB floppies
served on `A:`:

| Disk | |
|---|---|
| `dos401nl1.img` | Install |
| `dos401nl2.img` | Operating system |
| `dos401nlshell.img` | DOS Shell — the disk whose label reads *Microsoft(R) MS-DOS(R) versie 4.01* |

The images are **not in the repository** — `*.img` is gitignored, and they are not ours
to distribute.

This is worth more as a test than the [soak](tools.md#usbsoak--sustained-write--read--verify)
is. A soak proves the transport under a pattern chosen to be hostile; an installer
proves it under a workload nobody designed for it — partitioning, formatting, thousands
of small file writes, directory updates interleaved with data, and a reboot in the
middle that has to find everything exactly where it was left. Period software from 1988
has no idea it is talking to a USB stick over a host controller in an FPGA, which is
rather the point.

## The 80186 fast path

A USB packet is 64 bytes, and moving one used to cost roughly **900 µs** of CPU against
**45 µs** on the wire. The bus was idle about 95 % of the time, which is why every
transfer size converged on the same ~65 KB/s: the size did not matter, the copy did.

The copy is now a single `REP INSB`, which reads the port `CX` times straight into
`ES:DI`. It works because `U_DATA` auto-increments the controller's buffer pointer on
every read, so repeated reads of one port walk the packet — exactly what `INS` expects.
Worth **1.66×**, and the [numbers are in status](status.md#usb-throughput).

### Why it is conditional

`INS` is an 80186 instruction. The socket takes a NEC V20, which implements the 80186
additions, **or a real Intel 8088-1, which does not** — opcode `6C` is undefined there
and executing it is not survivable. So the BIOS cannot simply use it.

POST therefore probes the CPU and picks the path, reporting what it found:

```
Processor          : 80186 instructions present - fast disk path
Processor          : 8086/8088 class - compatible disk path
```

The probe asks one question: **does the CPU mask a shift count to five bits?** An 8086
or 8088 performs all 33 shifts of `shl al,cl` with `CL=33` and leaves zero; an 80186 and
the V20 mask the count to 1 and leave `0xFE`. It needs no undefined opcode — shifting by
`CL` is the only form an 8086 has — and it **fails in the safe direction**: a CPU that
does not mask is treated as an 8088 and never meets a 186 instruction. It can wrongly
refuse the fast path, never wrongly enable it.

> This identifies a **capability class, not a part.** A CPU carries no identifying
> register; everything you can learn comes from catching it behaving differently. A V20
> and a genuine 80186 answer identically, and the *speed grade* — 8088 against 8088-2
> against 8088-1 — is not detectable at all, being a marking on the package rather than
> anything electrical. See [status](status.md#ideas-unscheduled) for what raising the
> clock would actually involve.

The flag lives in the BIOS image (the F-segment is PSRAM, so it is writable) and its
offset is published at BDA `40:BC`. POST rewrites it every boot, so a fast path can
never be inherited across a CPU swap.
[`186BOOST`](tools.md#186boost--turn-the-80186-fast-path-off) can turn it off, which is
how the two paths get benchmarked against each other on one boot.

Writes still use the byte loop.

## Diagnosis

Every failure in this subsystem looks identical from DOS — "disk error" — and has been
a different bug each time. The tools that tell them apart are in
**[tools](tools.md)**: [`USBSOAK`](tools.md#usbsoak--sustained-write--read--verify) for sustained write/read/verify
with per-command forensics, [`USBSTAT`](tools.md#usbstat--controller-event-counters) for the controller's event
counters, [`SPIDUMP`](tools.md#spidump--read-the-flash-the-way-the-boot-rom-does) for reading the flash the way the boot ROM does,
and [`USBHD`](tools.md#usbhd--usbwipe--enumeration-state-and-clearing-a-stick) / [`USBWIPE`](tools.md#usbhd--usbwipe--enumeration-state-and-clearing-a-stick) for enumeration state and
clearing a GPT stick.

## Related

- [Fixed disk](fixed-disk.md) — the SPI flash mechanism in detail
- [Boot flow](boot.md) — where the boot order sits in the sequence
- [BIOS](bios.md) — `INT 13h` surface and the BIOS data area
- [usb_host](modules/usb_host.md) — the hardware side
- [Tools](tools.md) — the diagnostics
- [Gotchas](gotchas.md) — including why an SPI read must not exceed 512 bytes
