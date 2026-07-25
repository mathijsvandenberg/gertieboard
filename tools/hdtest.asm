; ============================================================================
;  hdtest.asm  --  exercise the INT 13h fixed disk (SPI flash) from DOS
;
;  The disk uses a single 4 KB write-back block buffer, because the flash can
;  only be erased 4 KB at a time. The interesting failure modes are therefore
;  NOT "does one sector round-trip" but:
;
;    * do 8 sectors in the SAME 4 KB block survive one erase cycle, and
;    * does touching a DIFFERENT block actually flush the dirty one to flash
;      (if the flush is broken, data appears fine until it is evicted, then
;       silently reverts -- the nastiest possible bug)
;
;  Test 4 is the one that catches that: write a block, force an eviction by
;  reading elsewhere, then read the first block back FROM FLASH and compare.
;
;  It works on cylinder 31 / head 3 (the last 4 KB block of the 2 MB device),
;  well away from anything a boot sector or file system would use.
;
;  Build:  nasm -f bin hdtest.asm -o hdtest.com
; ============================================================================

        org  0x100
        bits 16

HDD     equ 0x80                ; first fixed disk
TCYL    equ 31                  ; test block: last cylinder
THEAD   equ 3
TSEC    equ 25                  ; sectors 25..32 = one aligned 4 KB block
BUF1    equ 0x4000              ; 4 KB scratch (write pattern)
BUF2    equ 0x5000              ; 4 KB scratch (read back)

start:
        mov  dx, msg_hdr
        call puts

        ; ---------------- geometry (AH=08) ----------------
        mov  ah, 0x08
        mov  dl, HDD
        int  0x13
        jc   .geo_fail
        push cx
        push dx
        mov  dx, msg_geo
        call puts
        pop  dx
        pop  cx
        push cx
        push dx
        mov  al, ch             ; max cylinder (low 8 bits)
        inc  al
        mov  ah, 0
        call putdec
        mov  dx, msg_x
        call puts
        pop  dx
        push dx
        mov  al, dh             ; max head
        inc  al
        mov  ah, 0
        call putdec
        mov  dx, msg_x
        call puts
        pop  dx
        pop  cx
        mov  al, cl
        and  al, 0x3F           ; sectors per track
        mov  ah, 0
        call putdec
        mov  dx, msg_crlf
        call puts
        jmp  short .t1
.geo_fail:
        mov  dx, msg_geoerr
        call puts

        ; ---------------- 1: single sector round-trip ----------------
.t1:
        mov  dx, msg_t1
        call puts
        mov  di, BUF1
        mov  al, 0x5A
        call fill1              ; one sector of a walking pattern
        mov  al, 1
        mov  bx, BUF1
        call wr_sectors
        jc   .t1_bad
        mov  di, BUF2
        call clear1
        mov  al, 1
        mov  bx, BUF2
        call rd_sectors
        jc   .t1_bad
        mov  cx, 512
        call cmp_buf
        jc   .t1_bad
        call pass
        jmp  short .t2
.t1_bad:
        call fail

        ; ---------------- 2: 8 sectors, one erase block ----------------
.t2:
        mov  dx, msg_t2
        call puts
        mov  di, BUF1
        mov  al, 0xC3
        call fill8
        mov  al, 8
        mov  bx, BUF1
        call wr_sectors
        jc   .t2_bad
        mov  di, BUF2
        call clear8
        mov  al, 8
        mov  bx, BUF2
        call rd_sectors
        jc   .t2_bad
        mov  cx, 4096
        call cmp_buf
        jc   .t2_bad
        call pass
        jmp  short .t3
.t2_bad:
        call fail

        ; ---------------- 3: read a different block (forces eviction) ------
.t3:
        mov  dx, msg_t3
        call puts
        mov  ax, 0x0201         ; read 1 sector, LBA 0 = C0 H0 S1
        mov  cx, 0x0001
        mov  dx, 0x0080
        mov  bx, BUF2
        int  0x13
        jc   .t3_bad
        call pass
        jmp  short .t4
.t3_bad:
        call fail

        ; ---------------- 4: did the dirty block reach the flash? ---------
.t4:
        mov  dx, msg_t4
        call puts
        mov  di, BUF2
        call clear8
        mov  al, 8
        mov  bx, BUF2
        call rd_sectors         ; must come back from FLASH now, not RAM
        jc   .t4_bad
        mov  cx, 4096
        call cmp_buf
        jc   .t4_bad
        call pass
        jmp  short .fin
.t4_bad:
        call fail

.fin:
        mov  ah, 0x00           ; reset = commit anything still dirty
        mov  dl, HDD
        int  0x13
        mov  dx, msg_done
        call puts
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; wr_sectors / rd_sectors: AL = count, BX = offset in our segment
; ---------------------------------------------------------------------------
wr_sectors:
        mov  ah, 0x03
        jmp  short do_int13
rd_sectors:
        mov  ah, 0x02
do_int13:
        mov  ch, TCYL
        mov  cl, TSEC
        mov  dh, THEAD
        mov  dl, HDD
        int  0x13
        ret

; fill1/fill8: walking pattern seeded from AL into ES:DI
fill1:  mov  cx, 512
        jmp  short fill_do
fill8:  mov  cx, 4096
fill_do:
        push di
.f:     mov  [di], al
        inc  di
        add  al, 0x1B
        loop .f
        pop  di
        ret

clear1: mov  cx, 512
        jmp  short clr_do
clear8: mov  cx, 4096
clr_do:
        push di
        xor  al, al
.c:     mov  [di], al
        inc  di
        loop .c
        pop  di
        ret

; cmp_buf: CX bytes, BUF1 vs BUF2 -> CF set on mismatch
cmp_buf:
        push si
        push di
        mov  si, BUF1
        mov  di, BUF2
.cb:    mov  al, [si]
        cmp  al, [di]
        jne  .bad
        inc  si
        inc  di
        loop .cb
        clc
        jmp  short .out
.bad:   stc
.out:   pop  di
        pop  si
        ret

pass:   push dx
        mov  dx, msg_pass
        call puts
        pop  dx
        ret
fail:   push dx
        mov  dx, msg_fail
        call puts
        pop  dx
        ret

puts:   push ax
        mov  ah, 0x09
        int  0x21
        pop  ax
        ret

putdec:                          ; AX unsigned -> decimal
        push ax
        push bx
        push cx
        push dx
        xor  cx, cx
        mov  bx, 10
.dv:    xor  dx, dx
        div  bx
        push dx
        inc  cx
        test ax, ax
        jnz  .dv
.pr:    pop  dx
        add  dl, '0'
        mov  ah, 0x02
        int  0x21
        loop .pr
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

msg_hdr:    db 'gertieboard fixed-disk (SPI flash) test',13,10
            db 'testing C',13,10,'$'
msg_geo:    db 'geometry (C x H x S): $'
msg_geoerr: db 'AH=08 failed',13,10,'$'
msg_x:      db ' x $'
msg_t1:     db '1 single sector round-trip     : $'
msg_t2:     db '2 eight sectors, one 4K block  : $'
msg_t3:     db '3 read other block (evict)     : $'
msg_t4:     db '4 re-read after eviction       : $'
msg_pass:   db 'PASS',13,10,'$'
msg_fail:   db 'FAIL',13,10,'$'
msg_done:   db 'done.',13,10,'$'
msg_crlf:   db 13,10,'$'
