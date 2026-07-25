#!/usr/bin/env bash
# ============================================================================
#  mkjic.sh -- turn output_files/gertieboard.sof into a .jic so the FPGA
#              configures itself from the DE0-Nano's EPCS16 at power-on,
#              instead of needing a JTAG RAM load every time.
#
#  It refuses to run if the .sof is older than any FPGA source. That check is
#  here for a reason: a stale 64 KB BIOS image was served for two days because
#  one build step silently did not run, and every "fix" appeared to change
#  nothing. Flashing a stale bitstream into configuration memory is the same
#  trap, only slower to notice.
#
#  Usage:  bash tools/mkjic.sh [EPCS device]      (default EPCS16)
#
#  Then program the config flash over JTAG with:
#     quartus_pgm -m jtag -o "ipv;output_files/gertieboard.jic"
#  Power-cycle afterwards -- the FPGA loads from EPCS at power-up, so a JTAG
#  RAM load is no longer needed.
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

QDIR="/c/altera/25.1std/quartus/bin64"
DEV="${1:-EPCS16}"
FPGA="EP4CE22F17C6"
SOF="output_files/gertieboard.sof"
JIC="output_files/gertieboard.jic"

[ -f "$SOF" ] || { echo "FAIL: $SOF does not exist -- run the Quartus flow first"; exit 1; }

echo "== checking the bitstream is not stale =="
newest=$(ls -t *.vhd *.vhdl *.qsf *.sdc 2>/dev/null | head -1)
if [ "$SOF" -ot "$newest" ]; then
    echo "FAIL: $SOF is OLDER than $newest"
    echo "      rebuild first:  quartus_map/fit/asm  (or the full flow)"
    exit 1
fi
echo "   $SOF is newer than $newest -- ok"

echo "== converting for $DEV =="
"$QDIR/quartus_cpf.exe" -c -d "$DEV" -s "$FPGA" "$SOF" "$JIC" >/dev/null

sz=$(wc -c < "$JIC")
echo "   $JIC = $sz bytes"
# EPCS16 is 16 Mbit = 2 MiB; a wildly different size means the wrong -d value
case "$DEV" in
  EPCS16) want=2097152 ;;
  EPCS64) want=8388608 ;;
  EPCS4)  want=524288  ;;
  *)      want=0 ;;
esac
if [ "$want" -ne 0 ]; then
    lo=$(( want - want/8 ))
    [ "$sz" -ge "$lo" ] || { echo "FAIL: expected roughly $want bytes for $DEV"; exit 1; }
fi

echo
echo "JIC OK -> $JIC"
echo "Program it with:"
echo "   quartus_pgm -m jtag -o \"ipv;$JIC\""
echo "then power-cycle the board."
