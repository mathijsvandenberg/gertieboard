; ============================================================================
;  cgatest.asm  --  CGA 320x200 graphics hardware test (DOS .COM)
;
;  Isolates the FPGA CGA graphics path from both Digger and the BIOS mode-set:
;  it pokes the CGA mode/colour registers DIRECTLY (no INT 10h) and writes the
;  framebuffer by hand, so a blank result points squarely at the hardware
;  (register latch, video-enable, interleave read, or pixel decode).
;
;  It walks through four stages, one keypress each.  Watch the screen and note
;  the FIRST stage that misbehaves -- that localises the fault:
;
;    1. SOLID BLUE      3D9 background = blue, framebuffer cleared to pixel 0.
;                       Proves: 3D8/3D9 latch works, video is enabled, the
;                       interleave read + background decode work, VRAM writes
;                       land.  If this is BLACK -> the mode/enable latch or the
;                       render pipeline is broken (not a colour/pixel issue).
;
;    2. COLOUR BARS     Four vertical bars: cyan, magenta, white, blue(bg).
;                       Proves the 2-bpp pixel decode + palette.  Bars present
;                       but wrong colours -> palette wiring; bars sheared or
;                       shifted -> pipeline alignment; still solid blue ->
;                       VRAM data not reaching the scan-out.
;
;    3. TOP/BOTTOM      Top half white, bottom half cyan.  Exercises the
;                       even/odd interleave banks independently (a bad bank
;                       shows as horizontal striping every other line).
;
;    4. back to DOS     Restores 80x25 text (INT 10h mode 3 + direct poke).
;
;  Build:  nasm -f bin cgatest.asm -o cgatest.com
; ============================================================================

        org  0x100
        bits 16

VID     equ 0xB800
MODEREG equ 0x03D8
COLREG  equ 0x03D9

start:
        ; --- enter graphics mode 4 by DIRECT poke (bypass the BIOS) ---
        mov  dx, MODEREG
        mov  al, 0x0A            ; bit1 graphics + bit3 video-enable
        out  dx, al
        mov  dx, COLREG
        mov  al, 0x01            ; palette 0, bg = blue (colour 1)
        out  dx, al

        mov  ax, VID
        mov  es, ax

        ; ===================== stage 1: solid blue ======================
        call clear_fb            ; all pixels = 0 -> background = blue
        call waitkey

        ; ===================== stage 2: colour bars =====================
        xor  di, di
        call bars_bank           ; even lines
        mov  di, 0x2000
        call bars_bank           ; odd lines
        call waitkey

        ; =================== stage 3: top / bottom ======================
        ; top 100 CGA lines white (0xFF), bottom 100 cyan-ish (0x55).
        ; top    = display lines 0..99   -> even bank rows 0..49  + odd rows 0..49
        ; bottom = display lines 100..199-> even bank rows 50..99 + odd rows 50..99
        xor  di, di
        mov  al, 0xFF
        mov  cx, 50*80
        rep  stosb               ; even bank, top half
        mov  al, 0x55
        mov  cx, 50*80
        rep  stosb               ; even bank, bottom half
        mov  di, 0x2000
        mov  al, 0xFF
        mov  cx, 50*80
        rep  stosb               ; odd bank, top half
        mov  al, 0x55
        mov  cx, 50*80
        rep  stosb               ; odd bank, bottom half
        call waitkey

        ; ===================== stage 4: back to DOS =====================
        mov  ax, 0x0003
        int  0x10                ; BIOS restore text
        mov  dx, MODEREG
        mov  al, 0x29
        out  dx, al              ; belt-and-braces direct poke
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; clear_fb: zero both interleave banks (16 KB page)
; ---------------------------------------------------------------------------
clear_fb:
        cld
        xor  di, di
        xor  al, al
        mov  cx, 0x4000          ; 16384 bytes
        rep  stosb
        ret

; ---------------------------------------------------------------------------
; bars_bank: write one 8000-byte bank (100 rows x 80 bytes) with 4 vertical
;            bars.  Byte value = colour replicated across its 4 pixels:
;              colour 1 -> 0x55, colour 2 -> 0xAA, colour 3 -> 0xFF, 0 -> 0x00
;            ES:DI must point at the bank base; DI is advanced past it.
; ---------------------------------------------------------------------------
bars_bank:
        cld
        mov  bx, 100             ; rows
.row:
        mov  al, 0x55            ; bar 0: colour 1
        mov  cx, 20
        rep  stosb
        mov  al, 0xAA            ; bar 1: colour 2
        mov  cx, 20
        rep  stosb
        mov  al, 0xFF            ; bar 2: colour 3
        mov  cx, 20
        rep  stosb
        xor  al, al             ; bar 3: colour 0 (background = blue)
        mov  cx, 20
        rep  stosb
        dec  bx
        jnz  .row
        ret

; ---------------------------------------------------------------------------
; waitkey: block until a key is pressed (BIOS INT 16h)
; ---------------------------------------------------------------------------
waitkey:
        xor  ah, ah
        int  0x16
        ret
