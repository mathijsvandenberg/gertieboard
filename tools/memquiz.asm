; ============================================================================
;  memquiz.asm  --  ask this machine every memory question DOS and games ask,
;                   and print the raw answer to each one
;
;  MEM reporting a number nobody can explain is not a MEM bug. MEM asks the
;  BIOS and the drivers, and prints what comes back -- so the interesting
;  question is what this machine ANSWERS, one call at a time, with nothing
;  interpreted in between.
;
;  The reason that matters here: this BIOS points every interrupt it does not
;  implement at a single shared IRET. An IRET restores the caller's flags, so
;  CF comes back exactly as the caller left it -- usually clear, which reads as
;  "call succeeded" -- and every register comes back holding whatever the
;  CALLER put there. Ask an unimplemented INT 15h for the extended memory size
;  with AH=88h and you get AX=88xx back, which is 34 MB of memory that does not
;  exist. The call did not fail; it was never answered, and the caller cannot
;  tell those apart.
;
;  So each line below prints the flag AND the value, and flags the specific
;  case where the value returned is just the value sent -- the fingerprint of
;  an unanswered call.
;
;  Build:  nasm -f bin memquiz.asm -o memquiz.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

start:
        mov  dx, msg_hdr
        call puts

; ---------------------------------------------------------------------------
; Conventional memory -- BDA 40:13 via INT 12h. This one has a real handler.
        mov  dx, msg_i12
        call puts
        int  0x12
        call putdec
        mov  dx, msg_kb
        call puts

; ---------------------------------------------------------------------------
; Equipment word. Bit 0 = floppies present, 7:6 = count-1, 5:4 = video type.
        mov  dx, msg_i11
        call puts
        int  0x11
        call puthexw
        mov  dx, msg_crlf
        call puts

; ---------------------------------------------------------------------------
; Extended memory, INT 15h AH=88h. CF is cleared FIRST so that a handler which
; never touches it shows up as "succeeded" -- which is precisely the trap.
        mov  dx, msg_i15
        call puts
        clc
        mov  ax, 0x8800
        int  0x15
        pushf
        pop  bx                 ; keep the returned flags
        mov  [ret15], ax
        mov  [flg15], bx
        call puthexw
        mov  dx, msg_cf
        call puts
        mov  ax, [flg15]
        and  ax, 1
        call putdec
        mov  dx, msg_crlf
        call puts

        ; the fingerprint: AX came back holding what we sent
        mov  dx, msg_i15echo
        cmp  word [ret15], 0x8800
        je   .say15
        mov  dx, msg_i15ok
        cmp  word [ret15], 0
        je   .say15
        mov  dx, msg_i15real
.say15: call puts

; ---------------------------------------------------------------------------
; INT 15h AH=C0h, get system configuration. A real XT-class BIOS either returns
; a table or reports the function unsupported with CF=1 and AH=86h.
        mov  dx, msg_i15c0
        call puts
        clc
        mov  ax, 0xC000
        int  0x15
        pushf
        pop  bx
        call puthexw
        mov  dx, msg_cf
        call puts
        mov  ax, bx
        and  ax, 1
        call putdec
        mov  dx, msg_crlf
        call puts

; ---------------------------------------------------------------------------
; XMS. The driver announces itself through the DOS multiplex interrupt, not
; through the BIOS, so this answer does not depend on INT 15h at all.
        mov  dx, msg_xms
        call puts
        mov  ax, 0x4300
        int  0x2F
        mov  ah, 0
        push ax
        call puthexb
        pop  ax
        mov  dx, msg_xmsno
        cmp  al, 0x80
        jne  .sayxms
        mov  dx, msg_xmsyes
.sayxms:
        call puts

; ---------------------------------------------------------------------------
; EMS. Two separate questions, and they can disagree.
;
;   1. the INT 67h VECTOR -- on a real XT the interrupt table above 1Fh is left
;      as the memory test found it, so an unused vector reads 0000:0000 and
;      "is EMS installed" is answered by the vector alone. This BIOS fills all
;      256 entries with its dummy handler instead, so the vector is never zero
;      and that test cannot work here.
;
;   2. the "EMMXXXX0" signature ten bytes into the handler's segment, which is
;      how careful software (including id's) actually asks.
        mov  dx, msg_ems
        call puts
        xor  ax, ax
        mov  es, ax
        mov  ax, [es:0x67*4+2]
        mov  [emsseg], ax
        call puthexw
        mov  dl, ':'
        call putch
        mov  ax, [es:0x67*4]
        mov  [emsoff], ax
        call puthexw

        ; does it point at a bare IRET?
        mov  es, [emsseg]
        mov  bx, [emsoff]
        mov  al, [es:bx]
        mov  dx, msg_emsiret
        cmp  al, 0xCF
        je   .sayems
        mov  dx, msg_emscode
.sayems:
        call puts

        ; the signature test, ten bytes into the handler segment
        mov  dx, msg_emssig
        call puts
        mov  es, [emsseg]
        mov  si, 0x0A
        mov  cx, 8
.sigl:  mov  al, [es:si]
        call puthexb
        mov  dl, ' '
        call putch
        inc  si
        loop .sigl
        mov  dx, msg_crlf
        call puts

        ; compare it properly
        mov  es, [emsseg]
        mov  si, 0x0A
        mov  di, emmname
        mov  cx, 8
        mov  bl, 1
.cmpl:  mov  al, [es:si]
        mov  ah, [di]
        cmp  al, ah
        je   .cmpn
        mov  bl, 0
.cmpn:  inc  si
        inc  di
        loop .cmpl
        mov  dx, msg_emsnone
        cmp  bl, 0
        je   .sayems2
        mov  dx, msg_emsyes
.sayems2:
        call puts

; ---------------------------------------------------------------------------
; What DOS will actually hand a program. This is the number that decides
; whether a large game loads, and it comes from the DOS arena, not the BIOS.
        mov  dx, msg_dos
        call puts
        mov  ah, 0x48
        mov  bx, 0xFFFF
        int  0x21               ; fails by design; BX = largest block
        mov  ax, bx
        push ax
        call puthexw
        mov  dx, msg_para
        call puts
        pop  ax
        mov  cl, 6              ; paragraphs -> KB is a shift by 6
        shr  ax, cl
        call putdec
        mov  dx, msg_kbfree
        call puts

        mov  dx, msg_tail
        call puts
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
putch:  push ax
        mov  ah, 2
        int  0x21
        pop  ax
        ret

puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthexw:                        ; AX in hex
        push ax
        mov  al, ah
        call puthexb
        pop  ax
        call puthexb
        ret

puthexb:                        ; AL in hex
        push ax
        push bx
        push cx
        push dx
        mov  bl, al
        mov  cl, 4
        shr  al, cl
        call .nib
        mov  al, bl
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
        call putch
        ret

putdec:                         ; AX in decimal
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
        call putch
        loop .d2
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
ret15   dw 0
flg15   dw 0
emsseg  dw 0
emsoff  dw 0
emmname db 'EMMXXXX0'

msg_hdr db 'MEMQUIZ - the raw answer to every memory question',13,10
        db '--------------------------------------------------',13,10,'$'
msg_i12 db 'INT 12h  conventional      : $'
msg_kb  db ' KB',13,10,'$'
msg_i11 db 'INT 11h  equipment word    : $'
msg_i15 db 'INT 15h  AH=88h extended   : AX=$'
msg_cf  db '  CF=$'
msg_i15echo db '         -> UNANSWERED: AX came back holding the 8800h we sent.',13,10
        db '            Anything that trusts this sees 34816 KB of extended',13,10
        db '            memory that does not exist.',13,10,'$'
msg_i15ok db '         -> answered: no extended memory. Correct for this board.',13,10,'$'
msg_i15real db '         -> answered with a size. Unexpected on this board.',13,10,'$'
msg_i15c0 db 'INT 15h  AH=C0h config     : AX=$'
msg_xms db 'INT 2Fh  AX=4300h XMS      : AL=$'
msg_xmsno db '  no XMS driver',13,10,'$'
msg_xmsyes db '  XMS driver present',13,10,'$'
msg_ems db 'INT 67h  vector            : $'
msg_emsiret db '  -> a bare IRET',13,10,'$'
msg_emscode db '  -> real code',13,10,'$'
msg_emssig db 'INT 67h  bytes at seg:000A : $'
msg_emsnone db '         -> not EMMXXXX0, so no EMS driver.',13,10,'$'
msg_emsyes db '         -> EMMXXXX0 signature present: an EMS driver is here.',13,10,'$'
msg_dos db 'INT 21h  AH=48h largest    : $'
msg_para db 'h paragraphs = $'
msg_kbfree db ' KB free to a program',13,10,'$'
msg_tail db 13,10
        db 'A vector pointing at a bare IRET is not the same as "absent".',13,10
        db 'It answers every question with the question.',13,10,'$'
msg_crlf db 13,10,'$'
