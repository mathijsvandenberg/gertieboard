; ============================================================================
;  hdtest.asm  --  exercise the INT 13h fixed disk (SPI flash) from DOS
;
;  Reads AND writes are implemented, so this exercises both. The key trick for
;  the read path: an erased flash reads 0xFF in every byte, so "all N bytes are
;  0xFF" is a real data-path check rather than a return-code check. A broken read
;  (dropped SPI byte, wrong address, stuck MISO low) shows up as something other
;  than 0xFF.
;
;  Every 0xFF test therefore has to read a region NOTHING ELSE WRITES. Cylinder
;  30 is that region: DOS allocates from the start of the partition, and the
;  write tests here use cylinder 0. Both tests that once read elsewhere -- test 2
;  from LBA 0, test 3 from the block tests 5-7 fill -- started failing as soon as
;  the disk was really used, which looked like hardware faults and was not.
;
;  Tests 6 and 7 are the valuable ones: 6 forces an eviction to prove the flush
;  reaches flash, and 7 asserts the dirty flag is clear when AH=03 returns. Tests
;  5 and 6 pass even when writes are never committed, because they force the
;  eviction themselves -- which is exactly the bug that lost an FDISK partition.
;
;  Build:  nasm -f bin hdtest.asm -o hdtest.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

HDD     equ 0x80
BUF1    equ 0x4000              ; 4 KB
BUF2    equ 0x5000              ; 4 KB

start:
        mov  dx, msg_hdr
        call puts

        ; POST deliberately leaves the fixed disk hidden from DOS (BDA 40:75 = 0)
        ; so that a blank, unpartitioned flash cannot interfere with booting. The
        ; BIOS refuses every fixed-disk call while that byte is zero, so enable it
        ; here for the duration of the test and put it back on the way out.
        push ds
        mov  ax, 0x0040
        mov  ds, ax
        mov  byte [0x75], 1
        pop  ds

        ; ---------------- geometry (AH=08) ----------------
        mov  dx, msg_geo
        call puts
        mov  ah, 0x08
        mov  dl, HDD
        int  0x13
        jc   .geo_bad
        push cx
        mov  al, ch
        inc  al
        xor  ah, ah
        call putdec
        mov  dx, msg_x
        call puts
        mov  al, dh
        inc  al
        xor  ah, ah
        call putdec
        mov  dx, msg_x
        call puts
        pop  cx
        mov  al, cl
        and  al, 0x3F
        xor  ah, ah
        call putdec
        mov  dx, msg_crlf
        call puts
        jmp  short .t1
.geo_bad:
        mov  dx, msg_fail
        call puts

        ; ---------------- 1: read LBA 0 ----------------
.t1:
        mov  dx, msg_t1
        call puts
        mov  di, BUF1
        mov  cx, 512
        call clearbuf
        mov  ax, 0x0201         ; AH=02 read, AL=1 sector
        mov  cx, 0x0001         ; C=0, S=1
        mov  dx, 0x0080         ; H=0, drive 80
        mov  bx, BUF1
        int  0x13
        jc   .t1_bad
        call pass
        jmp  short .t2
.t1_bad:
        call fail

        ; ---------------- 2: erased flash must read 0xFF ----------------
        ; Does its OWN read, of a single sector DOS never touches. It used to
        ; just inspect the buffer test 1 left behind -- but test 1 reads LBA 0,
        ; and the moment FDISK wrote a partition table there this test could
        ; never pass again. Same staleness bug as test 3 had, same fix: read
        ; somewhere the rest of the system does not write.
        ; C30/H3/S24 = LBA 3959, just below the range test 3 reads.
.t2:
        mov  dx, msg_t2
        call puts
        mov  di, BUF1
        mov  cx, 512
        call clearbuf
        mov  ax, 0x0201         ; AH=02 read, AL=1 sector
        mov  cx, 0x1E18         ; C=30, S=24
        mov  dx, 0x0380         ; H=3, drive 80
        mov  bx, BUF1
        int  0x13
        jc   .t2_bad
        mov  si, BUF1
        mov  cx, 512
        call all_ff
        jc   .t2_bad
        call pass
        jmp  short .t3
.t2_bad:
        call fail

        ; ---------------- 3: multi-sector read (8 sectors) ----------------
.t3:
        mov  dx, msg_t3
        call puts
        mov  di, BUF1
        mov  cx, 4096
        call clearbuf
        ; Read from cylinder 30, which the write tests never touch. The old
        ; version read C0/H3/S25 -- the very block tests 5-7 write to -- so it
        ; started failing the moment writes were enabled. That was the test
        ; being stale, not the disk.
        mov  ax, 0x0208         ; read 8 sectors
        mov  cx, 0x1E19         ; C=30, S=25
        mov  dx, 0x0380         ; H=3, drive 80
        mov  bx, BUF1
        int  0x13
        jc   .t3_bad
        mov  si, BUF1
        mov  cx, 4096
        call all_ff
        jc   .t3_bad
        call pass
        jmp  short .t4
.t3_bad:
        call fail

        ; ---------------- 4: repeatability ----------------
        ; the same sector read twice must give identical bytes; a dropped SPI
        ; byte would desynchronise one of the two reads
