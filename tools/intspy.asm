; ============================================================================
;  intspy.asm  --  catch a program calling an interrupt this BIOS does not
;                  implement, and show which one on the 7-segment display
;
;  A program that stops dead tells you nothing. It has taken the screen, DOS is
;  not going to come back, and whatever it asked for last is gone. Keen 4 stops
;  on its startup panel with the memory figures still reading "xxxxx", which
;  says only that it got past drawing the panel and never reached filling it in.
;
;  This BIOS points every interrupt it does not implement at one shared IRET.
;  That is a quiet failure mode: the call returns, the caller's flags come back
;  untouched so CF reads as "no error", and every register comes back holding
;  what the caller put there. A program can ask for something this machine has
;  never heard of, be told yes, and then act on an answer that is really its own
;  question echoed back. It may loop forever waiting for something to change.
;
;  So this makes those calls visible. It finds every vector still pointing at
;  the BIOS dummy, gives each its own stub, and each stub writes its own vector
;  number to port 0x80 -- the 7-segment display -- before returning exactly as
;  the dummy would have. Nothing else about the machine changes.
;
;  The display is the point. It is not memory and it is not the screen: it keeps
;  showing the last value written even after the CPU has stopped doing anything
;  useful. Run the program, let it hang, and READ THE DIGIT. That is the number
;  of the last unimplemented interrupt the program called.
;
;      intspy            install
;      intspy d          dump the per-vector counts (needs DOS back)
;      intspy r          remove
;
;  Reading the result:
;
;    the display changes, then freezes on a value
;        -> that interrupt is the last thing the program asked for. It is
;           unimplemented, and the program is very likely stuck on the answer.
;
;    the display never changes from the POST code
;        -> the program never called an unimplemented interrupt. The hang is
;           somewhere else and this rules out a whole class of cause.
;
;  INT 1Ch is deliberately left alone. It is the user timer tick, it is empty on
;  purpose, and the BIOS calls it 18.2 times a second -- hooking it would peg the
;  display at 1C and hide everything else.
;
;  Build:  nasm -f bin intspy.asm -o intspy.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

STUBSZ  equ 12                  ; bytes per generated stub, see build_stubs
SEG7    equ 0x80                ; 7-segment display, one byte at a time

start:
        mov  al, [0x80]         ; command tail length
        test al, al
        jz   install
        mov  cl, al
        mov  ch, 0
        mov  si, 0x81
.scan:  lodsb
        cmp  al, ' '
        je   .next
        and  al, 0xDF
        cmp  al, 'D'
        je   dump
        cmp  al, 'R'
        je   remove
        jmp  short install
.next:  loop .scan
        jmp  short install

; ===========================================================================
;  install
; ===========================================================================
install:
        call find_resident      ; installing twice would hook our own stubs
        jnc  .already
        call find_dummy
        jc   .nodummy

        call build_stubs

        ; ---- point every dummy vector at its own stub ----
        xor  ax, ax
        mov  es, ax
        xor  si, si             ; si = vector number
        mov  word [hooked], 0
.hook:
        cmp  si, 0x1C           ; see the note at the top
        je   .skip

        mov  bx, si
        shl  bx, 1
        shl  bx, 1              ; bx = si*4, the IVT slot
        mov  ax, [es:bx]
        cmp  ax, [dummy]
        jne  .skip
        mov  ax, [es:bx+2]
        cmp  ax, [dummy+2]
        jne  .skip

        ; stub address = stubs + si*STUBSZ
        mov  ax, si
        mov  cx, STUBSZ
        mul  cx
        add  ax, stubs
        cli
        mov  [es:bx], ax        ; both halves together, or an interrupt
        mov  [es:bx+2], cs      ; landing between them goes nowhere
        sti
        inc  word [hooked]
.skip:
        inc  si
        cmp  si, 256
        jb   .hook

        mov  dx, msg_inst
        call puts
        mov  ax, [hooked]
        call putdec
        mov  dx, msg_inst2
        call puts

        mov  dx, (resident_end - start + 0x10F) / 16
        mov  ax, 0x3100         ; terminate and stay resident
        int  0x21

.already:
        mov  dx, msg_already
        call puts
        jmp  bye
.nodummy:
        mov  dx, msg_nodummy
        call puts
        jmp  bye

