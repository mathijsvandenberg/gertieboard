; ============================================================================
;  biosspy.asm  --  show which BIOS service is being used, live, on the
;                   7-segment display -- so a program that hangs still talks
;
;  INTSPY answered "is it stuck on an interrupt this BIOS does not implement?"
;  with a clean no. This asks the next question: what was the LAST thing it
;  asked the machine for before it stopped, and is it still asking for anything
;  at all.
;
;  It hooks the BIOS services a program actually uses -- video, disk, keyboard,
;  clock and the rest -- and chains every one of them straight through. Nothing
;  is blocked, nothing is answered differently. Each stub writes one byte to
;  port 0x80 on its way past:
;
;      high nibble = WHICH service          low nibble = a call counter
;
;  The counter is what makes this readable. A display sitting still and a
;  display being hammered look identical if you only show the service number,
;  and those are opposite diagnoses. With the counter in the low digit:
;
;    low digit racing, high digit steady    the program is polling that one
;                                           service forever -- e.g. 7x is
;                                           waiting on a key that never comes
;
;    low digit racing, high digit varying   it is WORKING, just slowly. Leave
;                                           it running before calling it a hang
;
;    both digits frozen                     no BIOS calls at all. It is spinning
;                                           inside its own code, and the high
;                                           digit is the last service it used --
;                                           which is where to start looking
;
;  Nothing here depends on the program's cooperation. Games hook INT 08h and
;  INT 09h and stop chaining them, which is why sampling from a timer hook is
;  unreliable; but they CALL 10h/13h/16h/1Ah rather than replacing them, so
;  these hooks cannot be bypassed.
;
;      biosspy           install
;      biosspy d         per-service call counts, if DOS came back
;      biosspy r         remove
;
;  Service codes -- the high digit on the display:
;
;      1 video 10h    4 disk   13h    7 keyboard 16h
;      2 equip 11h    5 serial 14h    8 printer  17h
;      3 memory 12h   6 system 15h    9 clock    1Ah
;
;  Build:  nasm -f bin biosspy.asm -o biosspy.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

SEG7    equ 0x80                ; 7-segment display

; ---------------------------------------------------------------------------
; One hook. %1 = vector number in DECIMAL (it becomes part of a label, so it
; cannot be written in hex), %2 = the service code shown in the high nibble.
;
; The stub must be transparent in both directions: AX is saved and restored,
; and the flags are saved around it because the arithmetic below would
; otherwise reach the real handler. The far JMP leaves the caller's IP, CS and
; FLAGS untouched on the stack, so the real handler's IRET returns to the
; caller exactly as if we had never been here.
; ---------------------------------------------------------------------------
%macro HOOK 2
stub%1:
        pushf
        push ax
        mov  al, [cs:ctr]
        inc  al
        and  al, 0x0F
        mov  [cs:ctr], al
        or   al, %2 << 4
        out  SEG7, al
        inc  word [cs:cnt%1]
        pop  ax
        popf
        jmp  far [cs:old%1]
%endmacro

%macro INSTALL 1
        mov  ax, [es:%1*4]
        mov  [old%1], ax
        mov  ax, [es:%1*4+2]
        mov  [old%1+2], ax
        cli                     ; both halves together, or an interrupt
        mov  word [es:%1*4], stub%1     ; landing between them goes nowhere
        mov  [es:%1*4+2], cs
        sti
%endmacro

start:
        mov  al, [0x80]
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

; ===========================================================================
install:
        call find_resident
        jnc  .already

        xor  ax, ax
        mov  es, ax
        INSTALL 16
        INSTALL 17
        INSTALL 18
        INSTALL 19
        INSTALL 20
        INSTALL 21
        INSTALL 22
        INSTALL 23
        INSTALL 26

        mov  dx, msg_inst
        call puts
        mov  dx, (resident_end - start + 0x10F) / 16
        mov  ax, 0x3100         ; terminate and stay resident
        int  0x21
.already:
        mov  dx, msg_already
        call puts
        jmp  bye

; ===========================================================================
; dump -- read the counters out of the installed copy
; ===========================================================================
dump:
        call find_resident
        jc   .notthere
        mov  dx, msg_dhdr
        call puts

        mov  si, tbl
.d1:    mov  al, [si]           ; vector number
        cmp  al, 0xFF
        je   .ddone
        push si
        mov  dx, msg_i
        call puts
        mov  al, [si]
        call puthexb
        mov  dx, msg_ix
        call puts
        mov  bx, [si+1]         ; offset of this service's counter
        mov  ax, [es:bx]
        call putdec
        mov  dx, [si+3]         ; its name
        call puts
        pop  si
        add  si, 7              ; vector + counter + name + saved vector
        jmp  short .d1
.ddone:
        mov  dx, msg_dtail
        call puts
        jmp  short bye
.notthere:
        mov  dx, msg_notinst
        call puts
        jmp  short bye

; ===========================================================================
remove:
        call find_resident      ; ES = the resident copy, [resseg] set HERE
        jc   dump.notthere

        ; The saved vectors were recorded by the copy that did the installing,
        ; not by this one. Pull them across first, so everything below reads
        ; from our own DS and there is no segment to keep straight.
        mov  si, old16
        mov  di, old16
        mov  cx, 9*2            ; nine dwords
