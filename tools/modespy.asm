; ============================================================================
;  modespy.asm  --  log every INT 10h call a program makes, then dump it
;
;  A game that takes the screen makes its own behaviour invisible: it sets a
;  mode, draws, and restores text mode on the way out, so by the time anything
;  can be read the evidence is gone. Guessing from the picture does not work
;  either -- a dithered 4-colour image, a composite-artifact image and a text
;  buffer being written into a graphics framebuffer all look like "stripes".
;
;  So this records instead. It hooks INT 10h, logs the registers of every call
;  into a ring buffer inside its own resident image, and chains on. Run the
;  program, quit it, then dump the log and read what actually happened.
;
;      modespy            install
;      modespy d          dump the log recorded since installation
;
;  The dump finds the resident copy through the INT 10h vector itself -- the
;  vector points into it, and the buffer is at the same offset in both copies
;  of the same binary, so there is nothing to hardcode and nothing to search.
;
;  Build:  nasm -f bin modespy.asm -o modespy.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

ENTRIES equ 40                  ; how many of the FIRST calls to keep
ESIZE   equ 4

start:
        jmp  setup

; ---------------------------------------------------------------------------
; Resident part, kept first so the transient setup can be dropped. The layout
; below is what the dump reads out of the installed copy, so the order of
; these three matters more than it looks.
old10   dd 0
wptr    dw 0                    ; write offset into log, in bytes
count   dw 0                    ; total calls seen
log     times ENTRIES*ESIZE db 0
hist    times 256*2 db 0        ; calls per AH value -- the whole run, not a window
lines   db 0                    ; used only by the dump, in its own copy

isr10:
        push bp
        mov  bp, sp
        push ax
        push bx
        push ds
        push cs
        pop  ds

        ; Count every call, for ever. A window of the last few is useless here:
        ; the run makes twelve thousand calls, so the startup sequence -- the
        ; mode set and the palette calls, the whole reason to look -- had
        ; scrolled out of it long before the program quit.
        push ax
        mov  al, ah
        mov  ah, 0
        shl  ax, 1
        mov  bx, ax
        inc  word [hist+bx]
        pop  ax

        ; and keep the FIRST few in order, which is where startup lives
        mov  bx, [wptr]
        cmp  bx, ENTRIES*ESIZE
        jae  .full
        mov  [log+bx], ah
        mov  [log+bx+1], al
        push ax
        mov  al, bh
        mov  [log+bx+2], al
        mov  al, bl             ; BL: colour for AH=0B/0E, attribute for AH=09
        mov  [log+bx+3], al
        pop  ax
        add  bx, ESIZE
        mov  [wptr], bx
.full:
        inc  word [count]

        pop  ds
        pop  bx
        pop  ax
        pop  bp
        jmp  far [cs:old10]
resident_end:

; ---------------------------------------------------------------------------
setup:
        mov  al, [0x80]         ; a command tail at all means "dump"
        test al, al
        jz   .install
        mov  si, 0x81
        mov  cl, al
        mov  ch, 0
.scan:  lodsb
        cmp  al, ' '
        jne  dump
        loop .scan

.install:
        xor  ax, ax
        mov  es, ax
        mov  ax, [es:0x10*4]
        mov  [old10], ax
        mov  ax, [es:0x10*4+2]
        mov  [old10+2], ax

        cli                     ; both halves together, or an interrupt
        mov  word [es:0x10*4], isr10   ; landing between them goes nowhere
        mov  [es:0x10*4+2], cs
        sti

        mov  dx, msg_inst
        call puts
        mov  dx, (resident_end - start + 0x10F) / 16
        mov  ax, 0x3100         ; terminate and stay resident
        int  0x21

; ---------------------------------------------------------------------------
; dump -- read the log out of the installed copy, wherever DOS put it
dump:
        xor  ax, ax
        mov  es, ax
        mov  ax, [es:0x10*4]    ; must point at OUR isr10 offset
        cmp  ax, isr10
        jne  .notthere
        mov  ax, [es:0x10*4+2]
        mov  es, ax             ; ES = the resident copy's segment

        mov  dx, msg_dhdr
        call puts
        mov  ax, [es:count]
        call putdec
        mov  dx, msg_dhdr2
        call puts

        ; ---- how many of each function, across the whole run ----
        xor  si, si
