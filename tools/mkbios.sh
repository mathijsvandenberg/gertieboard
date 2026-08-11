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
# Output is named after the board, not the source file: the BIOS ships together
# with the bitstream as one release, so gertieboard_bios.64k sits alongside
# gertieboard.sof / gertieboard.jic.
[ "$BASE" = "xtbios_src" ] && BASE="gertieboard_bios"
BIN="$BASE.bin"
K64="$BASE.64k"

# The BIOS grew past 8 KB when USB mass storage went in -- it was using 8191 of
# 8192 bytes, one byte spare. 16 KB at 0xC000 is the next step up: make64k.py
# already top-aligns a 16 KB image there, and the reset vector needs no change
# because it jumps to the _post SYMBOL, not a hardcoded address.
ROMSZ=16384
ROMOFF=0xC000

# ---------------------------------------------------------------------------
# Stamp the image with the commit it was built from. "Which BIOS is running?"
# is a question that has cost real time here -- twice a stale artefact was
# diagnosed as a hardware fault -- and seven characters on the POST screen
# answer it without guesswork. A trailing + means the working tree had
# uncommitted changes, so the hash alone does not describe the build.
GITHASH="$(git rev-parse --short=7 HEAD 2>/dev/null || echo 0000000)"
git diff --quiet HEAD 2>/dev/null || GITHASH="$GITHASH+"
printf 'b_git:    .asciz "%s"
' "$GITHASH" > gitver.inc
echo "== build stamp $GITHASH =="

# ---------------------------------------------------------------------------
# GNU as turns a symbol used BEFORE its .equ into a forward label reference, so
# "cmp dl, HD_DRIVE" silently assembles as "cmp dl, [0x0001]" -- a compare
# against memory instead of an immediate. The source looks perfect and only the
# encoding is wrong. This has cost two debugging rounds already (HD_DRIVE, then
# U_BUFSZ), so it is a build failure rather than something to remember.
echo "== checking .equ ordering =="
python3 tools_equcheck.py "$SRC" || exit 1

echo "== assembling $SRC =="
# `as`/`ld` come from WSL; -e _post only sets the (unused for a flat binary)
# ELF entry, so ld's "cannot find entry symbol" note is expected and harmless.
wsl bash -c "cd /mnt/c/altera/gertieboard/tools && \
  as --32 '$SRC' -o /tmp/$BASE.o && \
  ld -m elf_i386 -Ttext=$ROMOFF --section-start=.reset=0xFFF0 \
     --section-start=.font_rom=0xFA6E \
     --oformat=binary -e _post /tmp/$BASE.o -o '$BIN'"

sz=$(wc -c < "$BIN")
[ "$sz" -eq "$ROMSZ" ] || { echo "FAIL: $BIN is $sz bytes, expected $ROMSZ"; exit 1; }
echo "   $BIN = $sz bytes"

echo "== expanding to 64 KB =="
python3 make64k.py "$BIN" -o "$K64"

echo "== verifying =="
python3 - "$BIN" "$K64" "$ROMOFF" <<'PY'
import sys
binf, k64f = sys.argv[1], sys.argv[2]
off = int(sys.argv[3], 0)
b = open(binf,'rb').read()
d = open(k64f,'rb').read()
fails = []
if len(d) != 65536:                       fails.append(f"{k64f} is {len(d)} bytes, expected 65536")
if d[off:0x10000] != b:                   fails.append(f"image is not at F-seg offset 0x{off:04X}")
if d[0xFFF0:0xFFF2] != b'\xea\x00':       fails.append("reset vector at 0xFFF0 is not a far jump")
if d[0xFFF3:0xFFF5] != b'\x00\xf0':       fails.append("reset vector does not target segment F000")
if any(x != 0xFF for x in d[:off]):       fails.append(f"fill below 0x{off:04X} is not 0xFF")
# The 8x8 font MUST be readable at F000:FA6E. Software hardcodes that address
# rather than reading INT 43h -- King's Quest does -- and a zero-filled gap
# there is silent: it looks like a font full of blank glyphs, not like an
# error. Checking the ADDRESS is the only thing that catches a bad link.
font = open("font8x8.bin","rb").read()[:1024]
if d[0xFA6E:0xFA6E+1024] != font:         fails.append("8x8 font (chars 0..127) is NOT at F000:FA6E")
# the .64k must be built from THIS .bin -- the bug this script prevents
if fails:
    print("BUILD FAILED:")
    for f in fails: print("   -", f)
    sys.exit(1)
print(f"   64 KB image OK: {len(b)//1024} KB at 0x{0xF0000+off:05X}-0xFFFFF, reset vector",
      d[0xFFF0:0xFFF5].hex(), "fill 0xFF below")
PY

echo
echo "BUILD OK -> $BIN + $K64"
echo "Serve it with:  python floppy_host.py --port COMx --image dos33-xtpro.img --bios $K64"
