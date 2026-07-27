; ============================================================================
;  usbstat.asm  --  read the USB host controller's event counters
;
;  Answers the question no amount of staring at source can: is the link losing
;  packets, or is the driver wrong? Every failure so far has looked the same
;  from DOS ("disk error"), and it has been four different causes.
;
;  Run it, do some disk work, run it again, and compare. The counters wrap at
;  256 (or 65536 for the packet totals), so differences are what matter.
;
;    usbstat            show the counters once
;    usbstat r          show them, then read 64 sectors and show them again,
;                       so the error rate per packet can be worked out
;
;  Build:  nasm -f bin usbstat.asm -o usbstat.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

U_DIAG  equ 0xEF                ; write an index, read that counter

D_FRAME equ 0
D_CRC   equ 1
D_TMO   equ 2
D_NAK   equ 3
D_STALL equ 4
D_INLO  equ 5
D_INHI  equ 6
D_OUTLO equ 7
D_OUTHI equ 8
D_NAKHI equ 9
D_TXNLO equ 10
D_TXNHI equ 11

start:
        mov  dx, msg_hdr
        call puts

        ; ---- is the USB disk even there? ----
        mov  ax, 0x40
        mov  es, ax
        cmp  byte [es:0xC1], 0
        jne  .ok
        mov  dx, msg_nodisk
        call puts
        jmp  bye
.ok:
        call snapshot
        call show

        ; ---- was a read test asked for? ----
        mov  al, [0x80]         ; PSP command tail length
        test al, al
        jz   bye
        mov  si, 0x82
        mov  cx, 0x7F
.scan:
        lodsb
        cmp  al, ' '
        je   .next
        and  al, 0xDF
        cmp  al, 'R'
        je   .dotest
        jmp  bye
.next:  loop .scan
        jmp  bye

.dotest:
        mov  dx, msg_test
        call puts
        mov  word [lba], 0
        mov  cx, 64
.rloop:
        push cx
        ; CHS for 16 heads, 63 sectors
        mov  ax, [lba]
        xor  dx, dx
        mov  bx, 63
        div  bx
        mov  cl, dl
        inc  cl
        xor  dx, dx
        mov  bx, 16
        div  bx
        mov  ch, al
        mov  dh, dl
        push ds
        pop  es                 ; ES:BX must be OUR buffer, not the BDA
        mov  bx, secbuf
        mov  ax, 0x0201
        mov  dl, 0x80
        int  0x13
        mov  [rah], ah
        pop  cx
        jc   .rerr
        mov  dl, '.'
        mov  ah, 2
        int  0x21
        inc  word [lba]
        loop .rloop
        mov  dx, msg_rok
        call puts
        jmp  short .after
.rerr:
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_rfail
        call puts
        mov  ax, [lba]
        call putdec
        mov  dx, msg_rah
        call puts
        mov  al, [rah]
        call puthex
        mov  dx, msg_crlf
        call puts
.after:
        mov  dx, msg_after
        call puts
        call delta
bye:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; snapshot -- read all counters into `cur`, copying the previous set to `prev`
snapshot:
        push ax
        push bx
        push cx
        push si
        push di
        mov  si, cur
        mov  di, prev
        mov  cx, 12
.cp:    mov  al, [si]
        mov  [di], al
        inc  si
        inc  di
        loop .cp
        xor  bx, bx
        mov  cx, 12
.rd:    mov  al, bl
        out  U_DIAG, al
        in   al, U_DIAG
        mov  di, cur
        add  di, bx
        mov  [di], al
        inc  bx
        loop .rd
        pop  di
        pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

