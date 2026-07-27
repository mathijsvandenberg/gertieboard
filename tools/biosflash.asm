; ============================================================================
;  biosflash.asm  --  copy the RUNNING BIOS into the SPI flash (DOS .COM)
;
;  The boot ROM tries the serial loader first and falls back to a copy of the
;  BIOS held in the top 64 KB of the flash. This puts that copy there.
;
;  It writes through ordinary INT 13h calls rather than driving the SPI engine
;  directly. The first version did its own erase/program sequence and stalled on
;  the very first block; the BIOS already contains an erase/program path that is
;  verified working, so this reuses it instead of debugging a second
;  implementation of the same thing.
;
;  IT WRITES TO DRIVE B:, NOT C:.  The SPI flash used to be the fixed disk at
;  DL=0x80, and this tool was written against that. It is now the second floppy
;  at DL=0x01, and 0x80 is the USB hard disk -- so the previous version quietly
;  wrote 64 KB of BIOS image onto the USB drive and never touched the flash at
;  all. What the boot ROM then loaded was whatever stale fragment an older build
;  had left at 0x1F0000, which is exactly the "garbage with a few readable
;  strings" symptom.
;
;  Nothing about the geometry is assumed either. The old version hardcoded
;  cylinder 31 of a 31x4x32 disk; B: is reported as 80x2x18, so that cylinder is
;  a completely different place on the chip. The reserved region is derived from
;  the chip size the BIOS detected (BDA 40:E4, in KB) and the CHS for every
;  transfer is computed from the geometry INT 13h AH=08 reports, so this keeps
;  working if either changes again.
;
;      last 64 KB of a 2 MB chip = LBA 3968..4095 = flash 0x1F0000..0x1FFFFF
;
;  The BIOS advertises fewer cylinders than the chip holds so DOS can never
;  reach the reserved region, but it bounds-checks against the physical 4096
;  sectors -- so this tool can address it deliberately.
;
;  Source is the running BIOS at F000:0000 -- no filename to get wrong, and the
;  flashed copy is by construction the BIOS you just booted and tested.
;
;  Build:  nasm -f bin biosflash.asm -o biosflash.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

FLASHDRV equ 0x01               ; drive B: -- the SPI flash second floppy
ROMSEG   equ 0xF000             ; the running BIOS image
RESVKB   equ 64                 ; size of the reserved BIOS region, KB
CHUNK    equ 32                 ; sectors per INT 13h call = 16 KB
CHUNKS   equ (RESVKB*2)/CHUNK   ; 128 sectors total, in 4 calls
BUF      equ 0x4000             ; 16 KB scratch for the read-back compare

start:
        mov  dx, msg_hdr
        call puts

        ; ---- where does the reserved region start? ----
        ; From the chip size the BIOS detected, not a hardcoded cylinder.
        mov  ax, 0x40
        mov  es, ax
        mov  ax, [es:0xE4]              ; flash size in KB
        test ax, ax
        jz   .nochip
        sub  ax, RESVKB
        jc   .nochip
        shl  ax, 1                      ; KB -> 512-byte sectors
        mov  [lba], ax
        mov  [lba0], ax

        ; ---- geometry of drive B:, straight from the BIOS ----
        mov  ah, 0x08
        mov  dl, FLASHDRV
        int  0x13
        jc   .nogeo
        mov  al, cl
        and  al, 0x3F                   ; sectors per track
        mov  ah, 0
        test ax, ax
        jz   .nogeo
        mov  [spt], ax
        mov  al, dh
        mov  ah, 0
        inc  ax                         ; heads = max head + 1
        mov  [heads], ax

        mov  dx, msg_target
        call puts
        mov  ax, [lba0]
        call putdec
        mov  dx, msg_target2
        call puts

        ; ---- is the BIOS in RAM still the BIOS that booted? ----
        ; The F-segment is PSRAM, not ROM. This tool copies the RUNNING image,
        ; so anything that scribbled on it since POST would be flashed as
        ; faithfully as the real thing. POST leaves its own checksum of the
        ; code region in the BDA; recompute it and compare before writing.
        mov  ax, 0x40
        mov  es, ax
        mov  ax, [es:0xB8]
        mov  [postsum], ax
        mov  cx, [es:0xBA]
        mov  [sumlen], cx
        jcxz .nosum
        mov  ax, ROMSEG
        mov  es, ax
        mov  si, 0xC000
        xor  ax, ax
        xor  bx, bx
.sl:    mov  bl, [es:si]
        add  ax, bx
        inc  si
        loop .sl
        mov  [livesum], ax
        mov  dx, msg_sum
        call puts
        mov  ax, [postsum]
        call puthexw
        mov  dx, msg_sum2
        call puts
        mov  ax, [livesum]
        call puthexw
        mov  ax, [livesum]
        cmp  ax, [postsum]
        je   .sum_ok
        mov  dx, msg_sumbad
        call puts
        jmp  .fin
.sum_ok:
        mov  dx, msg_sumok
        call puts
.nosum:

        ; ---- write CHUNKS x CHUNK sectors ----
        mov  dx, msg_write
        call puts
        xor  bp, bp
.wr:
        mov  dx, msg_dot
        call puts
        call chs                        ; CX and DH from [lba]
        mov  ax, ROMSEG
        mov  es, ax
        push cx
        mov  bx, bp
        mov  cl, 14
        shl  bx, cl                     ; BX = chunk * 16384
        pop  cx
        mov  ax, 0x0300 | CHUNK         ; AH=03 write, AL=32 sectors
        mov  dl, FLASHDRV
        int  0x13
        jc   .wr_bad
        add  word [lba], CHUNK
        inc  bp
        cmp  bp, CHUNKS
        jb   .wr
        jmp  .verify
