#!/usr/bin/env bash
# ============================================================================
#  mkbios.sh -- build xtbios_src.s into the 8 KB image AND the 64 KB F-segment
#               image, then verify the result.
#
#  This exists because doing it by hand went wrong in a way that was hard to
#  spot: the link and the make64k step were chained with && after a `grep -v`
#  that filtered every line, so grep exited non-zero, make64k never ran, and a
#  DAY-OLD .64k kept being served while the freshly built .bin looked correct.
#  The board just booted the old BIOS with no error anywhere.
#
#  So: one command, `set -e`, and an explicit verify at the end. If it prints
#  BUILD OK the .64k on disk really is the image you just built.
#
#  Usage:  bash tools/mkbios.sh [src.s]        (default: xtbios_src.s)
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

SRC="${1:-xtbios_src.s}"
BASE="$(basename "$SRC" .s)"
[ "$BASE" = "xtbios_src" ] && BASE="xtbios_claude"      # historical output name
BIN="$BASE.bin"
K64="$BASE.64k"

echo "== assembling $SRC =="
# `as`/`ld` come from WSL; -e _post only sets the (unused for a flat binary)
# ELF entry, so ld's "cannot find entry symbol" note is expected and harmless.
wsl bash -c "cd /mnt/c/altera/gertieboard/tools && \
  as --32 '$SRC' -o /tmp/$BASE.o && \
  ld -m elf_i386 -Ttext=0xE000 --section-start=.reset=0xFFF0 \
     --oformat=binary -e _post /tmp/$BASE.o -o '$BIN'"

sz=$(wc -c < "$BIN")
[ "$sz" -eq 8192 ] || { echo "FAIL: $BIN is $sz bytes, expected 8192"; exit 1; }
echo "   $BIN = $sz bytes"

echo "== expanding to 64 KB =="
python3 make64k.py "$BIN" -o "$K64"

echo "== verifying =="
python3 - "$BIN" "$K64" <<'PY'
import sys
binf, k64f = sys.argv[1], sys.argv[2]
b = open(binf,'rb').read()
d = open(k64f,'rb').read()
fails = []
if len(d) != 65536:                       fails.append(f"{k64f} is {len(d)} bytes, expected 65536")
if d[0xE000:0x10000] != b:                fails.append("8 KB image is not placed at F-seg offset 0xE000")
if d[0xFFF0:0xFFF2] != b'\xea\x00':       fails.append("reset vector at 0xFFF0 is not a far jump")
if d[0xFFF3:0xFFF5] != b'\x00\xf0':       fails.append("reset vector does not target segment F000")
if any(x != 0xFF for x in d[:0xE000]):    fails.append("fill below 0xE000 is not 0xFF")
# the .64k must be built from THIS .bin -- the bug this script prevents
if fails:
    print("BUILD FAILED:")
    for f in fails: print("   -", f)
    sys.exit(1)
print("   64 KB image OK: 8 KB at 0xFE000-0xFFFFF, reset vector",
      d[0xFFF0:0xFFF5].hex(), "fill 0xFF below")
PY

echo
echo "BUILD OK -> $BIN + $K64"
echo "Serve it with:  python floppy_host.py --port COMx --image dos33-xtpro.img --bios $K64"
