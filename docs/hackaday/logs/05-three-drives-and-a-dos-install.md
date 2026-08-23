# Log 5 — Three drives, and installing MS-DOS 4.01 from its original floppies

*Suggested title: "There is no floppy drive, so where does DOS come from?"*

---

The board has no floppy connector and never will. It also has to boot with nothing
plugged into it but power and a monitor. Those two requirements pulled the storage design
into three separate paths, and all three exist today.

**`A:` — a floppy served over serial.** The FPGA presents a normal 8272 controller to
DOS at the addresses DOS expects, with DMA channel 2 doing the transfers. When the
controller needs a sector it asks a host program over a 1 Mbaud serial link, which reads
it out of a `.img` file. From the machine's point of view it is a diskette drive. If no
host is listening, the drive reports NOT READY and the boot moves on — the machine does
not depend on it.

The host side is [GertieBoardLoader](https://github.com/mathijsvandenberg/gertieboardloader).
It watches the image file *and* the BIOS binary and reloads both automatically, so during
BIOS development a rebuild-and-reboot is the whole edit cycle with nothing to restart.
The protocol is four bytes and a payload if you would rather write your own.

**`B:` — a USB floppy drive, or the on-board SPI flash.** A TEAC FD-05PUB reads real
720K and 1.44 MB diskettes under DOS with no driver loaded. When no drive is found at
POST, `B:` is instead a 1.44 MB volume on the top board's 2 MB SPI flash — `FORMAT B:`
works and the contents survive a power cycle. Which one holds `B:` is decided **once**, at
POST, so it cannot change under a running program.

**`C:` — a USB hard disk.** Bulk-Only Transport and a SCSI stack, both in the BIOS, over
the fabric USB host controller. 504 MB addressable.

## Installing DOS the way you would have in 1989

`C:` was partitioned with `FDISK`, formatted with `FORMAT /S`, and then **MS-DOS 4.01 was
installed onto it from its original three install floppies** — the Dutch release that
shipped with the Philips P2120, served as `A:` over the serial link, one disk at a time,
swapping images the way you would have swapped diskettes. `CHKDSK` passes on the result.

IBM PC-DOS 3.30 runs too.

There is something specific about watching a 1989 installer copy files onto a USB flash
drive through a SCSI stack written in 8088 assembly, on a CPU that has no idea any of
that exists.

## Two bugs from this stretch, both instructive

**A long SPI read does not come back intact.** The boot ROM was streaming the whole
64 KB BIOS image in one command, and about 11,000 bytes came back wrong. Chunked at 512
bytes: zero errors. This was the last thing standing between the board and booting on its
own.

**The floppy handler scribbled on the keyboard's BDA bytes.** Phantom modifier keys —
but only after disk activity, and only on the DOS versions that happen to read those
bytes. A fault whose trigger and whose symptom are in completely unrelated subsystems is
the kind that eats a weekend.
