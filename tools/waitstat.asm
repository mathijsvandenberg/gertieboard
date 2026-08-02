; ============================================================================
;  waitstat.asm  --  what does ONE memory read actually cost on this board?
;
;  RAMSPEED compares M9K against PSRAM and reports the difference. That answers
;  "which memory is slower" but not "is either of them fast", and those turned
;  out to be the important question: M9K read only 13% quicker than a serial
;  PSRAM, which is not what a 60 ns on-chip SRAM should look like next to one.
;  If the fixed cost per access is large enough, the memory behind it barely
;  matters -- and no amount of PSRAM tuning would help.
;
;  So this measures the fixed cost directly, by timing the SAME loop with and
;  without a memory operand:
;
;      A   mov al,bl     + loop        no data access at all
;      B   mov al,[si]   + loop        one read from M9K
;      C   mov al,[si]   + loop        one read from PSRAM, same address every
;                                      time, so always a cache hit
;      D   mov al,bl     + add si,16 + loop     baseline for E
;      E   mov al,[si]   + add si,16 + loop     PSRAM, a new 16-byte line every
;                                      iteration, so always a cache MISS
;
;  Every loop body is otherwise identical, so B-A, C-A and E-D each isolate the
;  cost of exactly one memory read, in clocks, with instruction fetch and loop
;  overhead cancelling out. D exists so the extra ADD in E cancels too.
;
;  Reference point: on an 8088 with no wait states, "mov al,[si]" costs 11
;  clocks more than "mov al,bl" -- 8 plus 5 for the effective address, against
;  2. Everything above 11 is the machine waiting. This is a V20, whose timings
;  differ a little, so treat 11 as a landmark and not a verdict; the comparison
;  that really matters is B against C. If a 60 ns on-chip read costs nearly the
;  same as a PSRAM read, the cost is in the handshake around the memory rather
;  than in the memory, and that is where the missing performance lives.
;
;  READ ONLY -- nothing is written anywhere. The M9K address is in low memory
;  and the PSRAM addresses are inside this program's own segment.
;
;  Build:  nasm -f bin waitstat.asm -o waitstat.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

OUTER   equ 8                   ; passes of a 65536-iteration inner loop
                                ; 8 * 65536 = 524288 iterations per test

start:
        mov  dx, msg_hdr
        call puts

        mov  ax, 0x40
        mov  es, ax             ; ES stays on the BDA for the tick counter

        mov  dx, msg_seg
        call puts
        mov  ax, cs
        call puthexw
        mov  dx, msg_seg2
        call puts

        mov  bl, 0x5A           ; a value for "mov al,bl" to move

; ---------------------------------------------------------------------------
;  A -- no memory operand
        push cs
        pop  ds
        mov  di, test_a
        call timeit
        mov  [t_a], ax
        mov  si, n_a
        call report

; ---------------------------------------------------------------------------
;  B -- one read from M9K.  Segment 0 offset 0x600 is physical 0x600, inside
;  the 0x00000-0x07FFF on-chip window. Read only, so nothing there minds.
        xor  ax, ax
        mov  ds, ax
        mov  si, 0x0600
        mov  di, test_mem
        call timeit
        push cs                 ; DS is still 0 here -- restore it BEFORE the
        pop  ds                 ; store, or [t_b] lands at 0000:t_b instead
        mov  [t_b], ax
        mov  si, n_b
        call report

; ---------------------------------------------------------------------------
;  C -- one read from PSRAM, same address every time.  After the first
;  iteration this line is cached, so every later read is a HIT and the PSRAM
;  interface itself is not involved at all. Whatever this costs above A is
;  pure overhead around the memory.
        push cs
        pop  ds
        mov  si, 0x0000
        mov  di, test_mem
        call timeit
        mov  [t_c], ax
        mov  si, n_c
        call report

; ---------------------------------------------------------------------------
;  D -- baseline with the extra ADD, so E has something honest to subtract
        push cs
        pop  ds
        mov  si, 0x0000
        mov  di, test_d
        call timeit
        mov  [t_d], ax
        mov  si, n_d
        call report

