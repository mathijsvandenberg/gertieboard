; ============================================================================
;  186boost.asm  --  enable the BIOS's 80186 fast path for USB reads
;
;  The USB read loop has two implementations. The default moves a packet a byte
;  at a time with "in al,dx / stosb / loop", which any 8086 or 8088 can execute.
;  The other moves the whole packet with a single REP INSB and measures 1.66x
;  faster end to end -- 65 to 108 KB/s at 32 KB transfers.
;
;  REP INSB is an 80186 instruction. This board's socket is happy to hold either
;  a NEC V20, which implements the 80186 additions, or a real Intel 8088-1,
;  which does not: opcode 6C is undefined there and executing it is not
;  survivable.
;
;  POST now runs the same probe this tool does and picks the path itself, so
;  none of this is needed to get the speed -- it is already on. What this is
;  still for is taking it AWAY: turning the fast path off is how you benchmark
;  one against the other on the same boot, which is the only honest way to
;  measure what a change is worth.
;
;      186boost           report what the CPU is and whether the boost is on
;      186boost on        enable it, if the CPU test passes
;      186boost off       back to the 8086-safe loop
;      186boost on /f     enable without the test -- see the warning below
;
;  The test executes opcode 6C and sees what happened. On a V20 that is INSB;
;  on an 8088 it is JZ, because the 8086 family decodes 60-6F as aliases of the
;  conditional jumps at 70-7F. The surrounding bytes are arranged so both
;  readings are harmless and land on the same instruction -- see cputest.
;
;  POST clears the flag on every boot, so this is not sticky -- put it in
;  AUTOEXEC.BAT if you want it. That is deliberate: swapping the CPU must never
;  leave a fast path armed for a processor that cannot execute it.
;
;  Build:  nasm -f bin 186boost.asm -o 186boost.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; this tool itself must run on either CPU

BIOSSEG equ 0xF000              ; the BIOS image, in writable PSRAM

start:
        mov  dx, msg_hdr
        call puts

        ; ---- where does the BIOS keep the flag? ----
        ; POST publishes the offset; there is no other way to find it, and
        ; hardcoding it would rot the first time the BIOS is rebuilt.
        mov  ax, 0x40
        mov  es, ax
        mov  ax, [es:0xBC]
        mov  [flagoff], ax
        test ax, ax
        jnz  .havebios
        mov  dx, msg_nobios
        call puts
        jmp  bye
.havebios:

        ; ---- what is in the socket? ----
        call cputest
        mov  [is186], al
        mov  dx, msg_cpu
        call puts
        mov  dx, msg_cpu8086
        cmp  byte [is186], 0
        je   .saycpu
        mov  dx, msg_cpu186
.saycpu:
        call puts

        call parse_args

        ; ---- act ----
        cmp  byte [action], 'N'
        je   .enable
        cmp  byte [action], 'F'
        je   .disable
        jmp  .report

.enable:
        cmp  byte [is186], 0
        jne  .doenable
        cmp  byte [force], 0
        jne  .doenable
        mov  dx, msg_refuse
        call puts
        jmp  .report
.doenable:
        mov  ax, BIOSSEG
        mov  es, ax
        mov  bx, [flagoff]
        mov  byte [es:bx], 1
        mov  dx, msg_on
        call puts
        jmp  short .report

.disable:
        mov  ax, BIOSSEG
        mov  es, ax
        mov  bx, [flagoff]
        mov  byte [es:bx], 0
        mov  dx, msg_off
        call puts

.report:
        ; read the flag back rather than reporting what we think we wrote --
        ; the F-segment is RAM, and a write that did not land should show
        mov  ax, BIOSSEG
        mov  es, ax
        mov  bx, [flagoff]
        mov  al, [es:bx]
        mov  dx, msg_state
        call puts
        mov  dx, msg_slow
        test al, al
        jz   .say
        mov  dx, msg_fast
