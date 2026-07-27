; ============================================================================
;  usbhd.asm  --  report what the BIOS made of the USB disk, and exercise it
;
;  POST already prints one line for C:. This goes further: it shows the
;  enumeration stage, the endpoints and geometry the BIOS settled on, and then
;  drives INT 13h against DL=0x80 the way DOS would.
;
;  The stage byte is the important one when C: does not appear. It says which
;  step failed rather than leaving a silent absence:
;
;    01 no 48 MHz PLL lock        02 no full-speed device on the port
;    03 device descriptor failed  04 SET_ADDRESS failed
;    05 config descriptor failed  06 no bulk endpoints / not mass storage
;    07 SET_CONFIGURATION failed  08 unit never became ready
;    09 READ CAPACITY failed      0A capacity unusable as CHS
;    FF success
;
;  Build:  nasm -f bin usbhd.asm -o usbhd.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

start:
        mov  dx, msg_hdr
        call puts

; ---------------- what POST decided -----------------------------------------
; ES is used as a scratch segment for BDA and F000 reads throughout, so any
; code below that hands a buffer to the BIOS must set it deliberately.
        mov  ax, 0x40
        mov  es, ax

        mov  dx, msg_stage
        call puts
        mov  al, [es:0xC0]
        call puthex
        mov  bl, al
        mov  dx, msg_sp
        call puts
        cmp  bl, 0xFF
        je   .ok
        call stage_name
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_absent
        call puts
        call dump_cfg
        jmp  done
.ok:
        mov  dx, msg_enumok
        call puts

        mov  dx, msg_eps
        call puts
        mov  al, [es:0xC3]
        call puthex
        mov  dx, msg_slash
        call puts
        mov  al, [es:0xC4]
        call puthex
        mov  dx, msg_crlf
        call puts

        mov  dx, msg_lba
        call puts
        mov  ax, [es:0xCA]
        call puthex16
        mov  ax, [es:0xC8]
        call puthex16
        mov  dx, msg_crlf
        call puts

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

        ; capacity in MB = cyl * heads * spt / 2048
        mov  dx, msg_size
        call puts
        mov  ax, [es:0xCC]
        xor  bh, bh
        mov  bl, [es:0xCE]
        mul  bx
        mov  bl, [es:0xCF]
        xor  bh, bh
        mul  bx                 ; dx:ax = total sectors
        mov  cx, 2048
        div  cx                 ; ax = MB
        call putdec
        mov  dx, msg_mb
        call puts

; ---------------- INT 13h AH=08 ---------------------------------------------
        mov  dx, msg_t1
        call puts
        mov  ah, 0x08
        mov  dl, 0x80
        int  0x13
        ; Snapshot everything NOW. puts uses DX for the string and AH=9;
        ; puthex uses DL for AH=2. Printing one register destroys the next,
        ; which is how this reported DH=05 DL=4B when the BIOS returned 0F/01.
        ; MOV does not touch flags, so the JC below still sees INT 13h's CF.
        mov  [r_ax], ax
        mov  [r_cx], cx
        mov  [r_dx], dx
        jc   .t1bad
        call pass
        mov  dx, msg_ind
        call puts
        mov  al, [r_cx+1]       ; CH = max cylinder, low 8 bits
        call puthex
        mov  dx, msg_sp
        call puts
        mov  al, [r_cx]         ; CL = sectors | cylinder high bits
        call puthex
        mov  dx, msg_sp
        call puts
        mov  al, [r_dx+1]       ; DH = max head
        call puthex
        mov  dx, msg_sp
        call puts
        mov  al, [r_dx]         ; DL = number of fixed disks
        call puthex
        mov  dx, msg_crlf
        call puts
        jmp  short .t2
.t1bad:
        call fail
        mov  dx, msg_ah
        call puts
        mov  al, [r_ax+1]
        call puthex
        mov  dx, msg_crlf
        call puts
        jmp  done

; ---------------- INT 13h AH=02, read LBA 0 ---------------------------------
.t2:
        mov  dx, msg_t2
        call puts
        mov  di, secbuf
        mov  cx, 512
        xor  al, al
.t2_clr:
        mov  [di], al
        inc  di
        loop .t2_clr
        ; ES:BX is the destination, and ES is still 0x0040 from reading the
        ; BDA at the top of this program. Without this the BIOS faithfully
        ; wrote 512 bytes to 0040:secbuf -- linear ~0xF00, in DOS's low memory.
        ; The read "passed", secbuf stayed zero, and the machine locked up a
        ; moment later. The BIOS was doing exactly what it was asked.
        push ds
        pop  es
        mov  ax, 0x0201         ; read 1 sector
        mov  cx, 0x0001         ; cyl 0, sector 1
        xor  dh, dh             ; head 0
        mov  dl, 0x80
        mov  bx, secbuf
        int  0x13
        mov  [r_ax], ax         ; before anything can clobber it
        mov  [r_cx], cx
        mov  [r_dx], dx
        jc   .t2bad
        call pass
        ; dump the first 16 bytes
        mov  dx, msg_ind
        call puts
        mov  si, secbuf
        mov  cx, 16
