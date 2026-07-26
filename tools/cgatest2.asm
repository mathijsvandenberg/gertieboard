; ============================================================================
;  cgatest2.asm  --  CGA graphics test via the BIOS INT 10h path (DOS .COM)
;
;  Companion to cgatest.com.  cgatest poked the CGA registers DIRECTLY and
;  proved the *hardware* graphics path works.  This version instead sets the
;  mode through INT 10h AH=00 -- exactly what Digger and other games do -- so
;  it exercises the BIOS v_setmode routine (xtbios_claude) rather than the
;  hardware.  It draws nothing but the mode set + a framebuffer pattern.
;
;    Stage 1: INT 10h AX=0004  (BIOS "set mode 4")  then colour bars.
;             BIOS programs 3D9=0x30 (palette 1 + intensity, black bg), so
;             correct output is:  light-cyan, light-magenta, white, black.
;    Stage 2: INT 10h AX=0005  (BIOS "set mode 5", b/w palette) then bars.
;             Correct output:     light-cyan, light-red, white, black.
;    Stage 3: INT 10h AX=0003   back to text, exit.
;
;  Interpreting the result (compare against cgatest.com, which already works):
;    * Clean bars in both stages -> the BIOS mode-set works; Digger's blank
;      screen is NOT the mode set (look at timer/keyboard/retrace-wait hangs,
;      or confirm the updated BIOS is actually being served).
;    * Blank screen -> BIOS v_setmode leaves graphics disabled.
;    * Garbled *text* characters instead of graphics -> an OLD BIOS is loaded
;      (its v_setmode ignores AL and stays in text mode); reflash / re-serve
;      xtbios_claude.64k.
;
;  Build:  nasm -f bin cgatest2.asm -o cgatest2.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

VID     equ 0xB800

start:
        ; ---------------- stage 1: BIOS mode 4 ----------------
        mov  ax, 0x0004
        int  0x10
        mov  ax, VID
        mov  es, ax
        xor  di, di
        call bars_bank
        mov  di, 0x2000
        call bars_bank
        call waitkey

        ; ---------------- stage 2: BIOS mode 5 ----------------
        mov  ax, 0x0005
        int  0x10
        mov  ax, VID
        mov  es, ax
        xor  di, di
        call bars_bank
        mov  di, 0x2000
        call bars_bank
        call waitkey

        ; ---------------- stage 3: back to DOS ----------------
        mov  ax, 0x0003
        int  0x10
        mov  ax, 0x4C00
        int  0x21

; one 8000-byte bank: 4 vertical bars (colours 1,2,3,0 -> 0x55,0xAA,0xFF,0x00)
bars_bank:
        cld
        mov  bx, 100
.row:
        mov  al, 0x55
        mov  cx, 20
        rep  stosb
        mov  al, 0xAA
        mov  cx, 20
        rep  stosb
        mov  al, 0xFF
        mov  cx, 20
        rep  stosb
        xor  al, al
        mov  cx, 20
        rep  stosb
        dec  bx
        jnz  .row
        ret

waitkey:
        xor  ah, ah
        int  0x16
        ret
