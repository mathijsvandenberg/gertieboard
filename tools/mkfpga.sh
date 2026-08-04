#!/usr/bin/env bash
# ============================================================================
#  mkfpga.sh -- build the FPGA, and refuse to leave a lie behind.
#
#  This exists for the same reason mkbios.sh does, and it was written after the
#  same mistake was made three times in one day:
#
#    * quartus_map failed on a VHDL error. The && chain stopped, exactly as it
#      should -- but output_files/ still held the reports and the .sof from the
#      PREVIOUS run. Every number read from them was real, current-looking, and
#      about a different design. The only tell was a resource count that had not
#      changed after adding a port, a synchroniser and reset gating.
#
#    * A .sof was programmed that was two clock rates out of date, so an hour
#      was spent testing 8.333 MHz while believing it was 6.25.
#
#    * A build closed timing at -0.037 ns and nobody noticed, because the
#      summary was read for the clock frequency and not for the slack.
#
#  So: one command, every stage checked, and three refusals -- a stage that did
#  not report success, any negative slack, and a .sof older than the newest
#  source file. If it prints BUILD OK then the .sof on disk really is the design
#  in the working tree, and it really does meet timing.
#
#  It then converts that .sof to a .jic for the EPCS16, by calling mkjic.sh
#  rather than repeating it. The .jic is a SECOND copy of the bitstream and the
#  one the board actually boots from, so leaving it a build behind reproduces
#  the stale-artefact trap this file exists to close -- only now it survives a
#  power cycle. Deleting it up front means a failed build cannot leave one.
#
#  Usage:  bash tools/mkfpga.sh
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

QDIR="${QUARTUS_BIN:-C:/altera/25.1std/quartus/bin64}"
PROJ=gertieboard
OUT=output_files
LOG=$OUT/mkfpga.log

for t in map fit asm sta cpf; do
  [ -x "$QDIR/quartus_$t.exe" ] || { echo "FAIL: no quartus_$t in $QDIR"; exit 1; }
done

mkdir -p "$OUT"

# Remove the artefacts we are about to claim to have produced. Without this a
# failed build leaves the previous ones in place and every check below passes
# while describing the wrong design -- which is the whole reason this file
# exists.
rm -f "$OUT/$PROJ.sof" "$OUT/$PROJ.jic" "$OUT/$PROJ.sta.summary" "$OUT/$PROJ.fit.summary"

echo "== building $PROJ =="
: > "$LOG"
for t in map fit asm sta; do
  printf '   quartus_%-4s ' "$t"
  if "$QDIR/quartus_$t.exe" "$PROJ" >> "$LOG" 2>&1; then
    echo "ok"
  else
    echo "FAILED"
    echo
    echo "---- errors from quartus_$t ----"
    grep -E "^Error" "$LOG" | head -20
    echo
    echo "BUILD FAILED. Full log: $LOG"
    exit 1
  fi
done

# quartus_* can return 0 and still have reported errors, so check the log too.
if grep -qE "^Error" "$LOG"; then
  echo
  echo "BUILD FAILED: errors in the log despite a zero exit code"
  grep -E "^Error" "$LOG" | head -20
  exit 1
fi

echo
echo "== verifying =="
python3 - "$OUT" "$PROJ" <<'PY'
import glob, os, re, sys

out, proj = sys.argv[1], sys.argv[2]
sof = os.path.join(out, proj + '.sof')
fails = []

if not os.path.exists(sof):
    print("BUILD FAILED: no .sof was produced")
    sys.exit(1)

# ---- 1. the .sof must be newer than every source it was built from --------
srcs = glob.glob('*.vhd') + glob.glob('*.vhdl') + glob.glob('*.qsf') + glob.glob('*.sdc')
sof_t = os.path.getmtime(sof)
stale = [f for f in srcs if os.path.getmtime(f) > sof_t]
if stale:
    fails.append(".sof is older than: " + ", ".join(sorted(stale)[:5]))

# ---- 2. every clock must meet timing -------------------------------------
# Reading the summary for the frequency and not the slack is how a -0.037 ns
# build shipped once. Any negative number here is a failure, not a note.
summ = os.path.join(out, proj + '.sta.summary')
worst = []
if os.path.exists(summ):
    txt = open(summ, encoding='utf-8', errors='replace').read()
    for blk in re.findall(r"Type\s*:\s*(.+?)\n\s*Slack\s*:\s*(-?[\d.]+)", txt):
        kind, slack = blk[0].strip(), float(blk[1])
        worst.append((slack, kind))
        if slack < 0:
            fails.append("NEGATIVE SLACK %.3f ns on %s" % (slack, kind))
    if not worst:
        fails.append("no slack figures in the timing summary")
else:
    fails.append("no timing summary produced")

# ---- 3. report what was actually built -----------------------------------
rpt = os.path.join(out, proj + '.sta.rpt')
if os.path.exists(rpt):
    for line in open(rpt, encoding='utf-8', errors='replace'):
        if 'CPU_CLK_OUT' in line:
            m = re.search(r';\s*([\d.]+)\s*;\s*([\d.]+\s*[GMk]?Hz)', line)
            if m:
                print("   CPU clock      %s  (%s ns)" % (m.group(2).strip(), m.group(1)))
            break

fit = os.path.join(out, proj + '.fit.summary')
if os.path.exists(fit):
    for line in open(fit, encoding='utf-8', errors='replace'):
        if 'logic elements' in line or 'memory bits' in line:
            print("   " + line.split(':', 1)[1].strip().replace('  ', ' '))

if worst:
    s, k = min(worst)
    print("   worst slack    %+.3f ns  (%s)" % (s, k.split("'")[-2] if "'" in k else k))

if fails:
    print()
    print("BUILD FAILED:")
    for f in fails:
        print("   -", f)
    sys.exit(1)
PY

echo
echo "== configuration flash =="
bash tools/mkjic.sh

echo
echo "BUILD OK -> $OUT/$PROJ.sof  (JTAG, volatile)"
echo "         -> $OUT/$PROJ.jic  (EPCS16, survives a power cycle)"
echo "Program either one, and remember the BIOS is a separate artefact:"
echo "   quartus_pgm -m jtag -o \"p;$OUT/$PROJ.sof\"     tools/mkbios.sh"
echo "   quartus_pgm -m jtag -o \"ipv;$OUT/$PROJ.jic\""
