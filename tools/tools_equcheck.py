#!/usr/bin/env python3
"""
tools_equcheck.py -- fail the build if a .equ symbol is used before it is defined.

GNU as (Intel syntax) treats a symbol referenced ahead of its .equ as a forward
LABEL reference, so it assembles as a memory operand rather than an immediate:

    cmp dl, HD_DRIVE   ->   3A 16 01 00    cmp dl, [0x0001]

The source reads correctly and only the encoding is wrong, which makes it
invisible to review and to any test that looks at logic rather than bytes. It
has bitten this project twice -- HD_DRIVE, which sent every B: access to the
serial floppy, and U_BUFSZ, which compared a descriptor length against the
BDA's floppy motor counter and stopped USB enumeration dead.
"""
import re
import sys

src = open(sys.argv[1], encoding='utf-8').read().splitlines()

defined = {}
for i, line in enumerate(src):
    m = re.match(r'\s*\.equ\s+(\w+)\s*,', line)
    if m:
        defined.setdefault(m.group(1), i)

bad = []
for name, dline in defined.items():
    pat = re.compile(r'\b' + re.escape(name) + r'\b')
    for i, line in enumerate(src[:dline]):
        if pat.search(line.split('#')[0]):
            bad.append((name, i + 1, dline + 1))

if bad:
    print("FAIL: .equ symbols used before they are defined; these assemble")
    print("      as MEMORY OPERANDS instead of immediates:")
    for name, use, dfn in bad:
        print(f"   {name}  used at line {use}, defined at line {dfn}")
    sys.exit(1)

print(f"   {len(defined)} .equ symbols, all defined before first use")