.rc:    mov  ax, [es:si]
        mov  [di], ax
        add  si, 2
        add  di, 2
        loop .rc

        xor  ax, ax
        mov  es, ax             ; ES = IVT
        call unhook
        mov  dx, msg_rem
        call puts
bye:
        mov  ax, 0x4C00
        int  0x21

; unhook -- ES = IVT, DS = ours. Restores every vector still pointing into the
; resident copy, and leaves alone any that a later program took over.
unhook:
        push si
        push di
        mov  si, tbl
.u1:    mov  al, [si]
        cmp  al, 0xFF
        je   .udone
        mov  bl, al
        mov  bh, 0
        shl  bx, 1
        shl  bx, 1              ; bx = vector * 4
        mov  ax, [es:bx+2]
        cmp  ax, [resseg]       ; still ours?
        jne  .unext
        mov  di, [si+5]         ; where this stub's saved vector lives
        cli
        mov  ax, [di]
        mov  [es:bx], ax
        mov  ax, [di+2]
        mov  [es:bx+2], ax
        sti
.unext: add  si, 7
        jmp  short .u1
.udone: pop  di
        pop  si
        ret

; ===========================================================================
; find_resident -- ES = the installed copy's segment, CF=1 if not installed.
; INT 10h is the anchor: it is always hooked, so if the vector points at our
; stub offset AND that segment carries the signature, it is us.
; ===========================================================================
find_resident:
        push ax
        push ds
        xor  ax, ax
        mov  ds, ax
        mov  ax, [0x10*4]
        cmp  ax, stub16
        jne  .no
        mov  ax, [0x10*4+2]
        mov  es, ax
        cmp  word [es:sig], 'BS'
        jne  .no
        cmp  word [es:sig+2], 'PY'
        jne  .no
        pop  ds
        mov  [resseg], ax
        clc
        jmp  short .out
.no:    pop  ds
        stc
.out:   pop  ax
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
msg_inst db 'BIOSSPY installed. Nine BIOS services now report to the',13,10
        db '7-segment display, and every call still chains through.',13,10,13,10
        db '  high digit = service     low digit = call counter',13,10,13,10
        db '  1 video 10h   4 disk   13h   7 keyboard 16h',13,10
        db '  2 equip 11h   5 serial 14h   8 printer  17h',13,10
        db '  3 memory 12h  6 system 15h   9 clock    1Ah',13,10,13,10
        db 'Run the program and watch the display:',13,10
        db '  low digit racing, high steady  -> polling that service forever',13,10
        db '  low digit racing, high varying -> working, just slowly. WAIT.',13,10
        db '  both frozen                    -> spinning in its own code, and',13,10
        db '     the high digit is the last service it used before it stopped.',13,10,'$'
msg_already db 'BIOSSPY is already installed. Nothing has been changed.',13,10,'$'
msg_notinst db 'BIOSSPY is not installed.',13,10,'$'
msg_dhdr db 'BIOS calls since installation:',13,10,13,10,'$'
msg_dtail db 13,10,'A service with a count of zero was never asked for at all.',13,10,'$'
msg_rem db 'BIOSSPY removed. Any vector a later program took over is left',13,10
        db 'alone. The resident copy stays in memory; reboot to reclaim it.',13,10,'$'
msg_i   db '  INT $'
msg_ix  db 'h  x $'

n10     db '   video',13,10,'$'
n11     db '   equipment list',13,10,'$'
n12     db '   memory size',13,10,'$'
n13     db '   disk',13,10,'$'
n14     db '   serial',13,10,'$'
n15     db '   system services',13,10,'$'
n16     db '   keyboard',13,10,'$'
n17     db '   printer',13,10,'$'
n1a     db '   clock',13,10,'$'

; vector, counter offset, name, saved-vector offset -- 7 bytes per entry
tbl     db 0x10
        dw cnt16, n10, old16
        db 0x11
        dw cnt17, n11, old17
        db 0x12
        dw cnt18, n12, old18
        db 0x13
        dw cnt19, n13, old19
        db 0x14
        dw cnt20, n14, old20
        db 0x15
        dw cnt21, n15, old21
        db 0x16
        dw cnt22, n16, old22
        db 0x17
        dw cnt23, n17, old23
        db 0x1A
        dw cnt26, n1a, old26
        db 0xFF

resseg  dw 0

; ---------------------------------------------------------------------------
; Resident part. The stubs and everything they touch must stay in memory.
        align 2
sig     db 'BSPY'
ctr     db 0

old16   dd 0
old17   dd 0
old18   dd 0
old19   dd 0
old20   dd 0
old21   dd 0
old22   dd 0
old23   dd 0
old26   dd 0

cnt16   dw 0
cnt17   dw 0
cnt18   dw 0
cnt19   dw 0
cnt20   dw 0
cnt21   dw 0
cnt22   dw 0
cnt23   dw 0
cnt26   dw 0

        HOOK 16, 1              ; INT 10h  video
        HOOK 17, 2              ; INT 11h  equipment
        HOOK 18, 3              ; INT 12h  memory size
        HOOK 19, 4              ; INT 13h  disk
        HOOK 20, 5              ; INT 14h  serial
        HOOK 21, 6              ; INT 15h  system services
        HOOK 22, 7              ; INT 16h  keyboard
        HOOK 23, 8              ; INT 17h  printer
        HOOK 26, 9              ; INT 1Ah  clock
resident_end:
