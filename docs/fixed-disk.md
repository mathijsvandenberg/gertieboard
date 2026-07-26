# Fixed disk

A 2 MB hard disk, backed by the on-board SPI FLASH (ISSI **IS25LP016D**), presented to
DOS through `INT 13h` for `DL >= 0x80`. FDISK and FORMAT work, and partitions survive
a reboot.

Implementation: `hd_int13` and friends in [`tools/xtbios_src.s`](../tools/xtbios_src.s),
on top of the [`flash`](modules/flash.md) SPI engine.

## Geometry

| | Value |
|---|---|
| Reported | **31** cylinders × 4 heads × 32 sectors = 3968 sectors = 1984 KB |
| Physical | **32** cylinders × 4 heads × 32 sectors = 4096 sectors = 2048 KB |
| Sector size | 512 bytes |

```asm
.equ HD_CYLS,   31              ; REPORTED: DOS never sees cylinder 31
.equ HD_PHYS_SECTORS, 32*4*32   ; the chip really holds 4096 sectors
```

That split is deliberate. `AH=08` advertises 31 cylinders so DOS keeps out of the last
one, which holds the BIOS copy the boot ROM falls back to — but the bounds check uses
the **physical** size, so a deliberate tool can still address cylinder 31 to write that
copy.

## Flash layout

| Range | Size | Contents |
|---|---|---|
| `0x000000`–`0x1EFFFF` | 1984 KB | Disk data — LBA 0 … 3967 |
| `0x1F0000`–`0x1FFFFF` | 64 KB | Reserved: BIOS image for the [boot fallback](boot.md) |

`flash address = LBA × 512`, and the reserved region is exactly cylinder 31:

```
C31 H0 S1  ->  LBA 3968  ->  flash 0x1F0000,  and 128 sectors = 64 KB
```

## The write problem

SPI NOR cannot be overwritten in place. Changing one 512-byte sector means:

1. **Erase** the surrounding 4 KB block (`0x20`) — takes 60–300 ms
2. **Program** it back in 256-byte pages (`0x02`), 16 of them
3. Each of those needs a **write enable** (`0x06`) first, and a `WIP` poll (`0x05`) after

Done naively, DOS writing 8 consecutive sectors in one block costs **8 erase cycles of
the same block** — both slow and 8× the flash wear.

## The solution: a 4 KB block buffer

One 4 KB block is held in on-chip M9K at `0xE0000`, outside conventional memory.

| Operation | Behaviour |
|---|---|
| **Write** | Load the block, copy 512 bytes in, mark dirty |
| **Read**, block cached **and dirty** | Serve from the buffer — the flash copy is stale |
| **Read**, otherwise | Straight from flash: no 4 KB pull-in just to hand back 512 bytes |
| **Commit** | Erase + reprogram |

So a multi-sector write inside **one** `INT 13h` call costs a single erase.

### Writes commit before returning

> ⚠️ **This is the important rule.** `INT 13h AH=03` is expected to have **committed**
> when it returns. Real hardware writes immediately, so deferring across calls is
> invisible to DOS right up until the power goes.
>
> FDISK demonstrated this perfectly: it wrote the partition table, never issued
> `AH=00`, and the still-dirty block was lost at reboot — **the partition simply
> vanished**. The buffer is therefore flushed before any write call returns.

What that gives up is batching *across* separate calls, so eight individual
single-sector writes now cost eight erases (~100 ms each). That is the right trade: a
disk that loses data on reboot is worthless however fast it is.

The buffer still earns its place — it is what makes read-modify-write **correct** (the
other seven sectors of the block must be preserved), and it keeps multi-sector calls
to one erase.

`AH=00` and `AH=0D` also commit, so DOS's disk reset remains a valid commit point.

## CHS to LBA

```
LBA = (cylinder × 4 + head) × 32 + (sector − 1)
```

`hd_chs2lba` uses BDA scratch bytes (`0xEA`, `0xEB`) rather than register gymnastics,
because `mul` clobbers `DX` and the head has to be read before that happens.

## Visibility to DOS

`hd_int13` refuses **every** function while BDA `0x40:75` is zero, returning
`AH=01, CF=1` (invalid drive).

> Answering `AH=08` with `CF=0` (success) *and* `DL=0` (no drives) is contradictory,
> and it stopped DOS booting: DOS took the success at face value and went on to act on
> a device that was not there. A machine with no hard disk **fails** the call, and DOS
> then simply skips the drive.

