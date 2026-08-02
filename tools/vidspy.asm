; ============================================================================
;  vidspy.asm  --  did the BIOS video call RETURN, and which one was it
;
;  BIOSSPY narrowed a hang to "the last thing it asked for was video, and then
;  it never asked for anything again". That is two completely different faults
;  wearing the same face:
;
;      the call returned, and the program then spun in its own code
;      the call never returned, and the BIOS is the thing that is stuck
;
;  BIOSSPY cannot tell them apart, because it marks a call on the way IN and
;  then chains away. This one marks both ends.
;
;  Instead of chaining, the video stub invokes the real handler as a subroutine
;  -- PUSHF then a far CALL, which is exactly what an INT does -- so control
;  comes back here afterwards and the return can be recorded. What lands on the
;  7-segment display:
;
;      00..1F   ENTERING that INT 10h function, by its real AH
;      Ex       a video call RETURNED (x counts them, so it moves)
;
;  Reading a frozen display:
;
;      stuck on a low value    the BIOS video handler for THAT function never
;                              came back. The number is the AH to go and read.
;
;      stuck on Ex             every video call completed. The program is
;                              spinning in its own code, and video is innocent.
;
;  And the separate question of whether anything is running at all:
;
;      vidspy t                hook the timer tick instead, and show Fx on
;                              every one. Cycling = interrupts are still being
;                              serviced. Frozen = they are not.
;
;  Those are kept in separate runs on purpose. They compete for one display,
;  and a timer heartbeat firing 18 times a second would overwrite the video
;  state within a tick of it mattering.
;
;      vidspy            trace INT 10h, both ends
;      vidspy t          timer heartbeat only
;      vidspy r          remove
;
;  Build:  nasm -f bin vidspy.asm -o vidspy.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

SEG7    equ 0x80

start:
        mov  al, [0x80]
        test al, al
        jz   inst_vid
        mov  cl, al
        mov  ch, 0
        mov  si, 0x81
.scan:  lodsb
        cmp  al, ' '
        je   .next
        and  al, 0xDF
        cmp  al, 'T'
        je   inst_tick
        cmp  al, 'R'
        je   remove
        jmp  short inst_vid
.next:  loop .scan

; ===========================================================================
inst_vid:
        call find_resident
        jnc  already
        xor  ax, ax
        mov  es, ax
        mov  ax, [es:0x10*4]
        mov  [old10], ax
        mov  ax, [es:0x10*4+2]
        mov  [old10+2], ax
        cli                             ; both halves together, or an
        mov  word [es:0x10*4], stub10   ; interrupt landing between them
        mov  [es:0x10*4+2], cs          ; goes nowhere
        sti
        mov  dx, msg_vid
        call puts
        jmp  short stay

inst_tick:
        call find_resident
        jnc  already
        xor  ax, ax
        mov  es, ax
        mov  ax, [es:0x08*4]
        mov  [old08], ax
        mov  ax, [es:0x08*4+2]
        mov  [old08+2], ax
        cli
        mov  word [es:0x08*4], stub08
        mov  [es:0x08*4+2], cs
        sti
        mov  dx, msg_tick
        call puts

stay:
        mov  dx, (resident_end - start + 0x10F) / 16
        mov  ax, 0x3100         ; terminate and stay resident
        int  0x21

already:
        mov  dx, msg_already
        call puts
        jmp  short bye

; ===========================================================================
remove:
        call find_resident
        jc   .notthere
        ; the saved vectors live in the copy that installed them
        mov  ax, [es:old10]
        mov  [old10], ax
        mov  ax, [es:old10+2]
        mov  [old10+2], ax
        mov  ax, [es:old08]
        mov  [old08], ax
        mov  ax, [es:old08+2]
        mov  [old08+2], ax
        mov  bx, [resseg]

        xor  ax, ax
        mov  es, ax
        cmp  word [es:0x10*4+2], bx
        jne  .no10
        cli
        mov  ax, [old10]
        mov  [es:0x10*4], ax
        mov  ax, [old10+2]
        mov  [es:0x10*4+2], ax
        sti