.hloop:
        mov  ax, [es:hist+si]
        test ax, ax
        jz   .hnext
        mov  dx, msg_hah
        call puts
        mov  ax, si
        shr  ax, 1
        call puthex
        mov  dx, msg_hx
        call puts
        mov  ax, [es:hist+si]
        call putdec
        push si
        mov  ax, si             ; si is a byte index into hist; the AH value
        shr  ax, 1              ; it counts is half that
        call name_ah
        pop  si
.hnext:
        add  si, 2
        cmp  si, 512
        jb   .hloop

        call waitkey            ; the summary is the part worth reading; do not
                                ; let the listing scroll it away
        mov  dx, msg_first
        call puts
        mov  byte [lines], 0
        xor  si, si
        mov  cx, [es:wptr]
        mov  ax, cx
        mov  cl, 2
        shr  ax, cl
        mov  cx, ax             ; entries actually stored
.loop:
        jcxz .done
        push cx
        push si
        mov  al, [es:log+si]
        call show
        inc  byte [lines]
        cmp  byte [lines], 20
        jb   .nopage
        mov  byte [lines], 0
        call waitkey
.nopage:
        pop  si
        add  si, ESIZE
        pop  cx
        loop .loop
.done:
        mov  dx, msg_dend
        call puts
        jmp  bye
.notthere:
        mov  dx, msg_none
        call puts
bye:
        mov  ax, 0x4C00
        int  0x21

; show -- one log entry; ES:SI points at it, AL is already its AH byte
show:
        mov  dx, msg_ah
        call puts
        mov  al, [es:log+si]
        call puthex
        mov  dx, msg_al
        call puts
        mov  al, [es:log+si+1]
        call puthex
        mov  dx, msg_bh
        call puts
        mov  al, [es:log+si+2]
        call puthex
        mov  dx, msg_bl
        call puts
        mov  al, [es:log+si+3]
        call puthex
        mov  al, [es:log+si]
        call name_ah
        ret

; name_ah -- one line naming the function in AL
name_ah:
        mov  dx, msg_n00
        cmp  al, 0x00
        je   .say
        mov  dx, msg_n09
        cmp  al, 0x09
        je   .say
        mov  dx, msg_n0a
        cmp  al, 0x0A
        je   .say
        mov  dx, msg_n0b
        cmp  al, 0x0B
        je   .say
        mov  dx, msg_n0c
        cmp  al, 0x0C
        je   .say
        mov  dx, msg_n0e
        cmp  al, 0x0E
        je   .say
        mov  dx, msg_n0f
        cmp  al, 0x0F
        je   .say
        mov  dx, msg_crlf
.say:   call puts
        ret

; ---------------------------------------------------------------------------
; waitkey -- hold the screen. Reading a dump off a CRT with a camera needs the
; interesting part to stay put, and the histogram is the interesting part.
waitkey:
        push ax
        push dx
        mov  dx, msg_more
        call puts
        xor  ah, ah
        int  0x16
        mov  dx, msg_crlf
        call puts
        pop  dx
        pop  ax
        ret

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
msg_inst db 'MODESPY installed. Every INT 10h call is now logged.',13,10
         db 13,10
         db 'Run the program, quit back to DOS, then:  modespy d',13,10,'$'
msg_none db 'MODESPY is not installed (INT 10h does not point at it).',13,10,'$'
msg_dhdr db 'INT 10h calls logged: $'
msg_dhdr2 db 13,10,13,10,'$'
msg_dend db 13,10,'Reboot to remove MODESPY.',13,10,'$'
msg_ah   db '  AH=$'
msg_al   db ' AL=$'
msg_bh   db ' BH=$'
msg_bl   db ' BL=$'
msg_hah  db '  AH=$'
msg_hx   db ' x $'
msg_first db 13,10,'first calls, in order:',13,10,'$'
msg_more db 13,10,'-- press a key --$'
msg_n00  db '   set mode',13,10,'$'
msg_n09  db '   write char+attr',13,10,'$'
msg_n0a  db '   write char',13,10,'$'
msg_n0b  db '   palette / background',13,10,'$'
msg_n0c  db '   write pixel',13,10,'$'
msg_n0e  db '   teletype',13,10,'$'
msg_n0f  db '   get mode',13,10,'$'
msg_crlf db 13,10,'$'
