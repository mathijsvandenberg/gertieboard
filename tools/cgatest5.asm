; ============================================================================
;  cgatest5.asm  --  CGA drawing-technique test (DOS .COM)
;
;  Everything tested so far works: hardware, BIOS mode-set, retrace, timer.
;  And the BIOS INT16 probe shows Digger is ALIVE, looping on the keyboard --
;  it just draws nothing visible.  All earlier tests wrote VRAM with
;  "rep stosb" of an immediate value.  Digger does NOT draw that way: it uses
;  word moves from a RAM buffer and masked read-modify-write sprites.  Those
;  two paths are still unverified -- especially VRAM READ-BACK in graphics
;  mode, which masked sprites depend on.  This test exercises them.
;
;  Three bands, top to bottom:
;    A. STRIPES  (top)    -- written with REP MOVSW from a RAM buffer.
;                            Missing/garbled -> word-move writes to VRAM fail.
;    B. STATUS   (middle) -- VRAM read-back check: writes bytes, reads them
;                            back, compares.
;                              WHITE band  = read-back CORRECT
;                              MAGENTA band= read-back WRONG  <-- the bug
;    C. CHECKER  (bottom) -- drawn with read/AND-mask/OR-sprite/write, i.e. the
;                            masked-sprite path.  Missing or solid -> RMW fails.
;
;  If A and C are missing but earlier tests drew fine, Digger's blank screen is
;  explained: its drawing method doesn't reach the framebuffer.
;
;  Build:  nasm -f bin cgatest5.asm -o cgatest5.com
; ============================================================================

        org  0x100
        bits 16

VID     equ 0xB800

start:
        cld
        mov  ax, 0x0004         ; BIOS mode 4 (3D9=0x30: palette1+intensity)
        int  0x10

        mov  ax, VID
        mov  es, ax
        xor  di, di             ; clear both banks
        xor  al, al
        mov  cx, 0x4000
        rep  stosb

        ; ---------------- A: REP MOVSW from a RAM buffer ----------------
        ; build a 2000-byte stripe pattern in our own segment, then word-move
        ; it into bank 0 (rows 0..24) and bank 1 (odd rows).
        mov  di, buf
        mov  cx, 1000           ; 1000 words = 2000 bytes
        mov  ax, 0x55AA         ; alternating pixel colours
        push es
        push ds
        pop  es                 ; ES = our segment for this fill
        rep  stosw
        pop  es                 ; ES = VID again

        mov  si, buf
        xor  di, di
        mov  cx, 1000           ; 2000 bytes -> bank 0, first 25 CGA rows
        rep  movsw              ; <-- word moves RAM -> VRAM
        mov  si, buf
        mov  di, 0x2000
        mov  cx, 1000
        rep  movsw              ; same into bank 1

        ; ---------------- B: VRAM read-back verification ----------------
        ; write a known sequence into a scratch area, read it back, compare.
        mov  di, 40*80          ; well clear of band A
        mov  al, 0x3C
        mov  cx, 80
.wr:    mov  [es:di], al
        inc  di
        inc  al                 ; varying data, not a constant
        loop .wr

        mov  di, 40*80
        mov  al, 0x3C
        mov  cx, 80
        mov  bl, 1              ; assume pass
.rd:    mov  ah, [es:di]        ; <-- VRAM read-back in graphics mode
        cmp  ah, al
        je   .ok
        xor  bl, bl             ; mismatch -> fail
.ok:    inc  di
        inc  al
        loop .rd

        ; paint the status band: white = pass, magenta = fail
        mov  al, 0xFF           ; white
        cmp  bl, 1
        je   .paint
        mov  al, 0xAA           ; magenta
.paint:
        mov  di, 40*80
        mov  cx, 6*80
        rep  stosb
        mov  di, 0x2000 + 40*80
        mov  cx, 6*80
        rep  stosb

        ; ---------------- C: masked read-modify-write sprites ------------
        ; classic sprite blit: (background AND mask) OR sprite, per byte.
        mov  di, 60*80
        mov  cx, 30*80
.rmw:   mov  al, [es:di]        ; read background
        and  al, 0x0F           ; mask: keep low nibble of background
        or   al, 0xA0           ; sprite bits into the high nibble
        mov  [es:di], al        ; write back
        inc  di
        loop .rmw
        mov  di, 0x2000 + 60*80
        mov  cx, 30*80
.rmw2:  mov  al, [es:di]
        and  al, 0x0F
        or   al, 0xA0
        mov  [es:di], al
        inc  di
        loop .rmw2

        xor  ah, ah
        int  0x16               ; wait for a key
        mov  ax, 0x0003
        int  0x10
        mov  ax, 0x4C00
        int  0x21

buf:                            ; 2000-byte scratch buffer (uninitialised tail)