.say:   call puts
bye:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; cputest -- AL = 1 if this CPU can execute INSB, 0 if it cannot.
;
; It asks about the exact instruction the BIOS wants to use, rather than
; inferring the answer from some other behaviour. An earlier version asked
; whether shift counts are masked to five bits, on the theory that a V20
; behaves like an 80186 there. It does not -- NEC kept the 8086's quirks and
; only ADDED instructions -- so a V20 answered exactly like an 8088 and the
; fast path was refused on the very CPU that supports it.
;
; The probe rests on a documented 8086 property: opcodes 60-6F decode as
; aliases of 70-7F, the conditional jumps. So 6C is INSB on a V20 or 80186,
; and JZ rel8 on an 8088 -- one byte against two. Line the byte counts up and
; both CPUs resume at the same instruction:
;
;   6C 06   V20:  INSB, then PUSH ES      8088: JZ +6, taken because ZF=1
;   07      V20:  POP ES                  8088: jumped over
;   43      V20:  INC BX                  8088: jumped over
;   90 x4   V20:  NOP                     8088: jumped over
;
; Six bytes skipped, six of displacement. Every byte is harmless whichever way
; it decodes, the PUSH/POP pair balances the stack on the V20 path, and BX says
; which CPU it was.
cputest:
        push bx
        push dx
        push di
        push es
        cld
        push cs
        pop  es
        mov  di, scratch        ; somewhere harmless for INSB to write
        mov  dx, 0xEF           ; reading the diag window has no side effect
        xor  bx, bx
        xor  ax, ax             ; ZF = 1, and nothing below disturbs it
        db   0x6C, 0x06         ; INSB + PUSH ES   |   JZ +6
        db   0x07               ; POP ES     -- V20 only
        db   0x43               ; INC BX     -- V20 only
        db   0x90, 0x90, 0x90, 0x90
        mov  al, 0
        test bx, bx
        jz   .done
        mov  al, 1
.done:  pop  es
        pop  di
        pop  dx
        pop  bx
        ret

; ---------------------------------------------------------------------------
parse_args:
        push ax
        push cx
        push si
        mov  byte [action], 0
        mov  byte [force], 0
        mov  cl, [0x80]
        mov  ch, 0
        jcxz .out
        mov  si, 0x81
.scan:  lodsb
        cmp  al, '/'
        jne  .n1
        mov  byte [force], 1
        jmp  short .next
.n1:    and  al, 0xDF
        cmp  al, 'F'            ; the F of OFF, or of /F
        jne  .n2
        cmp  byte [force], 0
        jne  .next              ; part of /F, already handled
        cmp  byte [action], 0
        jne  .next
        mov  byte [action], 'F'
        jmp  short .next
.n2:    cmp  al, 'N'
        jne  .next
        cmp  byte [action], 0
        jne  .next
        mov  byte [action], 'N'
.next:  loop .scan
.out:
        pop  si
        pop  cx
        pop  ax
        ret

puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

; ---------------------------------------------------------------------------
msg_hdr   db '186BOOST - 80186 fast path for USB reads',13,10
          db 'POST sets this automatically. Use this to turn it OFF and',13,10
          db 'benchmark the two paths against each other.',13,10
          db '---------------------------------------------------------',13,10,'$'
msg_nobios db 'This BIOS does not publish a boost flag (BDA 40:BC is zero),',13,10
          db 'so it has no fast path to enable.',13,10,'$'
msg_cpu   db 'CPU       : $'
msg_cpu186 db 'INSB executes - 80186 class (a V20 or better)',13,10,'$'
msg_cpu8086 db 'no INSB - plain 8086/8088',13,10,'$'
msg_refuse db 13,10,'REFUSED. This CPU does not appear to implement the 80186',13,10
          db 'additions, and REP INSB would be an undefined opcode on it.',13,10
          db 'If you are certain the test is wrong, "186boost on /f" will',13,10
          db 'set it anyway -- but a wrong answer here hangs the machine on',13,10
          db 'the next disk read, so be certain.',13,10,'$'
msg_on    db 13,10,'Fast path ENABLED.',13,10,'$'
msg_off   db 13,10,'Fast path disabled - back to the 8086-safe loop.',13,10,'$'
msg_state db 'USB reads : $'
msg_fast  db 'REP INSB (about 1.66x faster)',13,10,'$'
msg_slow  db 'byte loop (works on any 8086 or 8088)',13,10,'$'

flagoff dw 0
scratch db 0            ; one byte for the probe's INSB to land in
is186   db 0
action  db 0
force   db 0