.t4:
        mov  dx, msg_t4
        call puts
        mov  ax, 0x0201
        mov  cx, 0x0002         ; C=0, S=2
        mov  dx, 0x0080
        mov  bx, BUF1
        int  0x13
        jc   .t4_bad
        mov  ax, 0x0201
        mov  cx, 0x0002
        mov  dx, 0x0080
        mov  bx, BUF2
        int  0x13
        jc   .t4_bad
        mov  cx, 512
        call cmp_buf
        jc   .t4_bad
        call pass
        jmp  short .t5
.t4_bad:
        call fail

        ; ---------------- 5: write 8 sectors, one erase block ---------------
.t5:
        mov  dx, msg_t5
        call puts
        mov  di, BUF1
        mov  al, 0xC3
        call fill8              ; walking pattern, 4 KB
        mov  ax, 0x0308         ; AH=03 write, 8 sectors
        mov  cx, 0x0019         ; C=0, S=25  (an aligned 4 KB block)
        mov  dx, 0x0380         ; H=3
        mov  bx, BUF1
        int  0x13
        jc   .t5_bad
        mov  di, BUF2
        mov  cx, 4096
        call clearbuf
        mov  ax, 0x0208         ; read them straight back
        mov  cx, 0x0019
        mov  dx, 0x0380
        mov  bx, BUF2
        int  0x13
        jc   .t5_bad
        mov  cx, 4096
        call cmp_buf
        jc   .t5_bad
        call pass
        jmp  short .t6
.t5_bad:
        call fail

        ; ---------------- 6: does the dirty block reach the flash? ----------
        ; THE important test. Read a different block to force an eviction, then
        ; re-read the first one -- which must now come back from FLASH, not RAM.
        ; If the flush is broken the data looks perfect until it is evicted and
        ; then silently reverts, which is the worst failure this design can have.
.t6:
        mov  dx, msg_t6
        call puts
        mov  ax, 0x0201         ; touch block 0, evicting the dirty one
        mov  cx, 0x0001
        mov  dx, 0x0080
        mov  bx, BUF2
        int  0x13
        jc   .t6_bad
        mov  ah, 0x00           ; and commit explicitly too
        mov  dl, HDD
        int  0x13
        mov  di, BUF2
        mov  cx, 4096
        call clearbuf
        mov  ax, 0x0208
        mov  cx, 0x0019
        mov  dx, 0x0380
        mov  bx, BUF2
        int  0x13
        jc   .t6_bad
        mov  cx, 4096
        call cmp_buf
        jc   .t6_bad
        call pass
        jmp  short .t7
.t6_bad:
        call fail

        ; ---------------- 7: a write must be COMMITTED on return ------------
        ; This is what FDISK tripped over: it wrote the partition table, never
        ; issued AH=00, and the block was still dirty in RAM at reboot, so the
        ; partition was gone. Tests 5 and 6 both passed anyway because they force
        ; an eviction themselves. So assert the contract directly: after AH=03
        ; returns, the BIOS's dirty flag (BDA 40:E8) must already be clear.
.t7:
        mov  dx, msg_t7
        call puts
        mov  di, BUF1
        mov  al, 0x77
        call fill8
        mov  ax, 0x0301         ; a single-sector write, no eviction anywhere
        mov  cx, 0x0019
        mov  dx, 0x0380
        mov  bx, BUF1
        int  0x13
        jc   .t7_bad
        push ds
        mov  ax, 0x0040
        mov  ds, ax
        mov  al, [0xE8]         ; dirty flag
        pop  ds
        test al, al
        jnz  .t7_bad            ; still dirty -> it would be lost on reboot
        call pass
        jmp  short .fin
.t7_bad:
        call fail

.fin:
        ; NB: deliberately leave BDA 40:75 alone. POST advertises the disk now,
        ; and clearing it here hid the drive again for anything run afterwards --
        ; which is why FDISK reported "no fixed disks present" after a test run.
        mov  dx, msg_done
        call puts
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
fill8:                           ; DI = start, AL = seed -> 4 KB walking pattern
        push di
        push cx
        mov  cx, 4096
.f:     mov  [di], al
        inc  di
        add  al, 0x1B
        loop .f
        pop  cx
        pop  di
        ret

clearbuf:                        ; DI = start, CX = count
        push di
        xor  al, al
.c:     mov  [di], al
        inc  di
        loop .c
        pop  di
        ret

all_ff:                          ; SI = start, CX = count -> CF set if any != FF
        push si
.a:     cmp  byte [si], 0xFF
        jne  .bad
        inc  si
        loop .a
        clc
        jmp  short .out
.bad:   stc
.out:   pop  si
        ret

cmp_buf:                         ; CX bytes, BUF1 vs BUF2 -> CF set on mismatch
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

putdec:
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

msg_hdr:  db 'gertieboard fixed disk (SPI flash) -- read/write',13,10,'$'
msg_geo:  db 'geometry C x H x S             : $'
msg_x:    db ' x $'
msg_t1:   db '1 read LBA 0                   : $'
msg_t2:   db '2 erased flash reads 0xFF      : $'
msg_t3:   db '3 multi-sector read, erased C30: $'
msg_t4:   db '4 same sector twice matches    : $'
msg_t5:   db '5 write 8 sectors + read back  : $'
msg_t6:   db '6 survives eviction (flushed)  : $'
msg_t7:   db '7 write committed on return    : $'
msg_pass: db 'PASS',13,10,'$'
msg_fail: db 'FAIL',13,10,'$'
msg_done: db 'done.',13,10,'$'
msg_crlf: db 13,10,'$'
