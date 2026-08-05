; ============================================================================
;  sdramtst.asm  --  prove the 32 MB SDRAM before the EGA planes move into it
;
;  The DE0-Nano has always had this chip and this board has never used it. It
;  is being brought up so mode 0Dh can have a second display page -- King's
;  Quest keeps the area under its text windows at offset 0x2000, and Keen 4
;  wants a 640-pixel logical line; both need 16 KB per plane against the 8 KB
;  that fits in M9K.
;
;  A memory fault in there would show up as a corrupt picture, which is
;  indistinguishable from a bug in the addressing, the scanline buffer, the
;  arbitration or the write path. Every one of those was wrong at least once
;  while EGA was being built on M9K. So the memory gets tested BY ITSELF, and
;  says which bit disagreed.
;
;  FOUR TESTS, each finding a different fault:
;
;    1 DATA LINES -- walking ones and zeros at one address.
;      Finds a data line stuck high or low, or two shorted together. Reports
;      the bits that disagreed, so a stuck line names itself.
;
;    2 ADDRESS LINES -- a unique value at each power-of-two word address.
;      Finds an address line stuck or swapped, which is the fault that makes a
;      memory look like it works until something large is stored in it: writes
;      land on top of each other and only the last one survives.
;
;    3 A WIDE PSEUDORANDOM PASS -- fill, then verify.
;      Catches anything the first two miss, across a span far larger than the
;      64 KB the planes will use.
;
;    4 THE DWELL -- write, wait ten seconds, read back.
;      This is the one that matters. A controller that never refreshes, or
;      that lets a busy master crowd refresh out, passes every test above:
;      the data is still in the sense amplifiers. It fails minutes later, in
;      a pattern that reads as anything but a memory fault. Ten seconds is
;      more than a thousand times the 64 ms retention the part promises
;      without refresh, so anything that survives it is genuinely being
;      refreshed.
;
;  Build:  nasm -f bin sdramtst.asm -o sdramtst.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

; 0x300 is the prototype-card range. These were at 0xE8 first, which is the USB
; host controller's register block -- both modules drove the same port and the
; read came back as 00, which is indistinguishable from a dead controller.
P_AL    equ 0x300               ; address 7:0    (WORD address)
P_AM    equ 0x301               ; address 15:8
P_AH    equ 0x302               ; address 23:16
P_DL    equ 0x303               ; data 7:0
P_DH    equ 0x304               ; data 15:8
P_CMD   equ 0x305               ; W: 1 = read, 2 = write
                                ; R: b0 busy, b1 init, b2 always 1, b3 reset

NPASS   equ 4096                ; words in the wide pass

start:
        mov  dx, msg_hdr
        call puts

        ; ---- is the controller even alive? ----------------------------
        mov  dx, P_CMD
        in   al, dx
        mov  bl, al
        ; Bit 2 is hardwired high, so this separates "the controller says
        ; something" from "nothing answered and the bus floated".
        test al, 0x04
        jnz  .alive
        mov  dx, msg_dead
        call puts
        mov  al, bl
        call puthex8
        mov  dx, msg_crlf
        call puts
        jmp  fail_exit
.alive:
        test al, 0x02
        jnz  .up
        mov  dx, msg_noinit
        call puts
        mov  al, bl             ; the whole status byte: bits 7:4 name the
        call puthex8            ; state the controller is sitting in
        mov  dx, msg_state
        call puts
        jmp  fail_exit
.up:
        mov  dx, msg_init
        call puts

; ---------------------------------------------------------------------------
;  1  Data lines
; ---------------------------------------------------------------------------
        mov  dx, msg_t1
        call puts
        mov  cx, 16
        mov  bx, 1              ; the walking bit
.d1:
        push cx
        push bx
        ; a one walking through zeros
        xor  ax, ax
        call setaddr
        mov  ax, bx
        call wr16
        xor  ax, ax
        call setaddr
        call rd16
        pop  bx
        push bx
        cmp  ax, bx
        jne  .d1bad
        ; and a zero walking through ones, so a line stuck HIGH is caught too
        pop  bx
        push bx
        xor  ax, ax
        call setaddr
        mov  ax, bx
        not  ax
        mov  [wexp], ax
        call wr16
        xor  ax, ax
        call setaddr
        call rd16
        mov  bx, [wexp]
        cmp  ax, bx
        jne  .d1bad
        pop  bx
        pop  cx
        shl  bx, 1
        loop .d1
        mov  dx, msg_ok
        call puts
        jmp  test2
.d1bad:
        pop  bx
        call report_bad
        jmp  fail_exit

; ---------------------------------------------------------------------------
;  2  Address lines -- a distinct value at every power-of-two word address
;
;  16 bits is 65536 words = 128 KB, which is twice what four 16 KB planes need.
;  The VALUE stored is the address itself, so a swapped pair of address lines
;  reports the address it actually reached.
; ---------------------------------------------------------------------------
test2:
        mov  dx, msg_t2
        call puts
        xor  ax, ax
        call setaddr
        mov  ax, 0xA55A         ; address 0 is not a power of two, so it needs
        call wr16               ; its own marker
        mov  cx, 16
        mov  bx, 1
.a1:    push cx
        push bx
        mov  ax, bx
        call setaddr
        mov  ax, bx
        call wr16
        pop  bx
        pop  cx
        shl  bx, 1
        loop .a1

        xor  ax, ax
        call setaddr
        call rd16
        mov  bx, 0xA55A
        cmp  ax, bx
        jne  .a1bad
        mov  cx, 16
        mov  bx, 1
.a2:    push cx
        push bx
        mov  ax, bx
        call setaddr
        call rd16
        pop  bx
        push bx
        cmp  ax, bx
        jne  .a1bad2
        pop  bx
        pop  cx
        shl  bx, 1
        loop .a2
        mov  dx, msg_ok
        call puts
        jmp  test3
.a1bad2:
        pop  bx
.a1bad:
        call report_bad
        jmp  fail_exit

; ---------------------------------------------------------------------------
;  3  A wide pseudorandom pass
; ---------------------------------------------------------------------------
test3:
        mov  dx, msg_t3
        call puts
        mov  word [seed], 0xACE1
        xor  si, si             ; word address
        mov  cx, NPASS
.f1:    push cx
        mov  ax, si
        call setaddr
        call lfsr
        call wr16
        pop  cx
        inc  si
        loop .f1

        mov  word [seed], 0xACE1
        xor  si, si
        mov  cx, NPASS
.v1:    push cx
        mov  ax, si
        call setaddr
        call rd16
        mov  bx, ax
        call lfsr
        cmp  ax, bx
        jne  .v1bad
        pop  cx
        inc  si
        loop .v1
        mov  dx, msg_ok
        call puts
        jmp  test4
.v1bad:
        pop  cx
        xchg ax, bx             ; AX = what was read, BX = what was expected
        call report_bad
        jmp  fail_exit

; ---------------------------------------------------------------------------
;  4  The dwell -- the test that actually proves refresh
; ---------------------------------------------------------------------------
test4:
        mov  dx, msg_t4
        call puts
        mov  word [seed], 0x1234
        xor  si, si
        mov  cx, 256
.w4:    push cx
        mov  ax, si
        call setaddr
        call lfsr
        call wr16
        pop  cx
        inc  si
        loop .w4

        ; ten seconds on the BIOS tick, which comes from the PIT and not from
        ; anything this test can influence
        mov  ax, 0x40
        mov  es, ax
        mov  bx, [es:0x6C]      ; start
.dw:    mov  ax, [es:0x6C]
        sub  ax, bx             ; elapsed, and correct across a wrap because
        cmp  ax, 182            ; unsigned subtraction wraps the same way
        jb   .dw

        mov  word [seed], 0x1234
        xor  si, si
        mov  cx, 256
.r4:    push cx
        mov  ax, si
        call setaddr
        call rd16
        mov  bx, ax
        call lfsr
        cmp  ax, bx
        jne  .r4bad
        pop  cx
        inc  si
        loop .r4
        mov  dx, msg_ok
        call puts
        mov  dx, msg_pass
        call puts
        mov  ax, 0x4C00
        int  0x21
.r4bad:
        pop  cx
        xchg ax, bx
        call report_bad
        mov  dx, msg_refresh
        call puts
fail_exit:
        mov  dx, msg_fail
        call puts
        mov  ax, 0x4C01
        int  0x21

; ---------------------------------------------------------------------------
; setaddr   -- AX = word address 15:0, high byte zero
; setaddr32 -- AX = word address 15:0, DX = 23:16
setaddr:
        xor  dx, dx
setaddr32:
        push ax
        push dx
        mov  dx, P_AL
        out  dx, al
        pop  dx
        push dx
        mov  al, ah
        mov  dx, P_AM
        out  dx, al
        pop  dx
        mov  al, dl
        mov  dx, P_AH
        out  dx, al
        pop  ax
        ret

; wr16 -- write AX at the current address
wr16:
        push ax
        push dx
        mov  dx, P_DL
        out  dx, al
        mov  al, ah
        mov  dx, P_DH
        out  dx, al
        mov  al, 2
        mov  dx, P_CMD
        out  dx, al
        call waitdone
        pop  dx
        pop  ax
        ret

; rd16 -- AX = the word at the current address
rd16:
        push dx
        mov  al, 1
        mov  dx, P_CMD
        out  dx, al
        call waitdone
        mov  dx, P_DL
        in   al, dx
        mov  bl, al
        mov  dx, P_DH
        in   al, dx
        mov  ah, al
        mov  al, bl
        pop  dx
        ret

; waitdone -- spin until the controller drops busy. Bounded, so a controller
; that never answers reports instead of hanging the machine.
waitdone:
        push ax
        push cx
        push dx
        mov  cx, 0
        mov  dx, P_CMD
.w:     in   al, dx
        test al, 0x01
        jz   .d
        loop .w
.d:     pop  dx
        pop  cx
        pop  ax
        ret

; lfsr -- next pseudorandom word in AX. A 16-bit Galois LFSR: cheap, and it
; visits every value but zero, so a stuck address shows as a mismatch rather
; than as a coincidence.
lfsr:
        push bx
        mov  ax, [seed]
        shr  ax, 1
        jnc  .n
        xor  ax, 0xB400
.n:     mov  [seed], ax
        pop  bx
        ret

; report_bad -- AX = read, BX = expected. Through memory rather than the stack:
; a mis-ordered push in the routine that reports failures is a special kind of
; unhelpful.
report_bad:
        mov  [r_got], ax
        mov  [r_exp], bx
        mov  dx, msg_bad
        call puts
        mov  ax, [r_exp]
        call puthex16
        mov  dx, msg_got
        call puts
        mov  ax, [r_got]
        call puthex16
        mov  dx, msg_diff
        call puts
        mov  ax, [r_got]
        xor  ax, [r_exp]
        call puthex16
        mov  dx, msg_crlf
        call puts
        ret

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthex16:
        push ax
        mov  al, ah
        call puthex8
        pop  ax
        call puthex8
        ret

puthex8:
        push ax
        push cx
        mov  cl, al
        shr  al, 1
        shr  al, 1
        shr  al, 1
        shr  al, 1
        call .nib
        mov  al, cl
        and  al, 0x0F
        call .nib
        pop  cx
        pop  ax
        ret
.nib:   and  al, 0x0F
        add  al, '0'
        cmp  al, '9'
        jbe  .p
        add  al, 7
.p:     push ax
        push dx
        mov  dl, al
        mov  ah, 2
        int  0x21
        pop  dx
        pop  ax
        ret

; ---------------------------------------------------------------------------
seed    dw 0xACE1
wexp    dw 0
r_got   dw 0
r_exp   dw 0

msg_hdr db 'SDRAMTST - the DE0-Nano 32 MB SDRAM',13,10
        db '-----------------------------------',13,10
        db 'This chip has been on the board since the beginning and has',13,10
        db 'never been used. It is being brought up to hold the EGA planes,',13,10
        db 'which do not fit in M9K: mode 0Dh needs a second display page.',13,10,13,10
        db 'A fault here would look like a corrupt picture, which is exactly',13,10
        db 'what a bug in the addressing or the scanline buffer looks like.',13,10
        db 'So the memory is tested on its own first.',13,10,13,10,'$'
msg_noinit db 'The controller never finished its init sequence (0xED bit 1',13,10
        db 'never came up). Nothing below would mean anything.',13,10,'$'
msg_init db 'controller reports init done',13,10,13,10,'$'
msg_dead db 'Nothing answered port 0x305 -- bit 2 is hardwired high and did',13,10
        db 'not come back. Either the bitstream is not the one with the SDRAM',13,10
        db 'in it, or something else is driving that port. Status byte: $'
msg_state db '  <- status byte. High nibble is the state:',13,10
        db '     0 reset  1 init-wait  2 precharge  3 refresh  4 mode-reg',13,10
        db '     5 idle   6 activate   7 rd/wr      8 cas-wait 9 done',13,10
        db '     A auto-refresh',13,10
        db '  Bit 3 set means RESET is being held asserted.',13,10
        db '  Stuck at 0 means RESET is being held. Stuck at 1 means the',13,10
        db '  100 us timer is not counting. 5 would mean init DID finish and',13,10
        db '  the status bit is the thing that is wrong.',13,10,'$'
msg_t1  db '1  data lines, walking ones and zeros ... $'
msg_t2  db '2  address lines, unique value per power of two ... $'
msg_t3  db '3  4096 pseudorandom words, fill then verify ... $'
msg_t4  db '4  dwell: write, wait ten seconds, read back ... $'
msg_ok  db 'ok',13,10,'$'
msg_bad db 13,10,'   MISMATCH  expected $'
msg_got db '  read $'
msg_diff db '  differing bits $'
msg_crlf db 13,10,'$'
msg_refresh:
        db 13,10,'The first three tests passed and this one did not, which is',13,10
        db 'the signature of refresh: the data was there while it was fresh',13,10
        db 'in the sense amplifiers and decayed while nothing rewrote it.',13,10
        db 'Look at the refresh counter and at whether the idle state serves',13,10
        db 'refresh BEFORE it serves a client request.',13,10,'$'
msg_pass:
        db 13,10,'ALL FOUR PASSED. The SDRAM is sound, including refresh over',13,10
        db 'ten seconds. The EGA planes can move into it.',13,10,'$'
msg_fail db 13,10,'STOPPED. Do not move anything into this memory yet.',13,10,'$'