.t2_dump:
        lodsb
        call puthex
        mov  dx, msg_sp
        call puts
        loop .t2_dump
        mov  dx, msg_crlf
        call puts
        ; partition signature?
        mov  dx, msg_sig
        call puts
        mov  ax, [secbuf+510]
        cmp  ax, 0xAA55
        jne  .nosig
        mov  dx, msg_yes
        call puts
        jmp  done
.nosig:
        call puthex16
        mov  dx, msg_nosig
        call puts
        jmp  done
.t2bad:
        call fail
        mov  dx, msg_ah
        call puts
        mov  al, [r_ax+1]       ; the real AH from INT 13h, not AH=9 from puts
        call puthex
        mov  dx, msg_sp
        call puts
        mov  dx, msg_alsec
        call puts
        mov  al, [r_ax]         ; AL = sectors actually transferred
        call puthex
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_ahhelp
        call puts
        ; where inside the transport it gave up
        push es
        mov  ax, 0x40
        mov  es, ax
        mov  al, [es:0xDD]
        mov  bl, al
        mov  al, [es:0xDE]
        mov  bh, al
        pop  es
        mov  dx, msg_botf
        call puts
        mov  al, bl
        call puthex
        mov  dx, msg_sp
        call puts
        mov  al, bl
        call bot_name
        mov  dx, msg_crlf
        call puts
        ; the raw transaction status that made the bulk transfer give up
        push es
        mov  ax, 0x40
        mov  es, ax
        mov  al, [es:0xDF]
        pop  es
        mov  bl, al
        mov  dx, msg_txst
        call puts
        mov  al, bl
        call puthex
        mov  dx, msg_sp
        call puts
        test bl, 0x10
        jz   .nt
        mov  dx, msg_x_tmo
        call puts
.nt:    test bl, 0x08
        jz   .ns
        mov  dx, msg_x_stall
        call puts
.ns:    test bl, 0x04
        jz   .nn
        mov  dx, msg_x_nak
        call puts
.nn:    test bl, 0x20
        jz   .ne
        mov  dx, msg_x_err
        call puts
.ne:    test bl, 0x02
        jz   .na2
        mov  dx, msg_x_ack
        call puts
.na2:   mov  dx, msg_crlf
        call puts
        cmp  bl, 5
        jne  .no_csw
        mov  dx, msg_cswst
        call puts
        mov  al, bh
        call puthex
        mov  dx, msg_crlf
        call puts
.no_csw:

done:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
;  dump_cfg -- show the configuration descriptor the BIOS received.
;  It lives in the BIOS segment; POST publishes its offset at BDA 0xDA and the
;  byte count at 0xDC, because a DOS program cannot otherwise know where the
;  linker put it.
dump_cfg:
        push es
        mov  ax, 0x40
        mov  es, ax
        mov  si, [es:0xDA]
        mov  cx, [es:0xDC]
        test si, si
        jz   .dc_none
        push cx
        mov  dx, msg_cfglen
        call puts
        mov  ax, cx
        call putdec
        mov  dx, msg_crlf
        call puts
        pop  cx
        jcxz .dc_none
        cmp  cx, 40
        jbe  .dc_sz
        mov  cx, 40
.dc_sz:
        mov  ax, 0xF000
        mov  es, ax
        mov  dx, msg_ind
        call puts
        mov  bx, 0
.dc_l:
        mov  al, [es:si]
        call puthex
        mov  dx, msg_sp
        call puts
        inc  si
        inc  bx
        cmp  bx, 16
        jne  .dc_nl
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_ind
        call puts
        xor  bx, bx
.dc_nl:
        loop .dc_l
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_cfghelp
        call puts
        pop  es
        ret
.dc_none:
        mov  dx, msg_nocfg
        call puts
        pop  es
        ret

bot_name:
        push ax
        mov  dx, msg_b_unk
        cmp  al, 1
        jne  .b2
        mov  dx, msg_b1
.b2:    cmp  al, 2
        jne  .b3
        mov  dx, msg_b2
.b3:    cmp  al, 3
        jne  .b4
        mov  dx, msg_b3
.b4:    cmp  al, 4
        jne  .b5
        mov  dx, msg_b4
.b5:    cmp  al, 5
        jne  .b0
        mov  dx, msg_b5
.b0:    cmp  al, 0
        jne  .bz
        mov  dx, msg_b0
.bz:    call puts
        pop  ax
        ret

stage_name:
        push ax
        mov  dx, msg_s_unk
        cmp  bl, 0x01
        jne  .n2
        mov  dx, msg_s01
.n2:    cmp  bl, 0x02
        jne  .n3
        mov  dx, msg_s02
.n3:    cmp  bl, 0x03
        jne  .n4
        mov  dx, msg_s03
.n4:    cmp  bl, 0x04
        jne  .n5
        mov  dx, msg_s04
.n5:    cmp  bl, 0x05
        jne  .n6
        mov  dx, msg_s05
.n6:    cmp  bl, 0x06
        jne  .n7
        mov  dx, msg_s06
.n7:    cmp  bl, 0x07
        jne  .n8
        mov  dx, msg_s07
.n8:    cmp  bl, 0x08
        jne  .n9
        mov  dx, msg_s08
.n9:    cmp  bl, 0x09
        jne  .na
        mov  dx, msg_s09
.na:    cmp  bl, 0x0A
        jne  .nz
        mov  dx, msg_s0a
.nz:    call puts
        pop  ax
        ret

puts:
        push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthex16:
        push ax
        mov  al, ah
        call puthex
        pop  ax
        call puthex
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

; ---------------------------------------------------------------------------
msg_hdr    db 'USBHD - USB mass storage (drive C:)',13,10
           db '-----------------------------------',13,10,'$'
msg_stage  db 'enumeration stage : $'
msg_enumok db 'FF  complete',13,10,'$'
msg_eps    db 'bulk endpoints    : IN $'
msg_slash  db '  OUT $'
msg_lba    db 'last LBA          : $'
msg_geo    db 'geometry C/H/S    : $'
msg_size   db 'usable capacity   : $'
msg_mb     db ' MB',13,10,'$'
msg_t1     db 'INT 13h AH=08     : $'
msg_t2     db 'INT 13h AH=02 LBA0: $'
msg_sig    db '  boot signature  : $'
msg_yes    db 'AA55 present',13,10,'$'
msg_nosig  db ' - not a partitioned disk yet (run FDISK C:)',13,10,'$'
msg_ah     db '  AH = $'
msg_alsec  db 'AL = $'
msg_ahhelp db '  AH=04 means the transport ran and the CSW reported failure;',13,10
           db '  AH=01 means the drive was refused before any transfer.',13,10,'$'
msg_txst   db '  transaction status  : $'
msg_x_tmo  db 'TIMEOUT(no reply) $'
msg_x_stall db 'STALL(endpoint halted) $'
msg_x_nak  db 'NAK(retries exhausted) $'
msg_x_err  db 'CRC/PID-ERROR $'
msg_x_ack  db 'ACK(?!) $'
msg_botf   db '  transport failed at : $'
msg_cswst  db '  CSW bCSWStatus      : $'
msg_b0     db 'nowhere - u_bot succeeded, so the failure is above it$'
msg_b1     db 'CBW out - the 31-byte command never went$'
msg_b2     db 'DATA phase - the 512-byte transfer broke$'
msg_b3     db 'CSW in - no status came back$'
msg_b4     db 'CSW signature wrong - stream out of step$'
msg_b5     db 'CSW status non-zero - device rejected the command$'
msg_b_unk  db 'unknown$'
r_ax    dw 0
r_bx    dw 0
r_cx    dw 0
r_dx    dw 0
msg_pass   db 'PASS',13,10,'$'
msg_fail   db 'FAIL',13,10,'$'
msg_crlf   db 13,10,'$'
msg_sp     db ' $'
msg_x      db ' x $'
msg_ind    db '    $'
msg_absent db 13,10
           db 'C: was not created. The stage above says which step failed;',13,10
           db 'the list is in the header of tools/usbhd.asm.',13,10,'$'

msg_cfglen db 'config descriptor bytes received: $'
msg_nocfg  db '  (no configuration descriptor was captured)',13,10,'$'
msg_cfghelp db '  each descriptor is {bLength, bType, ...}; type 04 = interface',13,10
            db '  (class at +5, 08 = mass storage), type 05 = endpoint',13,10
            db '  (address at +2, attributes at +3, 02 = bulk)',13,10,'$'
msg_s01 db 'no 48 MHz PLL lock$'
msg_s02 db 'no full-speed device on the port$'
msg_s03 db 'device descriptor failed$'
msg_s04 db 'SET_ADDRESS failed$'
msg_s05 db 'config descriptor failed$'
msg_s06 db 'no bulk endpoints / not mass storage$'
msg_s07 db 'SET_CONFIGURATION failed$'
msg_s08 db 'unit never became ready$'
msg_s09 db 'READ CAPACITY failed$'
msg_s0a db 'capacity unusable as CHS$'
msg_s_unk db 'unknown stage$'

secbuf  times 512 db 0
