; ============================================================================
;  egavfy.asm  --  is the picture wrong, or is the MEMORY wrong?
;
;  The EGA planes now live in SDRAM behind a scanline buffer, and the picture
;  comes back structurally correct with speckle scattered through it. That
;  speckle does not move, and it is there with the CPU completely idle -- so
;  the display reads the same wrong pixels every frame. Two things can do that
;  and they need opposite fixes:
;
;      the CPU WROTE the wrong thing, and memory faithfully holds it
;      the CPU wrote correctly and the PREFETCH reads the wrong thing
;
;  Nothing on the screen can tell those apart, because both end as wrong
;  pixels in the right places.
;
;  So this writes a known pattern through the EGA path -- the graphics
;  controller, the map mask, ega_mem, the arbiter, the whole write chain --
;  and then reads it back through the DIAGNOSTIC WINDOW at 0x300, which
;  reaches the SDRAM without touching the display path at all.
;
;      pattern matches  ->  the write path is sound and the fault is the
;                           prefetch, the line buffer or the scan
;      pattern differs  ->  the write path is corrupting, and the display is
;                           innocently showing what is really there
;
;  THE LAYOUT BEING CHECKED. ega_mem interleaves the planes so one pixel
;  offset is two consecutive SDRAM words:
;
;      word (offset*2 + 0) = plane 1 : plane 0
;      word (offset*2 + 1) = plane 3 : plane 2
;
;  Writing byte B to all four planes must therefore leave BOTH words holding
;  B in each half -- B * 0x0101. A mismatch in one half only says which pair
;  of planes went astray; a mismatch at the wrong OFFSET says the address
;  arithmetic is wrong rather than the data.
;
;  NOTHING IS PRINTED WHILE THE SCREEN IS IN GRAPHICS MODE. The first version
;  did, and every message went through the BIOS glyph renderer into the EGA
;  planes -- scribbled over the pattern it was measuring, or invisible. Results
;  are collected into a buffer and printed after the mode is back.
;
;  AND THE PHASE GOES TO THE 7-SEGMENT at port 0x80, because the first version
;  hung and the screen could not say where:
;
;      1  writing the pattern through the EGA path      (write mode 0)
;      2  reading it back through the 0x300 window
;      4  writing again in write mode 2
;      5  reading that back through the 0x300 window
;      6  writing again for the CPU read test
;      7  reading back THROUGH THE CPU, all four planes
;      3  back in text mode, printing
;
;  A display stuck on 2 or 5 means the window stopped answering while the
;  prefetch was running, which is an arbitration problem and not a memory one.
;  A display stuck on 7 means a CPU read of EGA memory never completed -- the
;  READY handshake, not the data.
;
;  MISMATCH TAGS in the "word" column:
;      00, 01   pass 1, the two SDRAM words of an offset (write mode 0)
;      02       pass 2 (write mode 2)
;      10..13   pass 3, a CPU read of plane 0..3
;
;  Build:  nasm -f bin egavfy.asm -o egavfy.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

P_AL    equ 0x300               ; SDRAM window: address 7:0 (WORD address)
P_AM    equ 0x301
P_AH    equ 0x302
P_DL    equ 0x303
P_DH    equ 0x304
P_CMD   equ 0x305

; THE WHOLE PLANE, NOT THE FIRST PAGE. This was 8000 -- one 320x200 screen --
; which was the whole of a plane back when a plane was 16 KB and the CPU window
; folded into it. A plane is 64 KB now and Keen 4 uses all of it: three display
; pages at 0, 16640 and 33280, and the off-screen latch area above those. Every
; offset past 7999 was therefore UNTESTED by the tool whose entire job is to say
; whether the write path is sound -- so it certified a quarter of the memory and
; reported CLEAN.
;
; 0 means 65536: LOOP takes CX = 0 as a full turn, and the verify loops end when
; SI wraps back to zero rather than by comparing against a count that no longer
; fits in the register.
NOFFS   equ 0                   ; one full 64 KB plane, in pixel offsets
EGABASE equ 0xA000

start:
        mov  dx, msg_hdr
        call puts

        mov  dx, P_CMD
        in   al, dx
        test al, 0x04
        jnz  .alive
        mov  dx, msg_nowin
        call puts
        jmp  bad_exit
.alive:

; ---------------------------------------------------------------------------
;  Mode 0Dh, and a write path with nothing clever in it.
;
;  Write mode 0, set/reset disabled, function replace, bit mask all bits, map
;  mask all four planes: the CPU byte goes to every plane untouched. If even
;  THIS is corrupted then no amount of latch or bit-mask logic is involved.
; ---------------------------------------------------------------------------
        mov  ax, 0x0000
        call gcout                      ; GC 0 set/reset
        mov  ax, 0x0100
        call gcout                      ; GC 1 enable set/reset = off
        mov  ax, 0x0300
        call gcout                      ; GC 3 rotate 0, replace
        mov  ax, 0x0500
        call gcout                      ; GC 5 write mode 0
        mov  ax, 0x08FF
        call gcout                      ; GC 8 bit mask = every bit
        mov  ax, 0x020F
        call seqout                     ; SEQ 2 map mask = all four planes
        mov  ax, 0x0605
        call gcout                      ; GC 6 graphics at 0xA0000 -- switches

        mov  al, 1
        out  0x80, al                   ; phase 1: writing

        mov  ax, EGABASE
        mov  es, ax
        xor  di, di
        mov  cx, NOFFS
        xor  si, si                     ; offset
.wr:    mov  ax, si
        call patt                       ; AL = the byte for this offset
        mov  [es:di], al
        inc  di
        inc  si
        loop .wr

        mov  al, 2
        out  0x80, al                   ; phase 2: verifying

; ---------------------------------------------------------------------------
;  Read it back the other way round. Mismatches go in a buffer -- printing
;  here would draw into the very planes being measured.
; ---------------------------------------------------------------------------
        xor  si, si                     ; offset
        mov  word [nbad], 0
.vf:    mov  ax, si
        call patt
        mov  bl, al                     ; BL = expected byte
        mov  bh, al
        mov  [wexp], bx                 ; expected word = B:B

        ; word (offset*2)
        mov  ax, si
        shl  ax, 1
        mov  dx, 0
        rcl  dx, 1                      ; carry out of the shift -> bit 16
        call setaddr
        call rd16
        cmp  ax, [wexp]
        je   .lo_ok
        mov  bp, 0                      ; which word disagreed
        call report
        jmp  .next
.lo_ok:
        ; word (offset*2 + 1)
        mov  ax, si
        shl  ax, 1
        mov  dx, 0
        rcl  dx, 1
        inc  ax
        adc  dx, 0
        call setaddr
        call rd16
        cmp  ax, [wexp]
        je   .next
        mov  bp, 1
        call report
.next:
        inc  si
        or   si, si                     ; wrapped to 0 = all 65536 swept
        jz   .done
        cmp  word [nbad], 8
        jb   .vf                        ; stop after eight; a pattern is enough
.done:
        ; ---- pass 2: WRITE MODE 2 -------------------------------------
        ; Pass 1 used write mode 0 with every bit unmasked -- the simplest path
        ; there is. EGATEST's colour bars and every line AGI draws use write
        ; mode 2, where the CPU byte's low nibble is a COLOUR and each plane
        ; gets 0x00 or 0xFF from one bit of it. Proving the plain path and
        ; leaving the one actually in use untested would be the wrong half.
        mov  al, 4
        out  0x80, al                   ; phase 4: writing, mode 2
        mov  ax, 0x0502
        call gcout                      ; GC 5 = write mode 2
        xor  di, di
        mov  cx, NOFFS
        xor  si, si
.w2:    mov  ax, si
        and  al, 0x0F                   ; colour = offset mod 16
        mov  [es:di], al
        inc  di
        inc  si
        loop .w2

        mov  al, 5
        out  0x80, al                   ; phase 5: verifying mode 2
        xor  si, si
.v2:    mov  ax, si
        and  al, 0x0F
        call expand2                    ; -> [wexp] = the planes 1:0 word
        mov  ax, si
        shl  ax, 1
        mov  dx, 0
        rcl  dx, 1
        call setaddr
        call rd16
        cmp  ax, [wexp]
        je   .v2n
        mov  bp, 2                      ; word 02 marks a mode-2 mismatch
        call report
.v2n:   inc  si
        or   si, si                     ; wrapped to 0 = all 65536 swept
        jz   .v2d
        cmp  word [nbad], 8
        jb   .v2