; ===========================================================================
;  find_dummy -- CF=0 and [dummy] = the BIOS's shared IRET handler.
;
;  Vector FFh is the honest place to look. The BIOS fills all 256 entries with
;  the dummy and then overwrites the ones it implements; DOS claims 20h-2Fh and
;  a few others but never FFh, so whatever is there is the dummy untouched.
;  It is only accepted if it lives in the BIOS segment AND the byte it points
;  at really is an IRET -- otherwise something else owns FFh and the whole
;  premise of this tool is wrong.
; ===========================================================================
find_dummy:
        push ax
        push bx
        push es
        xor  ax, ax
        mov  es, ax
        mov  ax, [es:0xFF*4]
        mov  [dummy], ax
        mov  ax, [es:0xFF*4+2]
        mov  [dummy+2], ax
        cmp  ax, 0xF000
        jne  .bad
        mov  es, ax
        mov  bx, [dummy]
        cmp  byte [es:bx], 0xCF ; IRET
        jne  .bad
        clc
        jmp  short .out
.bad:   stc
.out:   pop  es
        pop  bx
        pop  ax
        ret

; ===========================================================================
;  build_stubs -- write 256 handlers, one per vector.
;
;  Each is the same twelve bytes with two numbers stamped into it, so there is
;  one copy of the logic rather than 256 hand-written ones:
;
;      50              push ax
;      B0 nn           mov  al, <vector number>
;      E6 80           out  0x80, al        ; the 7-segment display
;      58              pop  ax              ; AX must survive: the dummy this
;      2E FF 06 ....   inc  word cs:[hits+2n]   ; replaces preserved everything
;      CF              iret
;
;  The INC lands after the POP so it cannot disturb AX, and its effect on the
;  flags does not matter because IRET reloads them from the stack. The result
;  behaves exactly like the IRET it replaced -- same registers, same flags --
;  which is what makes it safe to leave installed.
; ===========================================================================
build_stubs:
        push ax
        push bx
        push cx
        push di
        push es
        push cs
        pop  es
        mov  di, stubs
        xor  bx, bx             ; bx = vector number
.one:
        mov  al, 0x50           ; push ax
        stosb
        mov  al, 0xB0           ; mov al, imm8
        stosb
        mov  al, bl
        stosb
        mov  al, 0xE6           ; out imm8, al
        stosb
        mov  al, SEG7
        stosb
        mov  al, 0x58           ; pop ax
        stosb
        mov  al, 0x2E           ; CS: segment override
        stosb
        mov  al, 0xFF           ; inc word ptr [disp16]
        stosb
        mov  al, 0x06
        stosb
        mov  ax, bx             ; the counter for this vector
        shl  ax, 1
        add  ax, hits
        stosw
        mov  al, 0xCF           ; iret
        stosb
        inc  bx
        cmp  bx, 256
        jb   .one
        pop  es
        pop  di
        pop  cx
        pop  bx
        pop  ax
        ret

; ===========================================================================
;  dump -- print the counts out of the installed copy
; ===========================================================================
dump:
        call find_resident
        jc   .notthere

        mov  dx, msg_dhdr
        call puts
        xor  si, si             ; vector number
        mov  word [shown], 0
.d1:
        mov  bx, si
        shl  bx, 1
        mov  ax, [es:hits+bx]
        test ax, ax
        jz   .d2
        inc  word [shown]
        mov  dx, msg_int
        call puts
        mov  ax, si
        call puthexb
        mov  dx, msg_x
        call puts
        mov  bx, si
        shl  bx, 1
        mov  ax, [es:hits+bx]
        call putdec
        mov  ax, si
        call name_int
.d2:
        inc  si
        cmp  si, 256
        jb   .d1

        cmp  word [shown], 0
        jne  .some
        mov  dx, msg_dnone
        call puts
        jmp  short bye
.some:
        mov  dx, msg_dtail
        call puts
        jmp  short bye
.notthere:
        mov  dx, msg_notinst
        call puts
        jmp  short bye

; ===========================================================================
;  remove -- put the BIOS dummy back on everything we took
; ===========================================================================
remove:
        call find_resident      ; ES = the resident copy, [resseg] set here
        jc   dump.notthere

        ; The BIOS handler we displaced was recorded by the copy that did the
        ; installing, not by this one, so read it back out of there. DS stays
        ; ours throughout -- [resseg] and [dummy] below are this copy's.
        mov  ax, [es:dummy]
        mov  [dummy], ax
        mov  ax, [es:dummy+2]
        mov  [dummy+2], ax

        xor  ax, ax
        mov  es, ax             ; ES = IVT
        xor  si, si
.r1:
        mov  bx, si
        shl  bx, 1
        shl  bx, 1
        mov  ax, [es:bx+2]
        cmp  ax, [resseg]       ; still pointing into the resident copy?
        jne  .r2
        cli
        mov  ax, [dummy]
        mov  [es:bx], ax
        mov  ax, [dummy+2]
        mov  [es:bx+2], ax
        sti