show:
        push ax
        mov  dx, msg_crc
        call puts
        mov  al, [cur+D_CRC]
        call putdec8
        mov  dx, msg_tmo
        call puts
        mov  al, [cur+D_TMO]
        call putdec8
        mov  dx, msg_nak
        call puts
        mov  ah, [cur+D_NAKHI]
        mov  al, [cur+D_NAK]
        call putdec
        mov  dx, msg_stall
        call puts
        mov  al, [cur+D_STALL]
        call putdec8
        mov  dx, msg_pin
        call puts
        mov  ah, [cur+D_INHI]
        mov  al, [cur+D_INLO]
        call putdec
        mov  dx, msg_pout
        call puts
        mov  ah, [cur+D_OUTHI]
        mov  al, [cur+D_OUTLO]
        call putdec
        mov  dx, msg_txn
        call puts
        mov  ah, [cur+D_TXNHI]
        mov  al, [cur+D_TXNLO]
        call putdec
        mov  dx, msg_hang
        call puts
        push es
        mov  ax, 0x40
        mov  es, ax
        mov  al, [es:0xDB]
        pop  es
        call putdec8
        mov  dx, msg_crlf
        call puts
        pop  ax
        ret

; delta -- read again and print what changed
delta:
        push ax
        call snapshot
        mov  dx, msg_dhdr
        call puts
        mov  dx, msg_crc
        call puts
        mov  al, [cur+D_CRC]
        sub  al, [prev+D_CRC]
        call putdec8
        mov  dx, msg_tmo
        call puts
        mov  al, [cur+D_TMO]
        sub  al, [prev+D_TMO]
        call putdec8
        mov  dx, msg_nak
        call puts
        mov  ah, [cur+D_NAKHI]
        mov  al, [cur+D_NAK]
        mov  bh, [prev+D_NAKHI]
        mov  bl, [prev+D_NAK]
        sub  ax, bx
        call putdec
        mov  dx, msg_stall
        call puts
        mov  al, [cur+D_STALL]
        sub  al, [prev+D_STALL]
        call putdec8
        mov  dx, msg_pin
        call puts
        mov  ah, [cur+D_INHI]
        mov  al, [cur+D_INLO]
        mov  bh, [prev+D_INHI]
        mov  bl, [prev+D_INLO]
        sub  ax, bx
        call putdec
        mov  dx, msg_pout
        call puts
        mov  ah, [cur+D_OUTHI]
        mov  al, [cur+D_OUTLO]
        mov  bh, [prev+D_OUTHI]
        mov  bl, [prev+D_OUTLO]
        sub  ax, bx
        call putdec
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_read
        call puts
        pop  ax
        ret

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

putdec8:
        push ax
        xor  ah, ah
        call putdec
        pop  ax
        ret

puthex: push ax
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
msg_hdr    db 'USBSTAT - USB host controller event counters',13,10
           db '-------------------------------------------',13,10,'$'
msg_nodisk db 'No USB disk present.',13,10,'$'
msg_crc    db '  CRC/PID errors : $'
msg_tmo    db 13,10,'  timeouts       : $'
msg_nak    db 13,10,'  NAKs           : $'
msg_stall  db 13,10,'  STALLs         : $'
msg_pin    db 13,10,'  packets in     : $'
msg_pout   db 13,10,'  packets out    : $'
msg_txn    db 13,10,'  transactions   : $'
msg_hang   db 13,10,'  BUSY stalls    : $'
msg_test   db 13,10,'reading 64 sectors '
           db '$'
msg_rok    db ' ok',13,10,'$'
msg_rfail  db 'read failed at sector $'
msg_rah    db ', AH = $'
msg_after  db 13,10,'$'
msg_dhdr   db 'change during the test:',13,10,'$'
msg_read   db 13,10
           db 'CRC/PID errors against packets moved is the link error rate.',13,10
           db 'NAKs are normal - a device saying "not yet" - and are counted in',13,10
           db 'full 16 bits now. BUSY stalls is the one to watch: each is a',13,10
           db 'transaction the controller accepted but never finished, and each',13,10
           db 'used to cost half a second of spinning.',13,10,'$'
msg_crlf   db 13,10,'$'

lba     dw 0
rah     db 0
prev    times 12 db 0
cur     times 12 db 0
secbuf  times 512 db 0
