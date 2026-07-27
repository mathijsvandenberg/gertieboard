; ============================================================================
;  usbwipe.asm  --  zero the first sectors of the USB disk (drive C:)
;
;  A stick that arrives with GPT or non-DOS partitions cannot be repartitioned
;  by DOS FDISK: it reads the existing table, does not understand it, and
;  refuses. Zeroing the partition table makes the disk look factory-blank, and
;  FDISK is then happy.
;
;  It wipes the first 64 sectors (32 KB), which covers:
;     LBA 0        the MBR / protective MBR and its partition table
;     LBA 1        a GPT header, if the stick was partitioned that way
;     LBA 2..33    the GPT partition entry array
;     LBA 34..63   slack, plus any boot sector sitting at the start
;
;  It does NOT touch a backup GPT at the far end of the device -- that lives
;  beyond the 504 MB this BIOS can address, and DOS does not look for it.
;
;  THIS DESTROYS THE PARTITIONING ON THE ATTACHED STICK. It asks first, and
;  prints the geometry so you can see which device it found before agreeing.
;
;  Build:  nasm -f bin usbwipe.asm -o usbwipe.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

WIPE_SECTORS equ 64

start:
        mov  dx, msg_hdr
        call puts

        ; ---- is there a USB disk at all? ----
        mov  ax, 0x40
        mov  es, ax
        cmp  byte [es:0xC1], 0
        jne  .have
        mov  dx, msg_nodisk
        call puts
        jmp  bye
.have:
        ; ---- show what we are about to write to ----
        mov  dx, msg_geo
        call puts
        mov  ax, [es:0xCC]
        call putdec
        mov  dx, msg_x
        call puts
        xor  ah, ah
        mov  al, [es:0xCE]
        call putdec
        mov  dx, msg_x
        call puts
        xor  ah, ah
        mov  al, [es:0xCF]
        call putdec
        mov  dx, msg_crlf
        call puts

        mov  dx, msg_warn
        call puts
        mov  dx, msg_ask
        call puts

        ; ---- require an explicit Y ----
        mov  ah, 0x01
        int  0x21               ; read one key, echoed
        and  al, 0xDF           ; fold to upper case
        cmp  al, 'Y'
        je   .go
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_abort
        call puts
        jmp  bye
.go:
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_working
        call puts

        ; ---- zero the buffer once; it is reused for every write ----
        mov  di, secbuf
        mov  cx, 512
        xor  al, al
.clr:
        mov  [di], al
        inc  di
        loop .clr

        ; ---- write sectors 1..WIPE_SECTORS, CHS from the BIOS geometry ----
        ; LBA 0..63 is cylinder 0, head 0, sectors 1..63 then cylinder 0,
        ; head 1, sector 1 -- with 63 sectors per track that is exactly the
        ; first track plus one sector, so step through CHS rather than LBA.
        mov  word [lba], 0
.wloop:
        mov  ax, [lba]
        cmp  ax, WIPE_SECTORS
        jae  .done

        ; CHS for a 16-head, 63-sector geometry
        xor  dx, dx
        mov  bx, 63
        div  bx                 ; ax = lba/63, dx = lba mod 63
        mov  cl, dl
        inc  cl                 ; sector, 1-based
        xor  dx, dx
        mov  bx, 16
        div  bx                 ; ax = cylinder, dx = head
        mov  ch, al             ; cylinder low 8 (always 0 here)
        mov  dh, dl             ; head

        push ds                 ; ES:BX is the source; ES is still 0x40
        pop  es
        mov  bx, secbuf
        mov  ax, 0x0301         ; AH=03 write, AL=1 sector
        mov  dl, 0x80
        int  0x13
        jc   .werr

        mov  dl, '.'
        mov  ah, 2
        int  0x21
        inc  word [lba]
        jmp  .wloop

.werr:
        mov  [rah], ah
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_wfail
        call puts
        mov  ax, [lba]
        call putdec
        mov  dx, msg_ahis
        call puts
        mov  al, [rah]
        call puthex
        mov  dx, msg_crlf
        call puts
        jmp  bye

.done:
        mov  dx, msg_crlf
        call puts

        ; ---- verify: read LBA 0 back and check it really is zero ----
        mov  dx, msg_verify
        call puts
        mov  di, secbuf
        mov  cx, 512
        mov  al, 0xAA           ; poison it, so a failed read cannot look clean
.poison:
        mov  [di], al
        inc  di
        loop .poison

        push ds
        pop  es
        mov  bx, secbuf
        mov  ax, 0x0201         ; read 1 sector
        mov  cx, 0x0001         ; cyl 0, sector 1
        xor  dh, dh
        mov  dl, 0x80
        int  0x13
        jc   .vfail

        mov  si, secbuf
        mov  cx, 512
.vchk:
        lodsb
        test al, al
        jnz  .vbad
        loop .vchk
        mov  dx, msg_vok
        call puts
        mov  dx, msg_next
        call puts
        jmp  bye
.vbad:
        mov  dx, msg_vbad
        call puts
        jmp  bye
.vfail:
        mov  dx, msg_vrfail
        call puts

bye:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
puts:
        push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthex:
        push ax
        push bx
        push cx
        mov  bl, al
        mov  cl, 4
        shr  al, cl
        call .nib
        mov  al, bl
        and  al, 0x0F
        call .nib
        pop  cx
        pop  bx
        pop  ax
        ret
.nib:
        and  al, 0x0F
        cmp  al, 10
        jb   .n0
        add  al, 'A'-10
        jmp  short .n1
.n0:    add  al, '0'
.n1:    mov  dl, al
        mov  ah, 2
        int  0x21
        ret

putdec:
        push ax
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
msg_hdr    db 'USBWIPE - clear the partition table on drive C:',13,10
           db '----------------------------------------------',13,10,'$'
msg_nodisk db 'No USB disk was found at POST, so there is nothing to wipe.',13,10,'$'
msg_geo    db 'target : USB disk, geometry $'
msg_warn   db 13,10
           db 'This zeroes the first 64 sectors of that device: the partition',13,10
           db 'table, and a GPT header and entries if it has them. Everything',13,10
           db 'on the stick becomes unreachable. It cannot be undone.',13,10,13,10,'$'
msg_ask    db 'Type Y to wipe, anything else to abort : $'
msg_abort  db 'Aborted. Nothing was written.',13,10,'$'
msg_working db 'writing $'
msg_wfail  db 'Write failed at sector $'
msg_ahis   db ', AH = $'
msg_verify db 'verifying LBA 0 reads back as zeros : $'
msg_vok    db 'OK',13,10,'$'
msg_vbad   db 'FAILED - the sector is not zero',13,10,'$'
msg_vrfail db 'FAILED - could not read it back',13,10,'$'
msg_next   db 13,10
           db 'Done. Reboot, then run FDISK to create a DOS partition and',13,10
           db 'FORMAT C: to put a filesystem on it.',13,10,'$'
msg_crlf   db 13,10,'$'
msg_x      db ' x $'

lba     dw 0
rah     db 0
secbuf  times 512 db 0