POST now advertises the disk (`0x75 = 1`). Test tools that flip that byte must **leave
it set** on exit — an earlier version of `HDTEST` cleared it, which hid the drive from
anything run afterwards and looked exactly like a detection failure in FDISK.

## Performance

| Operation | Cost |
|---|---|
| Read, cache hit | ~0 extra |
| Read, from flash | 512 bytes × ~6 µs ≈ 3 ms |
| Block load (4 KB) | ~20 ms |
| Write (one call) | one erase, ~100 ms + program time |

Roughly real-XT-hard-disk speed. FORMAT is noticeably slow and pauses on each erase;
that is the flash, not a fault.

### Where the buffer lives

In **on-chip M9K at `0xE0000`**, outside conventional memory, so it costs DOS nothing
and the BIOS reports the full **640 KB**.

It did not start there. The first version put it at `0x9E000`, in reserved conventional
RAM just above what was then advertised as 632 KB — the classic way for a BIOS to keep
private RAM, and the quickest way to get the write logic proven. That cost 8 KB of DOS
memory.

Moving it was a small change on both sides:

- [`m9k_mem.vhd`](../m9k_mem.vhd) backs a second window, `0xE0000`–`0xE0FFF`, packed on
  top of the low 32 KB in the same inferred RAM — 36 KB total, +4 M9K blocks, 50 logic
  elements for the whole module
- `HDBUF_SEG` in the BIOS changed from `0x9E00` to `0xE000`, and the reported size and
  banner string went back to 640

> **`0xE0000` is load-bearing.** `busdecode`'s `MEMADDR` is true for `ADDR < 0xA0000` or
> `ADDR >= 0xE0000`, so a window there is a proper memory cycle and the CPU waits on
> `RAM_READY`. Put the buffer anywhere in `0xA0000`–`0xDFFFF` and the `T >= 3` clause
> releases the CPU without consulting the RAM at all — it would appear to work, at 50 MHz,
> right up until it did not. Moving the buffer means changing both the VHDL window and
> `HDBUF_SEG` together.

**This does not make the disk much faster.** Buffer writes now land in on-chip RAM
instead of PSRAM, but a 4 KB block load is dominated by 4096 bit-banged SPI byte
transfers at roughly 6 µs each. The tenfold speedup that was once hoped for here needs
the erase/program/poll sequence itself moved into VHDL — a ~300-line state machine that
does not exist, and where every bug would mean a reflash instead of a rebuild. The gain
from this change is 8 KB of conventional memory, not speed.

## Verification

`HDTEST.COM` (see [tools](tools.md)) checks seven things, all passing on hardware:

| # | Test | Catches |
|---|---|---|
| 1 | Read LBA 0 | basic read path |
| 2 | Erased flash reads `0xFF` | **real data movement** — a dropped SPI byte, wrong address or stuck MISO |
| 3 | Multi-sector read from an untouched cylinder | multi-sector addressing |
| 4 | Same sector twice matches | a desynchronised SPI stream |
| 5 | Write 8 sectors in one block, read back | write + read-modify-write |
| 6 | Read a different block to force eviction, then re-read | **the flush actually reaches flash** |
| 7 | Dirty flag clear when `AH=03` returns | the commit-on-return contract |

Tests 6 and 7 are the ones worth keeping. Without 6, a broken flush looks perfect until
the block is evicted and the data silently reverts. Without 7, tests 5 and 6 pass even
when writes are never committed, because they force an eviction themselves — which is
exactly the bug FDISK hit.

Test 2 works because a blank chip reads `0xFF` everywhere, so it is a genuine data
check rather than a return-code check. Note that tests 5–7 write to cylinder 0 / head 3,
so test 3 deliberately reads **cylinder 30** — an earlier version read the very block
the write tests fill and went stale the moment writes were enabled.

## Writing the BIOS copy

`BIOSFLSH.COM` copies the **running** BIOS (`F000:0000`, 64 KB) into the reserved
region, through ordinary `INT 13h` writes to cylinder 31 — reusing the proven
erase/program path rather than carrying its own SPI sequence. It then reads all 64 KB
back and compares.

There is no filename to get wrong, and the flashed copy is by construction the BIOS you
just booted and tested.

> An earlier version drove the SPI engine directly and stalled on the first block. The
> lesson: when a proven path exists, reuse it rather than writing a second
> implementation of the same thing.

## Related

- [flash](modules/flash.md) — the SPI engine and flash command set
- [BIOS](bios.md) — the `INT 13h` function list and BDA fields
- [Boot flow](boot.md) — what the reserved region is for
- [Tools](tools.md) — `HDTEST`, `HDSTEP`, `BIOSFLSH`
