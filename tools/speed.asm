; ============================================================================
;  speed.asm  --  read and set the machine's clock, and prove it changed
;
;  The bus clock is a register now (cpuclk.vhd, I/O 0xE5) rather than a line in
;  pll.vhd, so walking the ladder no longer costs a Quartus build per step.
;
;      SPEED          show the ladder and where the machine is on it
;      SPEED n        move to step n (0..7), then measure
;
;  MEASURING IT IS THE POINT. Setting a register proves nothing -- an hour was
;  once spent testing 8.333 MHz in the belief it was 6.25, from a .sof that was
;  two clock rates out of date. So this times a fixed loop at step 0 and again
;  at the step you asked for, and prints the RATIO of the two.
;
;  The ratio is what makes the test honest. Absolute figures need a clocks-per-
;  iteration constant that nobody here knows -- the loop is fetched from PSRAM
;  through a cache, so it is not the number in any 8088 table, and assuming one
;  is exactly how POST came to report 1.54 MHz and 94.82 MHz from the same code
;  (see cpuclk.asm). A ratio cancels it: whatever the loop costs, it costs the
;  same at both steps, so t(0)/t(n) is the speed change and nothing else. It is
;  measured against PIT channel 2, which runs from c2 and does NOT follow the
;  CPU clock -- that independence is the whole reason the measurement works.
;
;  If the measured ratio does not match the nominal one, believe the ratio: it
;  is the only thing here that touched the hardware.
;
;  Change step with the FLOPPY IDLE. The host serial link is re-timed by the
;  same register, so a step taken mid-byte re-times the bit in flight.
;
;  If the step you ask for is past what the bitstream was built and timed for,
;  the hardware clamps it and the read-back tells you so. If the machine wedges
;  at a step it cannot run, the reset button and Ctrl+Alt+Del both put it back
;  to the default -- reset restores it in hardware, which is the only place it
;  could be restored from, since a wedged CPU cannot write the register.
;
;  Build:  nasm -f bin speed.asm -o speed.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

PORT_SPEED equ 0xE5
POST       equ 0x80             ; the 7-seg, same ladder idea as bootldr_64k
ITER       equ 4096             ; ~20 ms at 5 MHz, ~6 ms at 16.667 -- both well
                                ; inside one 55 ms wrap of channel 2

; A step that cannot run DOS takes the numbers down with it, so the phases are
; marked on the 7-seg and the RESULTS ARE PRINTED FROM 5 MHz, not from the step
; under test. Everything that has to work for the measurement is done first,
; the machine is dropped back to a step known to work, and only then does any
; DOS output happen. A crash therefore costs you the machine but not the data.
;
;   C0 about to time the reference   C3 target step timed
;   C1 reference timed               C4 back at 5 MHz, printing
;   C2 target step applied           C5 printed; re-applying the target
;
; C2 showing means the step was accepted and the CPU died running it. C1 means
; it died the moment the step was applied. C5 means everything worked and only
; the final re-apply is left.
%macro MARK 1
        push    ax
        mov     al, %1
        out     POST, al
        pop     ax
%endmacro

start:
        mov  dx, msg_hdr
        call puts

; ---------------------------------------------------------------------------
;  Is there a speed control in this bitstream at all?
;  Bit 7 reads 0 when cpuclk answers. An older bitstream leaves 0xE5 on the
;  open bus, which reads 0xFF -- bit 7 set, and every other field nonsense.
; ---------------------------------------------------------------------------
        in   al, PORT_SPEED
        mov  [cur], al
        test al, 0x80
        jz   .have
        mov  dx, msg_absent
        call puts
        jmp  done
.have:
        and  al, 0x07
        mov  [idx0], al
        mov  al, [cur]
        mov  cl, 4
        shr  al, cl
        and  al, 0x07
        mov  [maxidx], al

; ---------------------------------------------------------------------------
;  The ladder, with a marker on the step in force
; ---------------------------------------------------------------------------
        mov  dx, msg_tab
        call puts
        xor  bx, bx                     ; bx = step being listed
.row:
        mov  dx, msg_ind_no
        cmp  bl, [idx0]
        jne  .r1
        mov  dx, msg_ind_yes
.r1:    call puts
        mov  ax, bx
        call putdec
        mov  dx, msg_sp
        call puts
        ; name table: 8 entries, 8 bytes each, '$'-terminated inside
        mov  ax, 8
        mul  bx
        add  ax, names
        mov  dx, ax
        call puts
        mov  dx, msg_over
        cmp  bl, [maxidx]
        ja   .r2
        mov  dx, msg_crlf
.r2:    call puts
        inc  bx
        cmp  bx, 8
        jb   .row

        mov  dx, msg_max
        call puts
        mov  al, [maxidx]
        xor  ah, ah
        call putdec
        mov  dx, msg_crlf
        call puts

; ---------------------------------------------------------------------------
;  A step on the command line?  Anything else is a report-only run.
; ---------------------------------------------------------------------------
        call getarg
        jc   done                       ; nothing asked for: the table was it

        mov  [want], al

        ; Say what is about to be tried WHILE STILL AT A STEP THAT WORKS. If the
        ; machine does not come back, the screen already names the step that
        ; killed it.
        mov  dx, msg_try
        call puts
        mov  al, [want]
        xor  ah, ah
        call putdec
        mov  dx, msg_sp
        call puts
        mov  al, [want]
        xor  ah, ah
        mov  bx, 8
        mul  bx
        add  ax, names
        mov  dx, ax
        call puts
        mov  dx, msg_crlf
        call puts

; ---------------------------------------------------------------------------
;  Time the loop at step 0, then at the requested step, then GO BACK to step 0
;  before printing anything. Interrupts off across each measurement: the 18.2 Hz
;  tick would otherwise be counted as part of the loop, and it is not the same
;  cost at both steps.
; ---------------------------------------------------------------------------
        MARK 0xC0
        xor  al, al
        call setspeed
        call measure
        mov  [t_ref], ax
        MARK 0xC1

        mov  al, [want]
        call setspeed
        MARK 0xC2
        call measure
        mov  [t_new], ax
        MARK 0xC3

        ; What the hardware settled on, which is not always what was asked for --
        ; the clamp is silent by design, the read-back is not. Read it BEFORE
        ; dropping back, or the answer is 0.
        in   al, PORT_SPEED
        and  al, 0x07
        mov  [got], al

        ; Back to a step known to work. Everything below here is DOS output, and
        ; that is the part a marginal step cannot survive -- so it happens at
        ; 5 MHz and the numbers reach the screen either way.
        xor  al, al
        call setspeed
        MARK 0xC4

        mov  dx, msg_now
        call puts
        mov  al, [got]
        xor  ah, ah
        call putdec
        mov  dx, msg_sp
        call puts
        mov  al, [got]
        xor  ah, ah
        mov  bx, 8
        mul  bx
        add  ax, names
        mov  dx, ax
        call puts
        mov  dx, msg_crlf
        call puts

        mov  al, [want]
        cmp  al, [got]
        je   .nocl
        mov  dx, msg_clamped
        call puts
.nocl:

; ---------------------------------------------------------------------------
;  The two timings and what they imply
; ---------------------------------------------------------------------------
        mov  dx, msg_ref
        call puts
        mov  ax, [t_ref]
        call putdec
        mov  dx, msg_counts
        call puts

        mov  dx, msg_at
        call puts
        mov  ax, [t_new]
        call putdec
        mov  dx, msg_counts
        call puts

        ; measured = t_ref * 100 / t_new, i.e. hundredths of "5 MHz's speed"
        mov  ax, [t_new]
        test ax, ax
        jz   .nodiv
        mov  ax, [t_ref]
        mov  bx, 100
        mul  bx                         ; dx:ax
        mov  bx, [t_new]
        div  bx
        mov  [ratio], ax

        mov  dx, msg_meas
        call puts
        mov  ax, [ratio]
        call puthund
        mov  dx, msg_vs
        call puts
        ; nominal = 1000 / half, since f = 50/half MHz and the reference is 5
        mov  al, [got]
        xor  ah, ah
        mov  bx, ax
        mov  al, [halves + bx]
        xor  ah, ah
        mov  bx, ax
        mov  ax, 1000
        xor  dx, dx
        div  bx
        call puthund
        mov  dx, msg_xtail
        call puts
        jmp  restore
.nodiv:
        mov  dx, msg_nodiv
        call puts

; ---------------------------------------------------------------------------
;  Everything is printed. The LAST thing done is to re-apply the step that was
;  asked for, so the machine is left where you wanted it -- and if that is a
;  step it cannot live at, it dies having already told you everything.
; ---------------------------------------------------------------------------
restore:
        MARK 0xC5
        mov  dx, msg_left
        call puts
        mov  al, [got]
        xor  ah, ah
        call putdec
        mov  dx, msg_crlf
        call puts
        mov  al, [got]
        call setspeed

done:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; setspeed -- AL = step. Written twice is harmless; the register is a latch.
setspeed:
        out  PORT_SPEED, al
        ; Let the divider adopt it before timing anything. The step is taken on
        ; a period boundary and crosses a three-stage synchroniser to get there,
        ; so it is a handful of clocks away, not instant.
        mov  cx, 200
.w:     loop .w
        ret

; ---------------------------------------------------------------------------
; measure -- AX = PIT channel 2 counts consumed by ITER iterations of LOOP.
; Channel 2 counts DOWN from 0xFFFF at 1.1905 MHz and is not derived from the
; CPU clock, so it is a real time base at every step.
measure:
        push bx
        push cx
        push si
        push di
        cli
        in   al, 0x61
        and  al, 0xFD                   ; speaker data off -- silent
        or   al, 0x01                   ; gate 2 on
        out  0x61, al
        mov  al, 0xB0                   ; ch2, lo/hi, mode 0, binary
        out  0x43, al
        mov  al, 0xFF
        out  0x42, al
        out  0x42, al

        call pit2
        mov  si, ax
        mov  cx, ITER
        call theloop
        call pit2
        mov  di, ax
        sti

        mov  ax, si
        sub  ax, di                     ; counts down, so start - end
        pop  di
        pop  si
        pop  cx
        pop  bx
        ret

theloop:
        db   0xE2, 0xFE                 ; loop $
        ret

pit2:   push bx
        mov  al, 0x80                   ; latch counter 2
        out  0x43, al
        in   al, 0x42
        mov  bl, al
        in   al, 0x42
        mov  bh, al
        mov  ax, bx
        pop  bx
        ret

; ---------------------------------------------------------------------------
; getarg -- first digit on the command tail -> AL, CF set if there is none
getarg:
        mov  si, 0x81
        mov  cl, [0x80]
        xor  ch, ch
        jcxz .none
.scan:  lodsb
        cmp  al, '0'
        jb   .next
        cmp  al, '7'
        ja   .next
        sub  al, '0'
        clc
        ret
.next:  loop .scan
.none:  stc
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

; puthund -- AX in hundredths, printed as n.nn
puthund:
        push ax
        push bx
        push dx
        xor  dx, dx
        mov  bx, 100
        div  bx                         ; ax = whole, dx = remainder
        push dx
        call putdec
        mov  dl, '.'
        mov  ah, 2
        int  0x21
        pop  ax
        ; two digits, leading zero kept
        xor  dx, dx
        mov  bx, 10
        div  bx
        push dx
        add  al, '0'
        mov  dl, al
        mov  ah, 2
        int  0x21
        pop  ax
        add  al, '0'
        mov  dl, al
        mov  ah, 2
        int  0x21
        pop  dx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
cur     db 0
idx0    db 0
maxidx  db 0
want    db 0
got     db 0
t_ref   dw 0
t_new   dw 0
ratio   dw 0

; 100 MHz cycles per half period, per step -- the same table cpuclk.vhd holds.
halves  db 10, 8, 7, 6, 5, 4, 3, 2

; eight bytes each, '$' inside, so the index is a shift and an add
names   db ' 5.000$ '
        db ' 6.250$ '
        db ' 7.143$ '
        db ' 8.333$ '
        db '10.000$ '
        db '12.500$ '
        db '16.667$ '
        db '25.000$ '

msg_hdr db 'SPEED - the bus clock, at I/O 0xE5',13,10
        db '----------------------------------',13,10,'$'

msg_absent db 'This bitstream has no speed control: port 0xE5 reads open bus.',13,10
           db 'Rebuild with cpuclk.vhd in the design.',13,10,'$'

msg_tab db 13,10,'   step   MHz',13,10,'$'
msg_ind_no  db '     $'
msg_ind_yes db '  -> $'
msg_sp  db '   $'
msg_over db "   (past this bitstream's limit)",13,10,'$'
msg_max db 13,10,'Fastest step this bitstream was built and timed for: $'

msg_try db 13,10,'Trying step $'
msg_left db 13,10,'Leaving the machine at step $'
msg_now db 13,10,'Now at step $'
msg_clamped db 'That step is past what this bitstream allows, so the hardware',13,10
            db 'clamped it. Raise MAX_IDX in gertieboard.vhdl AND the divide in',13,10
            db 'gertieboard.sdc together, then rebuild.',13,10,'$'

msg_ref db 13,10,'   loop at step 0 (5 MHz) : $'
msg_at  db '   loop at this step      : $'
msg_counts db ' PIT counts',13,10,'$'
msg_meas db 13,10,'   measured $'
msg_vs   db 'x the 5 MHz speed, nominal $'
msg_xtail db 'x',13,10
        db 13,10,'A measured figure well off the nominal one means the clock did not',13,10
        db 'do what the register says. Believe the measurement.',13,10,'$'
msg_nodiv db 13,10,'The loop consumed no PIT counts at all -- channel 2 is not counting.',13,10
          db 'Run CPUCLK.COM: nothing here can be trusted until that is fixed.',13,10,'$'

msg_crlf db 13,10,'$'