.v2d:
; ---------------------------------------------------------------------------
;  pass 3: THE CPU READ PATH, which nothing above has touched.
;
;  Passes 1 and 2 read back through the 0x300 window ON PURPOSE -- it reaches
;  the SDRAM without the display path, which is what makes them able to blame
;  the write path or clear it. But it also means they never exercise the way
;  the CPU ITSELF reads EGA memory: EM_RDATA -> ega_rd32 -> the read-map-select
;  mux, gated by the EGA_CLAIM/EGA_RDY handshake that makes the processor wait.
;
;  That path is not decoration. Every latch load Keen 4's blitter performs is a
;  CPU read of EGA memory, and a read that returns rubbish -- or one whose READY
;  never arrives, so busdecode's backstop releases the CPU onto a bus nobody is
;  driving -- puts that rubbish in a register and then wherever the program
;  keeps it. Both passes above can be CLEAN while this one is not.
;
;  All four planes, because read map select is part of the path being tested.
;  Tag 0x10..0x13 = a CPU read of plane 0..3.
; ---------------------------------------------------------------------------
        mov  al, 6
        out  0x80, al                   ; phase 6: rewriting for the read test
        mov  ax, 0x0500
        call gcout                      ; GC 5 back to write mode 0
        mov  ax, 0x08FF
        call gcout                      ; GC 8 bit mask = every bit
        mov  ax, 0x020F
        call seqout                     ; SEQ 2 map mask = all four planes
        xor  di, di
        mov  cx, NOFFS
        xor  si, si
.w3:    mov  ax, si
        call patt
        mov  [es:di], al
        inc  di
        inc  si
        loop .w3

        mov  al, 7
        out  0x80, al                   ; phase 7: reading back through the CPU
        mov  word [curpl], 0
.p3:    mov  al, [curpl]
        mov  ah, 4
        call gcout                      ; GC 4 read map select = this plane
        xor  di, di
        xor  si, si
.r3:    mov  ax, si
        call patt                       ; AL = the byte that must come back
        mov  bl, al
        mov  ah, al
        mov  [wexp], ax                 ; expected, in both halves, for report
        mov  al, [es:di]                ; THE READ UNDER TEST
        cmp  al, bl
        je   .r3n
        mov  ah, 0                      ; AX = what actually came back
        mov  bp, [curpl]
        add  bp, 0x10
        call report
.r3n:   inc  di
        inc  si
        or   si, si                     ; wrapped to 0 = all 65536 swept
        jz   .p3n
        cmp  word [nbad], 8
        jb   .r3
        jmp  .p3d                        ; eight is already a pattern
.p3n:   inc  word [curpl]
        cmp  word [curpl], 4
        jb   .p3
.p3d:

        mov  al, 3
        out  0x80, al                   ; phase 3: text mode and results
        call textmode

        mov  cx, [nbad]
        or   cx, cx
        jz   .clean
        cmp  cx, 8
        jbe  .show
        mov  cx, 8
.show:  mov  si, badbuf
.sl:    push cx
        mov  dx, msg_at
        call puts
        mov  ax, [si]
        call puthex16
        mov  dx, msg_word
        call puts
        mov  ax, [si+2]
        call puthex8
        mov  dx, msg_exp
        call puts
        mov  ax, [si+4]
        call puthex16
        mov  dx, msg_got
        call puts
        mov  ax, [si+6]
        call puthex16
        mov  dx, msg_crlf
        call puts
        add  si, 8
        pop  cx
        loop .sl
        mov  dx, msg_dirty
        call puts
        mov  ax, 0x4C01
        int  0x21
.clean:
        mov  dx, msg_clean
        call puts
        mov  ax, 0x4C00
        int  0x21

bad_exit:
        call textmode
        mov  dx, msg_dirty
        call puts
        mov  ax, 0x4C01
        int  0x21

; ---------------------------------------------------------------------------
; expand2 -- AL = colour 0..15 -> [wexp] = the planes 1:0 word that write
; mode 2 must have produced: plane 0 is 0xFF when bit 0 of the colour is set,
; plane 1 from bit 1, and the word is plane1:plane0.
expand2:
        push ax
        push bx
        xor  bx, bx
        test al, 0x01
        jz   .p0
        mov  bl, 0xFF
.p0:    test al, 0x02
        jz   .p1
        mov  bh, 0xFF
.p1:    mov  [wexp], bx
        pop  bx
        pop  ax
        ret

; patt -- AX = offset, returns AL = the byte to store there.
; Both halves of the offset take part, so a wrong ADDRESS shows up as a wrong
; VALUE rather than as a coincidence.
patt:
        push cx
        mov  cl, ah
        xor  al, cl
        add  al, 0x5A
        pop  cx
        ret

; setaddr -- AX = word address 15:0, DX = 23:16
setaddr:
        push ax
        push dx
        mov  dx, P_AL
        out  dx, al
        pop  dx
        push dx
        mov  al, ah
        mov  dx, P_AM
        out  dx, al
        pop  dx
        mov  al, dl
        mov  dx, P_AH
        out  dx, al
        pop  ax
        ret

; rd16 -- AX = the word at the current address
rd16:
        push dx
        push bx
        mov  al, 1
        mov  dx, P_CMD
        out  dx, al
        call waitdone
        mov  dx, P_DL
        in   al, dx
        mov  bl, al
        mov  dx, P_DH
        in   al, dx
        mov  ah, al
        mov  al, bl
        pop  bx
        pop  dx
        ret

waitdone:
        push ax
        push cx
        push dx
        xor  cx, cx
        mov  dx, P_CMD
.w:     in   al, dx
        test al, 0x01
        jz   .d
        loop .w
.d:     pop  dx
        pop  cx
        pop  ax
        ret

; report -- SI = offset, AX = read, BP = which word. STORES, does not print:
; the screen is in graphics mode and anything drawn here lands in the planes
; under test. Through memory rather than the stack, because a mis-ordered push
; in the routine that records failures is a particularly unhelpful bug.
report:
        push ax
        push bx
        mov  [rgot], ax
        mov  bx, [nbad]
        cmp  bx, 8
        jae  .full
        shl  bx, 1
        shl  bx, 1
        shl  bx, 1                      ; 8 bytes per entry
        add  bx, badbuf
        mov  ax, si
        mov  [bx], ax                   ; offset
        mov  ax, bp
        mov  [bx+2], ax                 ; which of the two words
        mov  ax, [wexp]
        mov  [bx+4], ax                 ; expected
        mov  ax, [rgot]
        mov  [bx+6], ax                 ; read
.full:  inc  word [nbad]
        pop  bx
        pop  ax
        ret

seqout:
        push dx
        push ax
        mov  dx, 0x3C4
        mov  al, ah
        out  dx, al
        pop  ax
        mov  dx, 0x3C5
        out  dx, al
        pop  dx
        ret

gcout:
        push dx
        push ax
        mov  dx, 0x3CE
        mov  al, ah
        out  dx, al
        pop  ax
        mov  dx, 0x3CF
        out  dx, al
        pop  dx
        ret

textmode:
        mov  ax, 0x060E         ; GC 6 back to alphanumeric BEFORE the mode set
        call gcout
        mov  ax, 0x0003
        int  0x10
        ret

puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthex16:
        push ax
        mov  al, ah
        call puthex8
        pop  ax
        call puthex8
        ret

puthex8:
        push ax
        push cx
        mov  cl, al
        shr  al, 1
        shr  al, 1
        shr  al, 1
        shr  al, 1
        call .nib
        mov  al, cl
        call .nib
        pop  cx
        pop  ax
        ret
.nib:   and  al, 0x0F
        add  al, '0'
        cmp  al, '9'
        jbe  .p
        add  al, 7
.p:     push ax
        push dx
        mov  dl, al
        mov  ah, 2
        int  0x21
        pop  dx
        pop  ax
        ret

; ---------------------------------------------------------------------------
curpl   dw 0
nbad    dw 0
wexp    dw 0
rgot    dw 0
badbuf  times 8*8 db 0

msg_hdr db 'EGAVFY - is the picture wrong, or the memory?',13,10
        db '---------------------------------------------',13,10
        db 'Writes a known pattern through the EGA write path, then reads it',13,10
        db 'back through the 0x300 window, which reaches the SDRAM without',13,10
        db 'going near the display.',13,10,13,10
        db '  matches  -> the write path is sound; the fault is the prefetch,',13,10
        db '              the line buffer or the scan',13,10
        db '  differs  -> the write path is corrupting, and the display is',13,10
        db '              honestly showing what is really stored',13,10,13,10,'$'
msg_nowin db 'The 0x300 window did not answer, so there is nothing to compare',13,10
        db 'against. Check the bitstream.',13,10,'$'
msg_write db 'writing 65536 offsets through the EGA path ... $'
msg_read  db 'done',13,10,'verifying through the SDRAM window ...',13,10,'$'
msg_at    db '  offset $'
msg_word  db '  word $'
msg_exp   db '  expected $'
msg_got   db '  read $'
msg_crlf  db 13,10,'$'
msg_clean:
        db 13,10,'CLEAN. Every one of 65536 offsets holds exactly what was',13,10
        db 'written, in both words. The EGA write path, the address',13,10
        db 'arithmetic and the SDRAM are all sound -- so the speckle is',13,10
        db 'downstream: the prefetch, the line buffer, or the scan.',13,10,13,10
        db 'word 00/01 = pass 1 (write mode 0); word 02 = pass 2 (mode 2).',13,10,'$'
msg_dirty:
        db 13,10,'MISMATCHES. The memory does not hold what was written, so the',13,10
        db 'display is innocent. If the offsets look random the write path is',13,10
        db 'dropping or corrupting data; if they are regular, the address',13,10
        db 'arithmetic in ega_mem is wrong.',13,10,'$'
