; ============================================================================
;  cgatest4.asm  --  CGA vertical-retrace (3DA bit 3) sync test (DOS .COM)
;
;  Disassembling DIGGER.EXE shows it spins on the CGA status port exactly here:
;
;        mov dx,0x3DA
;    w:  in  al,dx
;        test al,8          ; bit 3 = vertical retrace
;        jnz  w             ; wait for retrace to END, then (2nd loop) to START
;
;  If status bit 3 ever sticks, that spin never exits and Digger hangs with a
;  blank graphics screen -- the exact symptom.  This test runs the SAME two-part
;  retrace sync, but with a timeout so a stuck bit reports instead of hanging.
;
;  It sweeps a white fill down the screen, one CGA line per retrace, for 200
;  frames.  Result:
;    * A white fill marches top->bottom over ~3-4 s, ending SOLID WHITE ->
;      3DA bit 3 toggles correctly; retrace sync is NOT Digger's problem.
;    * Screen turns MAGENTA (bottom half) almost immediately -> bit 3 is stuck;
;      the retrace spin never completes.  THAT is the Digger hang, and the fix
;      is in cga_status.vhd (bit 3 timing / the counter that drives it).
;
;  Build:  nasm -f bin cgatest4.asm -o cgatest4.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

VID     equ 0xB800

start:
        cld
        mov  ax, 0x0004         ; BIOS: CGA mode 4
        int  0x10

        mov  ax, VID
        mov  es, ax
        xor  di, di             ; clear both banks to background
        xor  al, al
        mov  cx, 0x4000
        rep  stosb

        xor  si, si             ; frame / CGA-line counter
.frame:
        mov  dx, 0x03DA
        ; --- wait until bit3 = 0 (not in retrace), with timeout ---
        mov  cx, 0xFFFF
.w1:    in   al, dx
        test al, 8
        jz   .w1done
        loop .w1
        jmp  .syncfail
.w1done:
        ; --- wait until bit3 = 1 (retrace begins), with timeout ---
        mov  cx, 0xFFFF
.w2:    in   al, dx
        test al, 8
        jnz  .w2done
        loop .w2
        jmp  .syncfail
.w2done:
        call draw_row           ; one white line at CGA row SI
        inc  si
        cmp  si, 200
        jb   .frame
        jmp  .fin               ; success: full white sweep completed

.syncfail:
        ; bit 3 never toggled within the timeout -> paint magenta as the signal
        xor  di, di
        mov  al, 0xAA
        mov  cx, 50*80
        rep  stosb              ; even bank
        mov  di, 0x2000
        mov  al, 0xAA
        mov  cx, 50*80
        rep  stosb              ; odd bank

.fin:
        xor  ah, ah
        int  0x16               ; wait for a key
        mov  ax, 0x0003
        int  0x10
        mov  ax, 0x4C00
        int  0x21

; draw_row: solid white (0xFF) 80-byte row at CGA line SI, honouring the
;           even/odd interleave (even line -> bank 0, odd line -> bank 1).
draw_row:
        push ax
        push bx
        push cx
        push dx
        push di
        mov  ax, si
        mov  bx, ax
        and  bx, 1              ; bank = SI & 1
        shr  ax, 1             ; AX = SI / 2  (row within bank)
        mov  cx, 80
        mul  cx                ; AX = (SI/2)*80   (<= 7920, no overflow)
        mov  di, ax
        cmp  bx, 0
        je   .b0
        add  di, 0x2000        ; odd bank base
.b0:
        mov  al, 0xFF
        mov  cx, 80
        rep  stosb
        pop  di
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret
