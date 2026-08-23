; ============================================================================
;  b13.asm -- call INT 13h on drive B: directly and report what the BIOS says
;
;  DOS reports "General Failure" for anything it cannot classify, which hides
;  the BIOS return code completely. It also calls more than one function before
;  it will touch a drive -- get parameters, get type, check the change line --
;  and a wrong answer to ANY of them produces the same useless message.
;
;  So this asks each one separately and prints the raw answer. It talks to
;  INT 13h, not to the device, so it isolates exactly the layer between the
;  working transport (which USBFDD exercises) and DOS.
;
;  Usage:  B13 [drive]     drive 0 = A:, 1 = B: (default), 0x80 = C:
; ============================================================================

        CPU 8086
        org  0x100

start:
        mov  dx, msg_hdr
        call puts

        mov  byte [drive], 1
        mov  al, [0x80]
        cmp  al, 2
        jb   .go
        mov  al, [0x82]
        cmp  al, '0'
        jne  .n0
        mov  byte [drive], 0
.n0:
        cmp  al, 'c'
        je   .isc
        cmp  al, 'C'
        jne  .go
.isc:
        mov  byte [drive], 0x80
.go:
        mov  dx, msg_drv
        call puts
        mov  al, [drive]
        call puthex
        mov  dx, msg_crlf
        call puts

; ---- AH=15h: what kind of drive does the BIOS say this is? -----------------
        mov  dx, msg_t15
        call puts
        mov  ah, 0x15
        mov  dl, [drive]
        int  0x13
        call report
        ; AH is the type here on success: 1 = no change line, 2 = with one
        mov  dx, msg_type
        call puts
        mov  al, [lastah]
        call puthex
        mov  dx, msg_crlf
        call puts

; ---- AH=08h: geometry ------------------------------------------------------
        mov  dx, msg_t08
        call puts
        push es
        mov  ah, 0x08
        mov  dl, [drive]
        xor  di, di
        mov  es, di
        int  0x13
        mov  [r_cx], cx
        mov  [r_dx], dx
        mov  [r_bl], bl
        pop  es
        call report
        mov  dx, msg_geom
        call puts
        mov  ax, [r_cx]
        call puthex16
        mov  dl, ' '
        mov  ah, 2
        int  0x21
        mov  ax, [r_dx]
        call puthex16
        mov  dx, msg_bl
        call puts
        mov  al, [r_bl]
        call puthex
        mov  dx, msg_crlf
        call puts

; ---- AH=16h: has the medium changed? ---------------------------------------
        mov  dx, msg_t16
        call puts
        mov  ah, 0x16
        mov  dl, [drive]
        int  0x13
        call report

; ---- AH=00h: reset ---------------------------------------------------------
        mov  dx, msg_t00
        call puts
        mov  ah, 0x00
        mov  dl, [drive]
        int  0x13
        call report

; ---- AH=FEh: the BIOS's own view, which no error code carries --------------
; Vendor-specific and DOS never calls it. AH=20 from a read only says the sense
; held nothing, which is the absence of evidence rather than any.
        call fediag
        ; CAPTURE DX FIRST. DL is the diagnostic byte, and every "mov dx,
        ; msg_*" below destroys it -- so the enum value printed was the low
        ; byte of a string address, not the BIOS's answer. BX and CX survive
        ; because puthex saves CX and nothing here touches BX.
        mov  [r_dx], dx
; ---- AH=02h: read cylinder 0, head 0, sector 1 -----------------------------
        mov  dx, msg_t02
        call puts
        mov  ax, 0x0201                 ; read 1 sector
        mov  cx, 0x0001                 ; cyl 0, sector 1
        mov  dh, 0
        mov  dl, [drive]
        mov  bx, secbuf
        push cs
        pop  es
        int  0x13
        call report
        jc   .noread

        ; The BPB is the thing DOS reads next, so show what it would see.
        mov  dx, msg_bps
        call puts
        mov  ax, [secbuf+0x0B]
        call puthex16
        mov  dx, msg_spt
        call puts
        mov  ax, [secbuf+0x18]
        call puthex16
        mov  dx, msg_hds
        call puts
        mov  ax, [secbuf+0x1A]
        call puthex16
        mov  dx, msg_tot
        call puts
        mov  ax, [secbuf+0x13]
        call puthex16
        mov  dx, msg_med
        call puts
        mov  al, [secbuf+0x15]
        call puthex
        mov  dx, msg_sig
        call puts
        mov  al, [secbuf+511]
        call puthex
        mov  al, [secbuf+510]
        call puthex
        mov  dx, msg_crlf
        call puts
.noread:
        ; AGAIN, now that the read has failed. The first call ran BEFORE it and
        ; reported the reset's sense, which said nothing about the read.
        call fediag
        jmp  quit

; fediag -- AH=FE and print it
fediag:
        mov  dx, msg_tfe
        call puts
        mov  ah, 0xFE
        mov  dl, [drive]
        int  0x13
        jc   .fd_no
        mov  [r_dx], dx                 ; DL is the diagnostic: capture it
        mov  [r_bx], bx                 ; before any message load
        mov  [r_cx], cx
        mov  [r_al], al
        mov  [r_si], si
        mov  [r_di], di
        mov  dx, msg_rst
        call puts
        mov  al, [r_al]
        call puthex
        mov  dx, msg_sns
        call puts
        mov  al, [r_bx]
        call puthex
        mov  al, [r_bx+1]
        call puthex
        mov  dx, msg_cbi
        call puts
        mov  al, [r_cx]
        call puthex
        mov  al, [r_cx+1]
        call puthex
        mov  dx, msg_enu
        call puts
        mov  al, [r_dx]
        call puthex
        mov  dx, msg_blk
        call puts
        mov  ax, [r_si]
        call puthex16
        mov  dx, msg_lst
        call puts
        mov  al, [r_dx+1]
        call puthex
        mov  dx, msg_lba
        call puts
        mov  ax, [r_di]
        call puthex16
        mov  dx, msg_crlf
        call puts
        ret
.fd_no:
        mov  dx, msg_nofe
        call puts
        ret

; report -- CF and AH from the call that just returned
report:
        mov  [lastah], ah
        jc   .r_bad
        mov  dx, msg_ok
        call puts
        mov  al, ah
        call puthex
        mov  dx, msg_crlf
        call puts
        clc
        ret
.r_bad:
        mov  dx, msg_fail
        call puts
        mov  al, [lastah]
        call puthex
        mov  dx, msg_crlf
        call puts
        stc
        ret

quit:
        mov  ah, 0x4C
        xor  al, al
        int  0x21

puts:
        push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthex:
        push ax
        push cx
        push dx
        mov  cl, al
        shr  al, 1
        shr  al, 1
        shr  al, 1
        shr  al, 1
        call .nyb
        mov  al, cl
        call .nyb
        pop  dx
        pop  cx
        pop  ax
        ret
.nyb:
        and  al, 0x0F
        add  al, '0'
        cmp  al, '9'
        jbe  .pr
        add  al, 7
.pr:
        mov  dl, al
        mov  ah, 2
        int  0x21
        ret

puthex16:
        push ax
        mov  al, ah
        call puthex
        pop  ax
        call puthex
        ret

drive   db 1
lastah  db 0
r_cx    dw 0
r_dx    dw 0
r_bl    db 0
r_bx    dw 0
r_al    db 0
r_si    dw 0
r_di    dw 0

msg_hdr  db 'B13 -- what INT 13h actually returns for a drive', 13, 10, '$'
msg_drv  db 'drive       ', '$'
msg_t15  db 'AH=15 type  ', '$'
msg_t08  db 'AH=08 parms ', '$'
msg_t16  db 'AH=16 chng  ', '$'
msg_t00  db 'AH=00 reset ', '$'
msg_t02  db 'AH=02 read  ', '$'
msg_ok   db 'ok   AH=', '$'
msg_fail db 'FAIL AH=', '$'
msg_type db '      -> type ', '$'
msg_geom db '      -> CX=', '$'
msg_bl   db '  BL=', '$'
msg_bps  db '  BPB: bytes/sec ', '$'
msg_spt  db ' sec/trk ', '$'
msg_hds  db ' heads ', '$'
msg_tot  db ' total ', '$'
msg_med  db ' media ', '$'
msg_sig  db ' sig ', '$'
msg_tfe  db 'AH=FE diag  ', '$'
msg_rst  db 'ready-stage ', '$'
msg_sns  db '  sense ', '$'
msg_cbi  db '  cbi ', '$'
msg_enu  db '  enum ', '$'
msg_blk  db '  bulk-left ', '$'
msg_lst  db '  st ', '$'
msg_lba  db '  lba ', '$'
msg_nofe db 'not supported by this BIOS', 13, 10, '$'
msg_crlf db 13, 10, '$'

secbuf  times 512 db 0