.r2:
        inc  si
        cmp  si, 256
        jb   .r1

        mov  dx, msg_rem
        call puts

bye:
        mov  ax, 0x4C00
        int  0x21

; ===========================================================================
;  find_resident -- ES = the segment of the installed copy, CF=1 if not found.
;
;  There is no fixed vector to follow, because which ones got hooked depends on
;  what the BIOS left dummied. So: look for any vector whose OFFSET is exactly
;  the stub address that vector would have been given, then confirm the segment
;  really is a copy of this program by checking the signature. Two independent
;  facts have to agree, which is what stops a coincidence being believed.
; ===========================================================================
find_resident:
        push ax
        push bx
        push cx
        push dx
        push si
        push ds
        xor  ax, ax
        mov  ds, ax             ; DS = IVT
        xor  si, si
.f1:
        mov  bx, si
        shl  bx, 1
        shl  bx, 1
        mov  ax, si
        mov  cx, STUBSZ
        mul  cx
        add  ax, stubs
        cmp  ax, [bx]           ; the offset this vector would have been given
        jne  .f2
        mov  ax, [bx+2]
        mov  es, ax
        cmp  word [es:sig], 'IS'
        jne  .f2
        cmp  word [es:sig+2], 'PY'
        jne  .f2
        pop  ds
        mov  [resseg], ax
        clc
        jmp  short .fout
.f2:
        inc  si
        cmp  si, 256
        jb   .f1
        pop  ds
        stc
.fout:
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ===========================================================================
;  name_int -- one line naming the interrupt in AL, for the ones that matter
; ===========================================================================
name_int:
        mov  dx, msg_n15
        cmp  al, 0x15
        je   .say
        mov  dx, msg_n67
        cmp  al, 0x67
        je   .say
        mov  dx, msg_n33
        cmp  al, 0x33
        je   .say
        mov  dx, msg_n14
        cmp  al, 0x14
        je   .say
        mov  dx, msg_n17
        cmp  al, 0x17
        je   .say
        mov  dx, msg_n18
        cmp  al, 0x18
        je   .say
        mov  dx, msg_n1b
        cmp  al, 0x1B
        je   .say
        mov  dx, msg_crlf
.say:   call puts
        ret

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthexb:
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
msg_inst db 'INTSPY installed. $'
msg_inst2 db ' unimplemented vectors are now traced.',13,10,13,10
        db 'Run the program. If it hangs, READ THE 7-SEGMENT DISPLAY:',13,10
        db 'it holds the number of the last unimplemented interrupt called.',13,10
        db 'If it still shows the POST code, none were called at all.',13,10,13,10
        db 'Back at DOS:  intspy d   (counts)    intspy r   (remove)',13,10,'$'
msg_nodummy db 'INT FFh does not point at a BIOS IRET, so the dummy handler',13,10
        db 'cannot be identified. Nothing has been changed.',13,10,'$'
msg_notinst db 'INTSPY is not installed.',13,10,'$'
msg_already db 'INTSPY is already installed. Nothing has been changed.',13,10
        db 'Use  intspy d  to read the counts, or  intspy r  to remove it.',13,10,'$'
msg_dhdr db 'Unimplemented interrupts called since installation:',13,10,13,10,'$'
msg_dnone db 13,10,'None. Every interrupt that was called had a real handler.',13,10,'$'
msg_dtail db 13,10,'Each of these returned without doing anything, with the',13,10
        db "caller's own registers and flags handed straight back.",13,10,'$'
msg_rem db 'INTSPY removed. The BIOS dummy handler is back on every vector.',13,10
        db 'The resident copy is still in memory; reboot to reclaim it.',13,10,'$'
msg_int db '  INT $'
msg_x   db 'h  x $'
msg_n15 db '   system services - extended memory, config, wait',13,10,'$'
msg_n67 db '   EMS / expanded memory manager',13,10,'$'
msg_n33 db '   mouse driver',13,10,'$'
msg_n14 db '   serial port',13,10,'$'
msg_n17 db '   printer',13,10,'$'
msg_n18 db '   ROM BASIC',13,10,'$'
msg_n1b db '   Ctrl-Break',13,10,'$'
msg_crlf db 13,10,'$'

; ---------------------------------------------------------------------------
; Resident data. The signature is what find_resident confirms against, so it
; must stay inside the part that stays in memory.
        align 2
sig     db 'ISPY'
dummy   dd 0                    ; the BIOS handler we displaced
hooked  dw 0
shown   dw 0
resseg  dw 0
hits    times 256*2 db 0        ; one counter per vector
stubs   times 256*STUBSZ db 0   ; generated at install time
resident_end:
