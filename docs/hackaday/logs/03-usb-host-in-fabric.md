# Log 3 — A USB host controller with no USB host controller

*Suggested title: "Two FPGA pins, four resistors, and a hard disk"*

---

The XT never had USB, so there was no chip to reimplement and no compatibility to honour.
That made it the one part of the machine where the answer could be whatever worked.

Both USB ports on the top board are wired **straight to FPGA pins** as raw `D+`/`D-`.
No PHY, no host controller chip, nothing in between. The serial interface engine — NRZI,
bit stuffing, CRC5 and CRC16, SOF generation, the EOP detector, the whole transaction
state machine — lives in the fabric, and the class drivers live in the BIOS in 8088
assembly.

What runs on it today:

- **A USB flash drive as `C:`** — Bulk-Only Transport with a SCSI stack in the BIOS.
  `FDISK`, `FORMAT` and `CHKDSK` all pass, 504 MB is addressable, reads peak at
  **221 KB/s**.
- **A USB floppy drive as `B:`** — a TEAC FD-05PUB reading real 720K and 1.44 MB
  diskettes under DOS with **no driver loaded**. That one is UFI over CBI, a completely
  different transport: command out as a control request, data over bulk, status as two
  bytes on an interrupt endpoint.
- **A HID mouse** driving `INT 33h`, and a **HID keyboard** typing into the BIOS key
  buffer alongside the PS/2 one.
- **A USB Audio Class speaker**, which is how AdLib sound gets out.

Each port gets its **own** engine instance — `0xE8–0xEF` and `0xA8–0xAF` — so the disk
port and the input port cannot interfere with each other by construction.

**Low speed came almost free.** The same engine with a 32-clock bit time and the J/K
polarity swapped once at the pads: NRZI, CRC and the EOP detector are untouched, because
they never see the swap. +141 logic elements, no second state machine.

## The lessons all had the same shape

Three separate bring-ups cost real days, and in hindsight they are the same bug three
times — **a protocol step whose only purpose is to let the other end continue, omitted
from the error path**:

- A **UNIT ATTENTION** aborts the command, and the command must then be *reissued*.
- The **CBI interrupt status must be collected even when the data phase failed.**
- A **stalled endpoint stays latched** until `CLEAR_FEATURE(ENDPOINT_HALT)` — without
  which one bad sector took the drive down until it was physically unplugged.

And one that is worth its own paragraph: **NAK means two different things**, and one
budget was covering both. In data transfer NAK is flow control — a stick programming a
sector will NAK for hundreds of milliseconds while working perfectly, and cutting that
budget abandons writes mid-command. In enumeration NAK is a fault: a freshly reset device
returns eight descriptor bytes in milliseconds. Splitting the two budgets took a failed
probe from **13.7 seconds to about 2.5** on every boot, with the data path untouched.

## The pulldowns are a range, not a magic number

A downstream port needs a pulldown on `D+` and `D-`. Everyone quotes 15K; USB 2.0
actually specifies **≈14.25 kΩ to 24.8 kΩ**, and that window opens *upward* on purpose —
a larger pulldown loads the device's 1.5K pull-up less, so the idle high level goes up
rather than down.

| Rpd | idle high at 3.3 V | SE0 at 10 µA pin leakage | in spec? |
|---|---|---|---|
| 10K | 2.87 V | 0.10 V | **no** — below the floor |
| 15K | 3.00 V | 0.15 V | yes, near the bottom |
| 18K | 3.05 V | 0.18 V | yes |
| 22K | 3.09 V | 0.22 V | yes |

Both columns have to hold: the left is margin over V<sub>IH</sub> with a device attached,
the right is how well the pulldown holds SE0 against pin leakage with **nothing**
attached, which is what sets the upper limit. Anything from 15K to 22K works, 18K and 20K
are E12 values, 5 % parts are fine — and **match the pair on a given port**, which matters
more than the absolute value.

One trap: fitting a resistor to a port that already has one puts them in parallel. 15K ∥
20K is 8.6 kΩ, below the floor, in the one direction the range does not allow. Measure
the pad to ground *before* adding.

## The known limit

A USB device that wedges below the protocol cannot be recovered in software on this
board. That is measured, not assumed — SE0 holds of 36, 108, 324 and 972 ms all came back
NAK. Only removing VBUS clears it, and VBUS here is hardwired to 5 V; only DM and DP
reach the FPGA. A load switch on a spare GPIO fixes it on the next board revision.