; ---------------------------------------------------------------------------
;  E -- PSRAM with a 16-byte stride. Lines are 16 bytes and there are only
;  four of them, so stepping by a whole line every time misses on every single
;  access. SI wraps inside our own 64 KB segment, so this stays read-only.
        push cs
        pop  ds
        mov  si, 0x0000
        mov  di, test_e
        call timeit
        mov  [t_e], ax
        push cs
        pop  ds
        mov  si, n_e
        call report

; ---------------------------------------------------------------------------
;  the answers
; ---------------------------------------------------------------------------
        mov  dx, msg_sum
        call puts

        mov  ax, [t_b]
        sub  ax, [t_a]
        mov  [d_m9k], ax
        mov  si, s_m9k
        call diffline

        mov  ax, [t_c]
        sub  ax, [t_a]
        mov  [d_hit], ax
        mov  si, s_hit
        call diffline

        mov  ax, [t_e]
        sub  ax, [t_d]
        mov  si, s_mis
        call diffline

        mov  dx, msg_ref
        call puts

        ; Which story do the numbers tell? The test is whether an on-chip read
        ; and a cached PSRAM read cost about the SAME. If they do, the memory
        ; type is not what is being paid for.
        mov  ax, [d_m9k]
        mov  bx, [d_hit]
        sub  ax, bx
        jns  .pos
        neg  ax
.pos:
        shl  ax, 1              ; is |B-A| - |C-A| within ~25% of the M9K cost?
        shl  ax, 1
        cmp  ax, [d_m9k]
        ja   .differs
        mov  dx, msg_same
        call puts
        jmp  short bye
.differs:
        mov  dx, msg_diff
        call puts
bye:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; timeit -- run the routine at DI, return AX = elapsed BIOS ticks.
; Starts on a tick boundary so the count is never short by a partial tick.
timeit:
        push bx
        push cx
        push dx
        push si
        mov  bx, [es:0x6C]
.sync:  cmp  bx, [es:0x6C]      ; wait for the edge
        je   .sync
        mov  bx, [es:0x6C]
        push bx
        call di
        pop  bx
        mov  ax, [es:0x6C]
        sub  ax, bx
        pop  si
        pop  dx
        pop  cx
        pop  bx
        ret

; ---------------------------------------------------------------------------
; The five loops. Identical in every respect except the operand under test.
; ---------------------------------------------------------------------------
test_a:
        mov  dx, OUTER
.o:     mov  cx, 0              ; 0 means 65536 times round
.i:     mov  al, bl
        loop .i
        dec  dx
        jnz  .o
        ret

test_mem:                       ; used for both B and C -- only DS:SI differs
        mov  dx, OUTER
.o:     mov  cx, 0
.i:     mov  al, [si]
        loop .i
        dec  dx
        jnz  .o
        ret

test_d:
        mov  dx, OUTER
.o:     mov  cx, 0
.i:     mov  al, bl
        add  si, 16
        loop .i
        dec  dx
        jnz  .o
        ret

test_e:
        mov  dx, OUTER
.o:     mov  cx, 0
.i:     mov  al, [si]
        add  si, 16
        loop .i
        dec  dx
        jnz  .o
        ret

; ---------------------------------------------------------------------------
; report -- SI = label, AX = ticks. Prints ticks and clocks per iteration.
report:
        push ax
        push dx
        mov  dx, si
        call puts
        pop  dx
        pop  ax
        push ax
        call putdec
        mov  dx, msg_gap
        call puts
        pop  ax
        call putclocks
        mov  dx, msg_crlf
        call puts
        ret

; diffline -- SI = label, AX = tick difference
diffline:
        push ax
        mov  dx, si
        call puts
        pop  ax
        call putclocks
        mov  dx, msg_clk
        call puts
        ret

; ---------------------------------------------------------------------------
; putclocks -- AX = ticks over 524288 iterations, printed as clocks.tenths
;
;   one tick        = 54925 us
;   one iteration   = ticks * 54925us / 524288
;   one 5 MHz clock = 0.2 us
;   so clocks       = ticks * 54925 / 524288 / 0.2 = ticks * 0.5238
;   in tenths       = ticks * 5238 / 1000
putclocks:
        push ax
        push bx
        push cx
        push dx
        mov  bx, 5238
        mul  bx                 ; DX:AX = ticks * 5238
        mov  bx, 1000
        div  bx                 ; AX = tenths of a clock
        xor  dx, dx
        mov  bx, 10
        div  bx                 ; AX = whole clocks, DX = tenths digit
        push dx
        call putdec
        mov  al, '.'            ; putch takes the character in AL, not DL
        call putch
        pop  ax
        add  al, '0'
        call putch
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
putch:  push ax
        push dx
        mov  dl, al
        mov  ah, 2
        int  0x21
        pop  dx
        pop  ax
        ret

puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthexw:
        push ax
        push bx
        push cx
        push dx
        mov  bx, ax
        mov  cx, 4
.h1:    rol  bx, 1
        rol  bx, 1
        rol  bx, 1
        rol  bx, 1
        mov  al, bl
        and  al, 0x0F
        cmp  al, 10
        jb   .h2
        add  al, 'A'-10
        jmp  short .h3
.h2:    add  al, '0'
.h3:    call putch
        loop .h1
        pop  dx
        pop  cx
        pop  bx
        pop  ax
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
        call putch
        loop .d2
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
t_a     dw 0
t_b     dw 0
t_c     dw 0
t_d     dw 0
t_e     dw 0
d_m9k   dw 0
d_hit   dw 0

msg_hdr db 'WAITSTAT - what does one memory read cost on this board?',13,10
        db '--------------------------------------------------------',13,10
        db 'Times the same loop with and without a memory operand, so',13,10
        db 'the difference is one read and nothing else. 524288',13,10
        db 'iterations per test; about twenty seconds in total.',13,10,13,10,'$'
msg_seg db 'This program is loaded at segment $'
msg_seg2 db ', which is above 0800h',13,10
        db 'and therefore in PSRAM -- so is its code.',13,10,13,10
        db '                                    ticks   clocks/iter',13,10,'$'

n_a     db '  A  no memory   mov al,bl          $'
n_b     db '  B  M9K read    mov al,[si]        $'
n_c     db '  C  PSRAM hit   mov al,[si]        $'
n_d     db '  D  no memory   mov al,bl  +add    $'
n_e     db '  E  PSRAM miss  mov al,[si]+add    $'

msg_sum db 13,10,'Cost of one read, with everything else cancelled out:',13,10,13,10,'$'
s_m9k   db '  one M9K read          B-A  = $'
s_hit   db '  one PSRAM cache hit   C-A  = $'
s_mis   db '  one PSRAM cache miss  E-D  = $'
msg_clk db ' clocks',13,10,'$'

msg_ref db 13,10
        db 'On an 8088 with no wait states, mov al,[si] costs 11 clocks',13,10
        db 'more than mov al,bl (8 plus 5 for the address, against 2).',13,10
        db 'Anything above 11 is the machine waiting. The V20 differs a',13,10
        db 'little, so read 11 as a landmark rather than a verdict.',13,10,13,10,'$'

msg_same db 'M9K and a cached PSRAM read cost about the SAME.',13,10,13,10
        db 'A 60 ns on-chip SRAM and a serial PSRAM cannot genuinely be',13,10
        db 'equal, so what is being paid for is not the memory -- it is',13,10
        db 'the handshake around it. Faster PSRAM would not help, and',13,10
        db 'the fixed cost per access is where the performance went.',13,10,'$'
msg_diff db 'M9K is meaningfully cheaper than a cached PSRAM read.',13,10,13,10
        db 'The cost tracks which memory answers, so the handshake is',13,10
        db 'not the dominant term and the PSRAM interface is worth',13,10
        db 'attacking after all.',13,10,'$'
msg_gap db '     $'
msg_crlf db 13,10,'$'
