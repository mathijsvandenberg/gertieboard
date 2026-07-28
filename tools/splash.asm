; ============================================================================
;  splash.asm  --  full-screen CGA splash: "Gertieboard" as graffiti on a wall
;
;  Mode 4, 320x200, four colours. The artwork is built by tools/mksplash.py and
;  linked in as a run-length encoded framebuffer; this just sets the mode, sets
;  the palette, unpacks, and waits.
;
;  Palette, via the colour-select register at 0x3D9:
;      bits 3-0  background and border colour   -> 0, black
;      bit 4     intensity                      -> 1, the bright set
;      bit 5     palette                        -> 0, green / red / brown
;  which with the intensity bit gives light green, light red and yellow. That
;  is as close as CGA comes to the reference artwork: yellow letters, a red
;  keyline, a black outline that costs nothing because black is the background,
;  and green left over for the wall so it stays behind the warm colours.
;
;  Memory layout is the usual CGA oddity: two banks, even scanlines at
;  B800:0000 and odd ones at B800:2000, 80 bytes to a row, four pixels to a
;  byte, most significant bits leftmost. The generator has already interleaved
;  it, so unpacking is a straight linear write of 16384 bytes -- the 192-byte
;  holes at the end of each bank are included and cost two bytes each once
;  compressed.
;
;  Build:  python mksplash.py  &&  nasm -f bin splash.asm -o splash.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

VID     equ 0xB800
VIDLEN  equ 0x4000              ; both banks, holes included
CGA_SEL equ 0x3D9               ; colour select

start:
        mov  ax, 0x0004         ; INT 10h: 320x200 4-colour graphics
        int  0x10

        mov  dx, CGA_SEL
        mov  al, 0x10           ; black background, intense palette 0
        out  dx, al

        ; ---- unpack straight into video memory ----
        ; PackBits: 0x80|n = (n+1) copies of the next byte, otherwise (n+1)
        ; literal bytes follow. The length is the stop condition rather than
        ; any end marker, because a literal run of one zero byte encodes
        ; identically to one -- counting is unambiguous, a sentinel is not.
        mov  ax, VID
        mov  es, ax
        xor  di, di
        mov  si, art
        cld
.unpack:
        cmp  di, VIDLEN
        jae  .shown
        lodsb
        mov  cl, al
        mov  ch, 0
        test al, 0x80
        jnz  .run
        inc  cx                 ; literal: cx+1 bytes straight through
        rep  movsb
        jmp  short .unpack
.run:
        and  cl, 0x7F
        inc  cx                 ; run: cx+1 copies of one byte
        lodsb
        rep  stosb
        jmp  short .unpack

.shown:
        xor  ah, ah             ; wait for any key
        int  0x16

        mov  ax, 0x0003         ; back to 80x25 text
        int  0x10
        mov  ax, 0x4C00
        int  0x21

art:
        incbin "splash.dat"
