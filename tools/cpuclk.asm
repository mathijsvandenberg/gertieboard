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
;  TEST 1 times channel 2 against the BIOS tick. Both come from the same 8253,
;  so it needs no assumption about the CPU at all -- but it needs one about the
;  8253, and the obvious version of this test is WORTHLESS:
;
;      The BIOS programs counter 0 with divisor 0, meaning 65536. Counter 2
;      armed with 0xFFFF also wraps every 65536 counts. So one tick is EXACTLY
;      one full wrap of channel 2, the two readings are the same number, and
;      the delta is zero -- which is also what a dead counter returns.
;
;  This file shipped with that version. It expected "about 65388" and would have
;  reported a perfectly good PIT as "essentially ZERO, not counting at all".
;  The aliasing is total: no threshold could have rescued it.
;
;  So counter 0 is reprogrammed to 16384 for the duration, which is not a whole
;  wrap of channel 2, and the tick that results is 72.6 Hz instead of 18.2:
;
;      expected delta = 16384 counts, exactly
;
;  Counter 0 is put back to divisor 0 afterwards. DOS's time of day will be a
;  fraction of a second out; nothing else notices.
;
;  What this proves is that channel 2 counts at the SAME rate counter 0 does.
;  It cannot prove the absolute 1.1905 MHz, and neither can anything else on
;  this machine -- both counters come from c2, and there is no second clock to
;  check it against. That is a real limit of the test, not a gap in it.
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

        ; Counter 0 to 16384 so one tick is NOT a whole wrap of counter 2.
        ; Mode 3, lo/hi, binary -- the same mode the BIOS uses, only shorter.
        mov  al, 0x36
        out  0x43, al
        mov  al, 0x00
        out  0x40, al
        mov  al, 0x40
        out  0x40, al

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

        ; put the BIOS tick back before printing anything
        mov  al, 0x36
        out  0x43, al
        xor  al, al
        out  0x40, al
        out  0x40, al

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
        ; factor", not for a percent. 16384 expected; a few counts of latch
        ; overhead either way is normal.
        mov  ax, [d1]
        mov  dx, msg_v_dead
        cmp  ax, 1000
        jb   .v1
        mov  dx, msg_v_slow
        cmp  ax, 14000
        jb   .v1
        mov  dx, msg_v_ok
        cmp  ax, 19000
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

msg_t1  db 13,10,'1  Does PIT channel 2 count at the rate counter 0 does?',13,10
        db '   Counter 0 is set to 16384 for this test, because the BIOS value',13,10
        db '   of 65536 is exactly one wrap of counter 2 and the delta would be',13,10
        db '   zero however well the PIT worked. No assumption about the CPU is',13,10
        db '   involved. Counter 0 is restored afterwards.',13,10,'$'
msg_t2  db 13,10,'2  The calibration loop, timed exactly as the BIOS times it',13,10
        db '   4096 iterations of a two-byte LOOP.',13,10,'$'

msg_start db '     channel 2 at start : $'
msg_end   db 13,10,'     channel 2 at end   : $'
msg_delta db 13,10,'     counted           : $'
msg_exp1  db '   (expect 16384)',13,10,'$'

msg_v_ok   db '     -> plausible: channel 2 counts at about the right rate,',13,10
           db '        so the fault is in the loop timing, not the reference.',13,10,'$'
msg_v_slow db '     -> TOO FEW. Channel 2 is counting far slower than counter 0,',13,10
           db '        or the latch-and-read is returning something else. Every',13,10
           db '        figure built on this reference is meaningless.',13,10,'$'
msg_v_dead db '     -> essentially ZERO. Channel 2 is not counting at all: check',13,10
           db '        the gate at port 0x61 bit 0, and whether timer8253',13,10
           db '        implements mode 0 for counter 2.',13,10,'$'
msg_v_odd  db '     -> TOO MANY for one tick of 16384.',13,10,'$'

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