.wr_bad:
        mov  [rah], ah
        mov  dx, msg_wrfail
        call puts
        jmp  .fail_ah

        ; ---- read it all back and compare with the running BIOS ----
.verify:
        mov  dx, msg_verify
        call puts
        mov  ax, [lba0]
        mov  [lba], ax
        xor  bp, bp
.vf:
        call chs
        push cs
        pop  es
        mov  bx, BUF
        mov  ax, 0x0200 | CHUNK         ; AH=02 read, AL=32 sectors
        mov  dl, FLASHDRV
        int  0x13
        jc   .v_bad
        ; compare 16 KB:  BUF  vs  F000:(chunk * 16384)
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
        mov  dx, msg_dot
        call puts
        add  word [lba], CHUNK
        inc  bp
        cmp  bp, CHUNKS
        jb   .vf
        mov  dx, msg_ok
        call puts
        jmp  .fin

.v_mismatch:
        ; Say WHERE and WHAT, not just that it failed: an offset plus the two
        ; bytes distinguishes a bad write from a bad read from a wrong address.
        mov  dx, msg_vmm
        call puts
        mov  ax, di
        call puthexw
        mov  dx, msg_vmm2
        call puts
        mov  al, [es:di]
        call puthex
        mov  dx, msg_vmm3
        call puts
        mov  al, [si]
        call puthex
        mov  dx, msg_crlf
        call puts
        jmp  short .fin
.v_bad:
        mov  [rah], ah
        mov  dx, msg_rdfail
        call puts
.fail_ah:
        mov  al, [rah]
        call puthex
        mov  dx, msg_crlf
        call puts
        jmp  short .fin
.nochip:
        mov  dx, msg_nochip
        call puts
        jmp  short .fin
.nogeo:
        mov  dx, msg_nogeo
        call puts
.fin:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; chs -- CHS for [lba], returned in CX and DH ready for INT 13h.
;
;   The reserved region sits ABOVE the cylinder count AH=08 reports, so the
;   cylinder computed here is deliberately larger than the advertised maximum.
;   The BIOS bounds-checks the physical chip rather than the reported geometry,
;   so that is allowed -- and it is the entire point of a region DOS cannot see.
chs:
        push ax
        push bx
        push dx
        mov  ax, [lba]
        xor  dx, dx
        div  word [spt]                 ; ax = track, dx = sector - 1
        mov  bl, dl
        inc  bl                         ; sector, 1-based
        xor  dx, dx
        div  word [heads]               ; ax = cylinder, dx = head
        mov  bh, dl                     ; head
        mov  ch, al                     ; cylinder low 8
        mov  cl, 6
        shl  ah, cl                     ; cylinder high 2 -> bits 7:6
        mov  cl, ah
        and  cl, 0xC0
        or   cl, bl                     ; ... or'd with the sector number
        pop  dx
        mov  dh, bh
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 0x09
        int  0x21
        pop  ax
        ret

puthexw:
        push ax
        push ax
        mov  al, ah
        call puthex
        pop  ax
        call puthex
        pop  ax
        ret

puthex: push ax
        push bx
        push cx
        push dx
        mov  bl, al
        mov  cl, 4
        shr  al, cl
        call .nib
        mov  al, bl
        and  al, 0x0F
        call .nib
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret
.nib:   and  al, 0x0F
        cmp  al, 10
        jb   .n0
        add  al, 'A'-10
        jmp  short .n1
.n0:    add  al, '0'
.n1:    mov  dl, al
        mov  ah, 2
        int  0x21
        ret

putdec: push ax
        push bx
        push cx
        push dx
        xor  cx, cx
        mov  bx, 10
.d1:    xor  dx, dx
        div  bx
        push dx
        inc  cx
        test ax, ax
        jnz  .d1
.d2:    pop  ax
        add  al, '0'
        mov  dl, al
        mov  ah, 2
        int  0x21
        loop .d2
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
msg_hdr:    db 'BIOSFLASH - copy the running BIOS (F000:0000, 64 KB) into the',13,10
            db 'reserved top of the SPI flash, through drive B:.',13,10,13,10,'$'
msg_target: db 'target   : LBA $'
msg_target2: db ', 128 sectors (the last 64 KB of the chip)',13,10,'$'
msg_write:  db 'writing  $'
msg_verify: db 13,10,'verify   $'
msg_dot:    db '.$'
msg_ok:     db '  OK - the flash copy matches the running BIOS.',13,10
            db 'Stop the serial loader and reset: the boot ROM will use it.',13,10,'$'
msg_wrfail: db 13,10,'WRITE FAILED, AH = $'
msg_rdfail: db 13,10,'READ-BACK FAILED, AH = $'
msg_vmm:    db 13,10,'MISMATCH at image offset $'
msg_vmm2:   db ' : BIOS has $'
msg_vmm3:   db ', flash has $'
msg_sum:    db 'BIOS code : POST said $'
msg_sum2:   db ', RAM has $'
msg_sumok:  db '  - unchanged',13,10,'$'
msg_sumbad: db '  - CHANGED',13,10,13,10
            db 'The BIOS image in RAM is no longer the one that booted, so',13,10
            db 'flashing it now would store the damage. The F-segment is',13,10
            db 'PSRAM, not ROM, and something has written to it. Reboot and',13,10
            db 'run this before loading anything else.',13,10,'$'
msg_nochip: db 'No SPI flash was detected at POST (BDA 40:E4 is zero).',13,10,'$'
msg_nogeo:  db 'Drive B: did not report a geometry.',13,10,'$'
msg_crlf:   db 13,10,'$'

lba     dw 0
lba0    dw 0
spt     dw 18
heads   dw 2
rah     db 0
postsum dw 0
livesum dw 0
sumlen  dw 0
