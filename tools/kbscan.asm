; ============================================================================
;  kbscan.asm  --  show the raw scancode bytes the keyboard actually sends
;
;  The arrow keys have now been wrong in two different ways, and both times the
;  reasoning was built on an assumption about the byte stream rather than a
;  measurement of it. This removes the assumption: it hooks INT 09h, takes the
;  byte straight from port 60h, and prints it. Nothing is translated, nothing
;  is filtered.
;
;  What to look for, pressing one key at a time:
;
;    dedicated right arrow   should be   E0 4D   (make)   E0 CD   (break)
;    numeric keypad 6        should be      4D   (make)      CD   (break)
;    Enter                   should be      1C             9C
;    numeric keypad Enter    should be   E0 1C           E0 9C
;
;  If the E0 is missing, or arrives without its partner, or the pair is split
;  across two keypresses, that is the bug -- and it is in the FPGA or in the
;  acknowledge handshake, not in the BIOS translation.
;
;  The ISR only stores bytes in a ring; printing happens in the main loop,
;  because calling DOS from inside an interrupt handler is its own bug.
;
;  ESC exits and puts the original handler back.
;
;  Build:  nasm -f bin kbscan.asm -o kbscan.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

start:
        mov  dx, msg_hdr
        call puts

        ; ---- save and hook INT 09h ----
        xor  ax, ax
        mov  es, ax
        cli
        mov  ax, [es:9*4]
        mov  [old09], ax
        mov  ax, [es:9*4+2]
        mov  [old09+2], ax
        mov  word [es:9*4], isr09
        mov  [es:9*4+2], cs
        sti

.loop:
        ; ---- anything in the ring? ----
        mov  si, [rd]
        cmp  si, [wr]
        je   .loop

        mov  al, [ring+si]
        inc  si
        and  si, 0x3F
        mov  [rd], si

        push ax
        call puthex
        mov  dl, ' '
        mov  ah, 2
        int  0x21
        pop  ax

        ; a break code for ESC (0x81) ends the run
        cmp  al, 0x81
        jne  .loop

        ; ---- restore and leave ----
        xor  ax, ax
        mov  es, ax
        cli
        mov  ax, [old09]
        mov  [es:9*4], ax
        mov  ax, [old09+2]
        mov  [es:9*4+2], ax
        sti
        mov  dx, msg_bye
        call puts
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; isr09 -- take the byte, acknowledge exactly as the BIOS does, store, EOI.
isr09:
        push ax
        push bx
        push si
        push ds
        push cs
        pop  ds

        in   al, 0x60
        mov  bl, al             ; the byte, before anything can disturb it

        ; XT acknowledge: pulse PB7 high then low again, exactly as the BIOS
        ; does -- getting this wrong changes what the FPGA sends next
        in   al, 0x61
        mov  ah, al
        or   al, 0x80
        out  0x61, al
        mov  al, ah
        out  0x61, al

        mov  si, [wr]
        mov  [ring+si], bl
        inc  si
        and  si, 0x3F
        mov  [wr], si

        mov  al, 0x20           ; EOI
        out  0x20, al
        pop  ds
        pop  si
        pop  bx
        pop  ax
        iret

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 9
        int  0x21
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

; ---------------------------------------------------------------------------
msg_hdr db 'KBSCAN - raw scancode bytes, exactly as they arrive',13,10
        db '--------------------------------------------------',13,10
        db 'Press keys one at a time. Expected, on a 101-key board:',13,10
        db '  right arrow  E0 4D / E0 CD      keypad 6  4D / CD',13,10
        db '  Enter        1C / 9C            keypad Enter  E0 1C / E0 9C',13,10
        db 13,10,'ESC exits.',13,10,13,10,'$'
msg_bye db 13,10,'Original INT 09h restored.',13,10,'$'

old09   dd 0
wr      dw 0
rd      dw 0
ring    times 64 db 0
