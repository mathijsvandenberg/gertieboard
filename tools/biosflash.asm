; ============================================================================
;  biosflash.asm  --  copy the RUNNING BIOS into the SPI flash (DOS .COM)
;
;  The boot ROM tries the serial loader first and falls back to a copy of the
;  BIOS held in the top 64 KB of the flash. This puts that copy there.
;
;  It writes through ordinary INT 13h calls rather than driving the SPI engine
;  directly. The first version did its own erase/program sequence and stalled on
;  the very first block; the BIOS already contains an erase/program path that is
;  verified working (HDTEST 5, 6 and 7), so this reuses it instead of debugging a
;  second implementation of the same thing.
;
;  The last cylinder is exactly the reserved region:
;      C31 H0 S1 = LBA 3968 = flash 0x1F0000, and 128 sectors = 64 KB.
;  The BIOS reports 31 cylinders so DOS never goes there, but bounds-checks
;  against the physical 4096 sectors, so this tool can.
;
;  Source is the running BIOS at F000:0000 -- no filename to get wrong, and the
;  flashed copy is by construction the BIOS you just booted and tested.
;
;  Build:  nasm -f bin biosflash.asm -o biosflash.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

HDD     equ 0x80
ROMSEG  equ 0xF000              ; the running BIOS image
BIOSCYL equ 31                  ; last cylinder = flash 0x1F0000..0x1FFFFF
BUF     equ 0x2000              ; 16 KB scratch for read-back verify

start:
        mov  dx, msg_hdr
        call puts

        ; ---- write 4 x 32 sectors: one head at a time, 16 KB per call ----
        xor  bp, bp                     ; BP = head 0..3
.wr:
        mov  dx, msg_dot
        call puts
        mov  ax, ROMSEG
        mov  es, ax
        mov  bx, bp
        mov  cl, 14
        shl  bx, cl                     ; BX = head * 16384
        mov  ax, 0x0320                 ; AH=03 write, AL=32 sectors
        mov  cx, (BIOSCYL << 8) | 1     ; CH=cylinder, CL=sector 1
        mov  dx, bp                     ; DL = head 0..3
        mov  dh, dl                     ; -> DH = head
        mov  dl, HDD
        int  0x13
        jc   .wr_bad
        inc  bp
        cmp  bp, 4
        jb   .wr
        jmp  short .verify
.wr_bad:
        mov  dx, msg_wrfail
        call puts
        jmp  short .fin

        ; ---- read it all back and compare with the running BIOS ----
.verify:
        mov  dx, msg_verify
        call puts
        xor  bp, bp
.vf:
        push cs
        pop  es
        mov  bx, BUF
        mov  ax, 0x0220                 ; AH=02 read, AL=32 sectors
        mov  cx, (BIOSCYL << 8) | 1
        mov  dx, bp
        mov  dh, dl
        mov  dl, HDD
        int  0x13
        jc   .v_bad
        ; compare 16 KB: BUF  vs  F000:(head*16384)
        push ds
        mov  si, BUF
        mov  ax, bp
        mov  cl, 14
        shl  ax, cl
        mov  di, ax
        mov  ax, ROMSEG
        mov  es, ax                     ; ES:DI = the running BIOS
        mov  cx, 0x4000
.vc:    mov  al, [si]
        cmp  al, [es:di]
        jne  .v_mismatch
        inc  si
        inc  di
        loop .vc
        pop  ds
        mov  dx, msg_dot
        call puts
        inc  bp
        cmp  bp, 4
        jb   .vf
        mov  dx, msg_ok
        call puts
        jmp  short .fin
.v_mismatch:
        pop  ds
.v_bad:
        mov  dx, msg_bad
        call puts
.fin:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 0x09
        int  0x21
        pop  ax
        ret

msg_hdr:    db 'biosflash -- copying the running BIOS (F000:0000, 64 KB) into',13,10
            db 'the last cylinder of the fixed disk = flash 0x1F0000, via INT 13h.',13,10
            db 'writing: $'
msg_dot:    db '.$'
msg_verify: db 13,10,'verifying: $'
msg_wrfail: db 13,10,'WRITE FAILED -- INT 13h returned an error.',13,10,'$'
msg_ok:     db 13,10,'OK -- flash copy matches the running BIOS.',13,10
            db 'Stop the loader and reset: POST should show A then B.',13,10,'$'
msg_bad:    db 13,10,'MISMATCH -- do NOT rely on the flash copy.',13,10,'$'
