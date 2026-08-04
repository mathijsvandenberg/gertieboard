; ============================================================================
;  cpuclk.asm  --  why does POST report an impossible CPU clock?
;
;  The BIOS measures the CPU clock by timing a LOOP against PIT channel 2. It
;  has produced two readings from the same code: 1.54 MHz with the loop copied
;  into low RAM, and 94.82 MHz with it running in place. Those imply about 81
;  and about 1.3 clocks per LOOP iteration. Neither is possible, and they are
;  60x apart, so the fault is in the MEASUREMENT and not in the calibration
;  constant. Scaling the constant to make either number look right would only
;  bake the error in where it cannot be seen.
;
;  POST can print one line and cannot be stepped. This runs the identical
;  sequence and prints every intermediate value, so the wrong one is visible
;  rather than inferred.
;
;  TEST 1 is the one that settles it, and it rests on nothing that can be
;  argued about. Channel 2 is timed against the BIOS tick -- both come from the
;  same 8253, and the tick is a known 54.925 ms -- so it needs no assumption
;  about the CPU at all:
;
;      expected delta = 54.925 ms x 1.1905 MHz = about 65388 counts
;
;  If that comes back right, channel 2 counts at the rate the arithmetic
;  assumes and the fault is in the loop timing. If it comes back wrong, the
;  latch-and-read is broken and every figure built on it is meaningless.
;
;  It sits just under 65536, so a correct reading nearly fills the counter.
;  Anything much larger has wrapped; anything much smaller has not counted.
;
;  Build:  nasm -f bin cpuclk.asm -o cpuclk.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

CAL_ITER  equ 4096              ; same as the BIOS
PIT_HZ_10 equ 11905             ; c2 in units of 100 Hz, for integer maths

start:
        mov  dx, msg_hdr
        call puts

        mov  ax, 0x40
        mov  es, ax             ; ES on the BDA for the tick counter

; ---------------------------------------------------------------------------
;  1  Does channel 2 count, and at the rate everything else assumes?
; ---------------------------------------------------------------------------
        mov  dx, msg_t1
        call puts

        call pit2_arm
        ; align to a tick edge, then measure across exactly one tick
        mov  bx, [es:0x6C]
.sync:  cmp  bx, [es:0x6C]
        je   .sync
        call pit2_read
        mov  si, ax                     ; channel 2 at the start of the tick
        mov  bx, [es:0x6C]
.wait:  cmp  bx, [es:0x6C]
        je   .wait
        call pit2_read
        mov  di, ax                     ; and at the end

        mov  dx, msg_start
        call puts
        mov  ax, si
        call putdec
        mov  dx, msg_end
        call puts
        mov  ax, di
        call putdec
        mov  dx, msg_delta
        call puts
        mov  ax, si
        sub  ax, di                     ; counts DOWN
        mov  [d1], ax
        call putdec
        mov  dx, msg_exp1
        call puts

        ; verdict, with a generous window -- this is looking for "wrong by a
        ; factor", not for a percent
        mov  ax, [d1]
        mov  dx, msg_v_dead
        cmp  ax, 1000
        jb   .v1
        mov  dx, msg_v_slow
        cmp  ax, 55000
        jb   .v1
        mov  dx, msg_v_ok
        cmp  ax, 65535
        jbe  .v1
        mov  dx, msg_v_odd
.v1:    call puts

; ---------------------------------------------------------------------------
;  2  The loop, timed exactly as the BIOS times it
; ---------------------------------------------------------------------------
        mov  dx, msg_t2
        call puts

        call pit2_arm
        call pit2_read
        mov  si, ax
        mov  cx, CAL_ITER
        call cal_loop
        call pit2_read
        mov  di, ax

        mov  dx, msg_start
        call puts
        mov  ax, si
        call putdec
        mov  dx, msg_end
        call puts
        mov  ax, di
        call putdec
        mov  dx, msg_delta
        call puts
        mov  ax, si
        sub  ax, di
        mov  [d2], ax
        call putdec
        mov  dx, msg_crlf
        call puts

; ---------------------------------------------------------------------------
;  What the two together imply
; ---------------------------------------------------------------------------
        mov  dx, msg_sum
        call puts

        ; microseconds for the loop = delta2 * 1e6 / 1190500  ~= delta2 * 84 / 100
        mov  ax, [d2]
        mov  bx, 84
        mul  bx
        mov  bx, 100
        div  bx
        push ax
        mov  dx, msg_us
        call puts
        pop  ax
        push ax
        call putdec
        mov  dx, msg_crlf
        call puts

        ; clocks per iteration at an ASSUMED 5 MHz = us * 5 / 4096
        pop  ax
        mov  bx, 5
        mul  bx
        mov  bx, CAL_ITER
        div  bx
        push ax
        mov  dx, msg_cpi
        call puts
        pop  ax
        call putdec
        mov  dx, msg_cpi2
        call puts

        mov  dx, msg_tail
        call puts
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; pit2_arm -- gate on, speaker silent, mode 0, full 16-bit count.
; Exactly what the BIOS does, so this measures the same thing.
pit2_arm:
        push ax
        push dx
        in   al, 0x61
        and  al, 0xFD           ; speaker data OFF -- silent
        or   al, 0x01           ; gate 2 ON
        out  0x61, al
        mov  al, 0xB0           ; ch2, lo/hi, mode 0, binary
        out  0x43, al
        mov  al, 0xFF
        out  0x42, al
        out  0x42, al
        pop  dx
        pop  ax
        ret

; pit2_read -- AX = channel 2, via the counter-latch command
pit2_read:
        push bx
        mov  al, 0x80           ; latch counter 2
        out  0x43, al
        in   al, 0x42
        mov  bl, al             ; LSB first
        in   al, 0x42
        mov  bh, al             ; then MSB
        mov  ax, bx
        pop  bx
        ret

; the calibration loop: CX iterations of a two-byte LOOP
cal_loop:
        db   0xE2, 0xFE         ; loop $
        ret

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 9
        int  0x21
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
d1      dw 0
d2      dw 0

msg_hdr db 'CPUCLK - why is the measured CPU clock impossible?',13,10
        db '--------------------------------------------------',13,10
        db 'POST has reported 1.54 MHz and 94.82 MHz from the same code.',13,10
        db 'Both imply a LOOP cost no CPU can have, so the fault is in the',13,10
        db 'measurement. This prints every value POST cannot show.',13,10,'$'

msg_t1  db 13,10,'1  Does PIT channel 2 count at 1.1905 MHz?',13,10
        db '   Timed against ONE BIOS tick, which is 54.925 ms. No assumption',13,10
        db '   about the CPU is involved.',13,10,'$'
msg_t2  db 13,10,'2  The calibration loop, timed exactly as the BIOS times it',13,10
        db '   4096 iterations of a two-byte LOOP.',13,10,'$'

msg_start db '     channel 2 at start : $'
msg_end   db 13,10,'     channel 2 at end   : $'
msg_delta db 13,10,'     counted           : $'
msg_exp1  db '   (expect about 65388)',13,10,'$'

msg_v_ok   db '     -> plausible: channel 2 counts at about the right rate,',13,10
           db '        so the fault is in the loop timing, not the reference.',13,10,'$'
msg_v_slow db '     -> TOO FEW. Channel 2 is counting far slower than 1.1905 MHz,',13,10
           db '        or the latch-and-read is returning something else. Every',13,10
           db '        figure built on this reference is meaningless.',13,10,'$'
msg_v_dead db '     -> essentially ZERO. Channel 2 is not counting at all: check',13,10
           db '        the gate at port 0x61 bit 0, and whether timer8253',13,10
           db '        implements mode 0 for counter 2.',13,10,'$'
msg_v_odd  db '     -> impossible for one tick; the counter wrapped.',13,10,'$'

msg_sum db 13,10,'What that implies',13,10,'$'
msg_us  db '     loop took, microseconds : $'
msg_cpi db '     clocks per iteration at an assumed 5 MHz : $'
msg_cpi2 db 13,10,'$'
msg_tail db 13,10
        db 'A two-byte LOOP costs somewhere near 20 clocks on this machine',13,10
        db '(WAITSTAT measured a comparable loop at about 25). A figure far',13,10
        db 'from that is the size of the error, and test 1 says which half',13,10
        db 'of the measurement is lying.',13,10,'$'
msg_crlf db 13,10,'$'
