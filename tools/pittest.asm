; ============================================================================
;  pittest.asm  --  does IRQ0 survive being reprogrammed?
;
;  The BIOS sets timer 0 once, at 18.2 Hz, and never touches it again. Every
;  game does touch it: id's engines reprogram counter 0 to a few hundred Hz and
;  drive their music and their whole sense of time from it. So the divisor this
;  machine has been tested with is exactly one value out of 65536, and the one
;  value no game uses.
;
;  If IRQ0 stops at some other divisor, a game that reprograms it waits forever
;  on a tick that never arrives -- spinning in its own code, making no BIOS
;  calls, with nothing on screen to say so. That is not a hypothesis this can
;  be talked into or out of, so this measures it.
;
;  For each divisor: program it the way id does, count interrupts over a fixed
;  software delay, put it back. The delay is a plain instruction loop rather
;  than anything clock-derived, because the clock is the thing under test --
;  it is not accurate, but it is the SAME for every row, so the counts are
;  directly comparable and that is all the comparison needs.
;
;  Expect each count to scale with 65536/divisor. What matters is not the
;  arithmetic but the shape: every row must be non-zero. A zero, or a count
;  that stops rising, is the fault.
;
;  The BIOS divisor and the INT 08h vector are both put back before this
;  returns to DOS, so the system clock is left as it was found.
;
;  Build:  nasm -f bin pittest.asm -o pittest.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

OUTER   equ 10                  ; outer passes of a 65536-iteration inner loop

start:
        mov  dx, msg_hdr
        call puts

        ; ---- hook INT 08h so every IRQ0 is counted ----
        xor  ax, ax
        mov  es, ax
        mov  ax, [es:8*4]
        mov  [old08], ax
        mov  ax, [es:8*4+2]
        mov  [old08+2], ax
        cli
        mov  word [es:8*4], isr08
        mov  [es:8*4+2], cs
        sti

        ; ---- measure every divisor first, print afterwards ----
        ; Printing between measurements would call DOS while the timer is
        ; running at a thousand interrupts a second, which is a good way to
        ; measure the console instead of the timer.
        mov  si, tbl
        mov  di, results
.meas:
        cmp  byte [si], 0
        je   .done
        mov  al, [si]           ; control word
        mov  bx, [si+1]         ; divisor
        call settimer
        mov  word [ticks], 0
        call delay
        mov  ax, [ticks]
        mov  [di], ax
        add  di, 2
        add  si, 5
        jmp  short .meas
.done:

        ; ---- put the machine back the way it was ----
        mov  al, 0x36
        mov  bx, 0              ; 65536: the BIOS 18.2 Hz tick
        call settimer
        xor  ax, ax
        mov  es, ax
        cli
        mov  ax, [old08]
        mov  [es:8*4], ax
        mov  ax, [old08+2]
        mov  [es:8*4+2], ax
        sti

        ; ---- report ----
        mov  dx, msg_cols
        call puts
        mov  si, tbl
        mov  di, results
.rep:
        cmp  byte [si], 0
        je   .repdone
        mov  dx, [si+3]         ; the row's label
        call puts
        mov  ax, [di]
        call putdec5
        mov  ax, [di]
        mov  dx, msg_dead
        test ax, ax
        jz   .say
        mov  dx, msg_crlf
.say:   call puts
        add  di, 2
        add  si, 5
        jmp  short .rep
.repdone:
        mov  dx, msg_tail
        call puts
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; isr08 -- count and chain, so the BIOS keeps its own time and sends the EOI.
isr08:
        pushf
        inc  word [cs:ticks]
        popf
        jmp  far [cs:old08]

; ---------------------------------------------------------------------------
; settimer -- AL = control word, BX = divisor. Written exactly the way id's
; SDL_SetTimer0 writes it: control word, then LSB, then MSB, interrupts off
; across the pair so a tick cannot land between the halves of the count.
settimer:
        push ax
        cli
        out  0x43, al
        mov  al, bl
        out  0x40, al
        mov  al, bh
        out  0x40, al
        sti
        pop  ax
        ret

; ---------------------------------------------------------------------------
; delay -- a fixed amount of work. Not a fixed amount of TIME: at the higher
; divisors the interrupt handler itself steals cycles, so the wall clock
; stretches and the counts rise slightly faster than the divisor ratio. That
; is expected and does not affect the only question being asked.
delay:
        push ax
        push cx
        mov  al, OUTER
.d1:    mov  cx, 0              ; 0 means 65536 times round
.d2:    loop .d2
        dec  al
        jnz  .d1
        pop  cx
        pop  ax
        ret

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

; putdec5 -- AX right-aligned in five columns, so the table lines up
putdec5:
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
        mov  ax, 5
        sub  ax, cx
        jbe  .out
        mov  bx, ax
.pad:   mov  dl, ' '
        mov  ah, 2
        int  0x21
        dec  bx
        jnz  .pad
.out:
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
; control word, divisor, label -- 5 bytes per row, terminated by a zero
tbl     db 0x36
        dw 0x0000
        dw r1
        db 0x36
        dw 0x8000
        dw r2
        db 0x36
        dw 0x2000
        dw r3
        db 0x36
        dw 0x1000
        dw r4
        db 0x36
        dw 0x04A8
        dw r5
        db 0x34
        dw 0x2000
        dw r6
        db 0

r1      db '  mode 3   65536   18.2 Hz  BIOS default : $'
r2      db '  mode 3   32768   36.4 Hz              : $'
r3      db '  mode 3    8192  145.6 Hz  id engines   : $'
r4      db '  mode 3    4096  291.2 Hz              : $'
r5      db '  mode 3    1192   1000 Hz              : $'
r6      db '  mode 2    8192  145.6 Hz  rate gen     : $'

msg_hdr db 'PITTEST - does IRQ0 survive being reprogrammed?',13,10
        db '-----------------------------------------------',13,10
        db 'The BIOS uses one divisor out of 65536, and it is the one no',13,10
        db 'game uses. Measuring, at six of them. A few seconds.',13,10,13,10,'$'
msg_cols db 'divisor / expected rate                     interrupts',13,10,13,10,'$'
msg_dead db '   <-- NO INTERRUPTS AT ALL',13,10,'$'
msg_tail db 13,10
        db 'Every row must be non-zero, and the counts should rise roughly',13,10
        db 'with 65536/divisor. A zero row is a divisor at which this board',13,10
        db 'stops delivering IRQ0 -- and any game that picks it waits for a',13,10
        db 'tick that never comes.',13,10,13,10
        db 'The 18.2 Hz divisor and the INT 08h vector have been restored.',13,10,'$'
msg_crlf db 13,10,'$'

old08   dd 0
ticks   dw 0
results times 8 dw 0