.no10:
        cmp  word [es:0x08*4+2], bx
        jne  .no08
        cli
        mov  ax, [old08]
        mov  [es:0x08*4], ax
        mov  ax, [old08+2]
        mov  [es:0x08*4+2], ax
        sti
.no08:
        mov  dx, msg_rem
        call puts
        jmp  short bye
.notthere:
        mov  dx, msg_notinst
        call puts
bye:
        mov  ax, 0x4C00
        int  0x21

; ===========================================================================
; find_resident -- ES = the installed copy, CF=1 if not installed. Either hook
; identifies it, since only one of the two is ever in place.
; ===========================================================================
find_resident:
        push ax
        push ds
        xor  ax, ax
        mov  ds, ax
        mov  ax, [0x10*4]
        cmp  ax, stub10
        jne  .try08
        mov  ax, [0x10*4+2]
        jmp  short .check
.try08:
        mov  ax, [0x08*4]
        cmp  ax, stub08
        jne  .no
        mov  ax, [0x08*4+2]
.check:
        mov  es, ax
        cmp  word [es:sig], 'VS'
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

msg_vid db 'VIDSPY installed on INT 10h, marking BOTH ends of every call.',13,10,13,10
        db '  00..1F  entering that video function, by its real AH',13,10
        db '  Ex      a video call returned (x counts them, so it moves)',13,10,13,10
        db 'Run the program. If the display freezes on a LOW value, the BIOS',13,10
        db 'video handler for that AH never came back and the BIOS is at',13,10
        db 'fault. If it freezes on Ex, every video call completed and the',13,10
        db 'program is spinning in its own code.',13,10,13,10
        db 'Then run  vidspy t  on a fresh boot for the timer heartbeat.',13,10,'$'
msg_tick db 'VIDSPY installed on the timer tick. Every tick shows Fx.',13,10,13,10
        db 'Cycling = interrupts are still being serviced, so the machine is',13,10
        db 'alive and the program is spinning with the lights on.',13,10
        db 'Frozen = they are not, and that is the fault itself.',13,10,13,10
        db 'A game that takes INT 08h and never chains it would also look',13,10
        db 'frozen here, so read this one together with the video run.',13,10,'$'
msg_already db 'VIDSPY is already installed. Reboot before changing mode.',13,10,'$'
msg_notinst db 'VIDSPY is not installed.',13,10,'$'
msg_rem db 'VIDSPY removed.',13,10,'$'

resseg  dw 0

; ---------------------------------------------------------------------------
; Resident part.
        align 2
sig     db 'VSPY'
ctr     db 0
old10   dd 0
old08   dd 0

; ---------------------------------------------------------------------------
; stub10 -- show AH going in, then CALL the real handler rather than jumping to
; it, so there is somewhere to come back to.
;
; PUSHF followed by a far CALL is precisely the stack frame an INT builds, so
; the real handler's IRET returns here with its own work finished. The closing
; IRET then unwinds the caller's original frame, which restores the caller's
; flags exactly as a real INT 10h would.
;
; AX is saved around both markers: several video functions return values in it,
; and a diagnostic that eats them would create the bug it is looking for.
; ---------------------------------------------------------------------------
stub10:
        pushf
        push ax
        mov  al, ah             ; the function number itself, not a code for it
        out  SEG7, al
        pop  ax
        popf

        pushf                   ; == what INT pushes
        call far [cs:old10]

        push ax                 ; it came back. Say so.
        mov  al, [cs:ctr]
        inc  al
        and  al, 0x0F
        mov  [cs:ctr], al
        or   al, 0xE0
        out  SEG7, al
        pop  ax
        iret

; ---------------------------------------------------------------------------
; stub08 -- heartbeat. Chains, so the BIOS tick keeps its own time.
; ---------------------------------------------------------------------------
stub08:
        pushf
        push ax
        mov  al, [cs:ctr]
        inc  al
        and  al, 0x0F
        mov  [cs:ctr], al
        or   al, 0xF0
        out  SEG7, al
        pop  ax
        popf
        jmp  far [cs:old08]
resident_end:
