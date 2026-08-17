#!/usr/bin/env python3
"""
coldboot.py -- power-cycle the board N times and score every boot.

WHY THIS EXISTS
    Cold-boot faults on this board are INTERMITTENT, and intermittent means
    statistics. Five boots cannot tell 0 % from 15 %: at a 15 % failure rate a
    clean run of five happens 44 % of the time. That is not a small caveat --
    a whole investigation was built on a "5 of 5" baseline that never supported
    the weight put on it, and several bitstreams were built and flashed to chase
    a difference that was inside the noise.

    Fifteen boots gets that to 8.7 %. Fifty settles it. Nobody is going to flip
    a switch fifty times and keep an honest tally, so this does it.

WHAT COUNTS AS A BOOT
    The board asks the host for sectors (0x33 0x01 C H R), so the serial link is
    also the progress report. This serves them -- it REPLACES GertieBoardLoader
    for the duration of a run, it cannot share the port with it -- and grades
    each attempt by how far the requests got:

      PASS       BIOS fetched, then the boot sector, then more reads
      NO_BIOS    nothing asked for at all. The loader died before the FDC, which
                 is where the memory probe lives (7-seg E1/E3/E4)
      NO_BOOT    BIOS fetched, then nothing. It got the image and did not run it
      BAD_CHS    a request outside the geometry -- the strongest corruption
                 signal there is, because the machine asked for a sector that
                 cannot exist

    The classification matters as much as the count: NO_BIOS and BAD_CHS fail at
    opposite ends of the boot and do not have the same cause.

POWER CONTROL
    Pluggable, because the right answer depends on what is on the bench:

      --rts-power          BEST OPTION HERE. The FTDI cable's RTS already runs
                           to the board and the FPGA design does not use it --
                           it has a pin assignment in the .qsf and no port in
                           the top-level entity. RTS is an FTDI OUTPUT, so with
                           a logic-level MOSFET (or a relay module) between it
                           and the board's 5 V, this script switches the board
                           itself. No hub, and NO FPGA CHANGES: RTS is driven by
                           the host and the transistor is external.
                           --rts-invert if your switch is active-low.
      --uhubctl LOC:PORT   a hub with real per-port power switching. Many hubs
                           with physical switches do NOT have this; uhubctl
                           itself will say so.
      --off CMD --on CMD   any shell commands -- a USB relay, a smart plug
      --manual             prompts, and still does the serving, the grading and
                           the tally. Worth it on its own: the judgement call
                           and the bookkeeping are where a hand-run experiment
                           actually goes wrong.

    NOT a reset line. Driving RTS into an FPGA reset input would be easy and
    would NOT reproduce this fault: the reset button does not fix a failed
    boot, and 2-3 s of power-off is not enough where 30 s is. Whatever this is,
    it needs the rails to actually fall. Switch the power, not the reset.

USAGE
    python tools/coldboot.py --port COM5 --image tools/dos33-xtpro.img \\
        --bios tools/gertieboard_bios.64k --trials 15 --manual
"""

import argparse, sys, time, math

try:
    import serial
except ImportError:
    sys.exit("pyserial required:  pip install pyserial")

PREAMBLE = 0x33
HCMD_RD  = 0x01
HCMD_WR  = 0x02
WRITE_OK = 0x06
SECTOR   = 512
BIOS_CYL = 0xFF


def detect_geometry(size):
    table = {368640: (40, 2, 9), 737280: (80, 2, 9),
             1228800: (80, 2, 15), 1474560: (80, 2, 18)}
    if size in table:
        return table[size]
    return (80, 2, 9)


def read_exact(ser, n, deadline):
    buf = b""
    while len(buf) < n:
        if time.time() > deadline:
            return None
        chunk = ser.read(n - len(buf))
        if chunk:
            buf += chunk
    return buf


def wilson(k, n, z=1.96):
    """95 % confidence interval for a failure rate. Wilson rather than the
    normal approximation because n is small and k is often 0 or 1, which is
    exactly where the naive interval is worst (it gives 0 to 0)."""
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    d = 1 + z*z/n
    c = (p + z*z/(2*n)) / d
    h = z * math.sqrt(p*(1-p)/n + z*z/(4*n*n)) / d
    return (max(0.0, c-h), min(1.0, c+h))


def one_trial(ser, img, bios, geom, timeout, verbose):
    """Serve one boot attempt. Returns (verdict, detail)."""
    cyl, heads, spt = geom
    ser.reset_input_buffer()
    deadline = time.time() + timeout
    got_bios = 0
    got_boot = False
    reads = 0

    while time.time() < deadline:
        b = ser.read(1)
        if not b:
            continue
        if b[0] != PREAMBLE:
            continue
        hdr = read_exact(ser, 4, deadline)
        if hdr is None:
            break
        cmd, c, h, r = hdr

        if cmd == HCMD_RD and c == BIOS_CYL:
            off = (r - 1) * SECTOR
            data = bios[off:off + SECTOR] if bios else b""
            ser.write(data + bytes(SECTOR - len(data)))
            got_bios += 1
            continue

        in_range = (0 <= c < cyl and 0 <= h < heads and 1 <= r <= spt)
        if not in_range:
            # A request for a sector that cannot exist. The machine computed an
            # address out of corrupt state -- report it and stop; later requests
            # tell us nothing once it is already lost.
            if cmd == HCMD_RD:
                ser.write(bytes(SECTOR))
            else:
                read_exact(ser, SECTOR, deadline)
                ser.write(bytes([WRITE_OK]))
            return ("BAD_CHS", f"C{c}/H{h}/R{r}")

        off = ((c * heads + h) * spt + (r - 1)) * SECTOR
        if cmd == HCMD_RD:
            img.seek(off)
            data = img.read(SECTOR)
            ser.write(data + bytes(SECTOR - len(data)))
            reads += 1
            if (c, h, r) == (0, 0, 1):
                got_boot = True
            # Past the boot sector and still reading = DOS is loading.
            if got_boot and reads >= 8:
                return ("PASS", f"{got_bios} BIOS + {reads} sectors")
        else:
            data = read_exact(ser, SECTOR, deadline)
            if data is None:
                break
            ser.write(bytes([WRITE_OK]))

    if got_bios == 0:
        return ("NO_BIOS", "no request at all")
    if not got_boot:
        return ("NO_BOOT", f"{got_bios} BIOS sectors, never asked for 0/0/1")
    return ("NO_BOOT", f"{got_bios} BIOS + {reads} sectors, stalled")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=1000000)
    ap.add_argument("--image", required=True)
    ap.add_argument("--bios")
    ap.add_argument("--trials", type=int, default=15)
    ap.add_argument("--timeout", type=float, default=25.0,
                    help="seconds to wait for a boot before calling it failed")
    ap.add_argument("--settle", type=float, default=30.0,
                    help="seconds powered OFF. 2-3 s is not a cold start on "
                         "this board -- the rails do not fully discharge")
    ap.add_argument("--rts-power", action="store_true",
                    help="switch the board's 5 V with the FTDI's RTS line "
                         "through an external MOSFET or relay")
    ap.add_argument("--rts-invert", action="store_true",
                    help="RTS low = powered (active-low switch)")
    ap.add_argument("--uhubctl", help="LOC:PORT, e.g. 1-1:2")
    ap.add_argument("--off"), ap.add_argument("--on")
    ap.add_argument("--manual", action="store_true")
    ap.add_argument("--label", default="", help="name for the log")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    import subprocess
    ser_ref = {}
    def power(state):
        if args.rts_power:
            # pyserial drives RTS directly, so the power switch and the data
            # link share one cable. Note the FTDI keeps driving TX into a
            # powered-down board; that is what the series resistor in the
            # adapter is for, but it is worth knowing if anything looks odd
            # during the off window.
            on = (state == "on")
            ser_ref["s"].rts = (not on) if args.rts_invert else on
            return
        if args.manual:
            input(f"    >>> power {state.upper()}, then press Enter ")
            return
        if args.uhubctl:
            loc, port = args.uhubctl.split(":")
            subprocess.run(["uhubctl", "-l", loc, "-p", port,
                            "-a", "on" if state == "on" else "off"], check=False)
            return
        cmd = args.on if state == "on" else args.off
        if cmd:
            subprocess.run(cmd, shell=True, check=False)

    img = open(args.image, "r+b")
    geom = detect_geometry(img.seek(0, 2) or img.tell())
    img.seek(0)
    bios = open(args.bios, "rb").read() if args.bios else b""

    print(f"coldboot: {args.trials} trials"
          + (f"  [{args.label}]" if args.label else ""))
    print(f"  geometry {geom[0]}x{geom[1]}x{geom[2]}, "
          f"BIOS {len(bios)} bytes, {args.settle:.0f} s off, "
          f"{args.timeout:.0f} s to boot\n")

    try:
        ser = serial.Serial(args.port, args.baud, timeout=0.2)
    except serial.SerialException as e:
        sys.exit(
            f"cannot open {args.port}: {e}\n\n"
            "If GertieBoardLoader (or floppy_host.py) is running, CLOSE IT.\n"
            "This script serves the BIOS and floppy itself for the duration of\n"
            "a run -- two programs cannot own the same port, and the board would\n"
            "be answered by whichever won the race.")
    ser_ref["s"] = ser
    results = []
    try:
        for i in range(1, args.trials + 1):
            power("off")
            if not args.manual:
                time.sleep(args.settle)
            power("on")
            verdict, detail = one_trial(ser, img, bios, geom,
                                        args.timeout, args.verbose)
            results.append(verdict)
            fails = sum(1 for v in results if v != "PASS")
            mark = "ok  " if verdict == "PASS" else "FAIL"
            print(f"  {i:3d}/{args.trials}  {mark} {verdict:<8} {detail}"
                  f"    running: {fails}/{i} failed")
    except KeyboardInterrupt:
        print("\ninterrupted")
    finally:
        ser.close()

    n = len(results)
    k = sum(1 for v in results if v != "PASS")
    if n:
        lo, hi = wilson(k, n)
        print(f"\n{k} failures in {n}  =  {100*k/n:.1f} %")
        print(f"95 % confidence: {100*lo:.1f} % .. {100*hi:.1f} %")
        for v in ("NO_BIOS", "NO_BOOT", "BAD_CHS"):
            c = sum(1 for x in results if x == v)
            if c:
                print(f"   {v:<8} {c}")
        # The interval is the point. Two builds only differ if their intervals
        # do not overlap -- "1 of 5 versus 0 of 5" never cleared that bar.
        if k == 0 and n < 15:
            print("\nNOTE: zero failures in fewer than 15 trials does not "
                  "establish a clean build.")


if __name__ == "__main__":
    main()
