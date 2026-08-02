; ============================================================================
;  adlibchk.asm  --  bench test for the AdLib front end at 0x388/0x389
;
;  A game is a bad first test of new hardware. If Keen stays silent you cannot
;  tell whether the card was not detected, was detected but got no notes, or
;  got notes that came out inaudible -- and Keen has its own reasons to fail
;  that have nothing to do with sound. This asks one question at a time.
;
;      1  detection    runs the exact handshake every AdLib program uses and
;                      prints both status bytes, so a failure says WHERE
;      2  scale        two chromatic octaves on channel 0 -- pitch and the
;                      block/F-number split
;      3  chord        four channels at once -- the PWM mixer, which is the
;                      part that cannot be tested one note at a time
;      4  sweep        each of the nine channels alone, in turn, so a channel
;                      that is dead is heard rather than inferred
;
;  The channels are given a real OPL2 patch (registers 0x20-0xE0) even though
;  opl2_lite ignores every one of them. That is deliberate: it makes this a
;  valid tool on a real AdLib card too, so the same binary can be used to
;  compare this board against genuine hardware. Nothing here assumes the
;  square-wave shortcut.
;
;  Scales and arpeggios only -- deliberately. Test material should be something
;  you can judge pitch and timing against, not something you recognise.
;
;  Build:  nasm -f bin adlibchk.asm -o adlibchk.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

ADLIB   equ 0x388

start:
        mov  dx, msg_hdr
        call puts

; ---------------------------------------------------------------------------
;  1  detection
; ---------------------------------------------------------------------------
        mov  dx, msg_t1
        call puts

        mov  al, 4
        mov  ah, 0x60           ; stop and mask both timers
        call alout
        mov  al, 4
        mov  ah, 0x80           ; reset the status flags
        call alout
        mov  dx, ADLIB
        in   al, dx
        mov  [sreg1], al

        mov  al, 2
        mov  ah, 0xFF           ; timer 1 preset: one tick from overflow
        call alout
        mov  al, 4
        mov  ah, 0x21           ; start timer 1, mask timer 2
        call alout

        mov  cx, 0              ; 65536 iterations, comfortably over 80 us
.dly:   loop .dly

        mov  dx, ADLIB
        in   al, dx
        mov  [sreg2], al

        mov  al, 4              ; leave the timers as we found them
        mov  ah, 0x60
        call alout
        mov  al, 4
        mov  ah, 0x80
        call alout

        mov  dx, msg_s1
        call puts
        mov  al, [sreg1]
        call puthexb
        mov  dx, msg_want1
        call puts
        mov  al, [sreg1]
        and  al, 0xE0
        call verdict

        mov  dx, msg_s2
        call puts
        mov  al, [sreg2]
        call puthexb
        mov  dx, msg_want2
        call puts
        mov  al, [sreg2]
        and  al, 0xE0
        sub  al, 0xC0           ; zero means it matched
        call verdict

        ; both must be right, or there is no point making a noise
        mov  al, [sreg1]
        and  al, 0xE0
        jnz  .nocard
        mov  al, [sreg2]
        and  al, 0xE0
        cmp  al, 0xC0
        jne  .nocard
        mov  dx, msg_found
        call puts
        jmp  short .sound
.nocard:
        mov  dx, msg_notfound
        call puts
        jmp  bye

; ---------------------------------------------------------------------------
.sound:
        call init_chans

; ---------------------------------------------------------------------------
;  2  scale -- two octaves, one channel
; ---------------------------------------------------------------------------
        mov  dx, msg_t2
        call puts
        mov  byte [blk], 4
        call one_octave
        mov  byte [blk], 5
        call one_octave

; ---------------------------------------------------------------------------
;  3  chord -- four channels together
;
;  Four notes at four DIFFERENT pitches. Four of the same note would stay
;  phase-locked and stack into one loud square wave, which proves nothing about
;  mixing; detuned voices drift in and out and exercise the whole 0..9 range.
; ---------------------------------------------------------------------------
        mov  dx, msg_t3
        call puts
        mov  si, chord
        xor  bl, bl             ; channel 0 upward
.ch1:   mov  cl, [si]
        cmp  cl, 0xFF
        je   .ch2
        push si
        mov  bh, 5
        xor  ch, ch
        mov  si, notes
        shl  cl, 1
        add  si, cx
        mov  cx, [si]
        call note_on
        pop  si
        inc  si
        inc  bl
        jmp  short .ch1
.ch2:
        mov  cx, 18             ; about a second
        call wait_ticks
        call silence

; ---------------------------------------------------------------------------
;  4  sweep -- every channel alone
; ---------------------------------------------------------------------------
        mov  dx, msg_t4
        call puts
        xor  bl, bl
.sw1:   cmp  bl, 9
        jae  .sw2
        push bx
        mov  dx, msg_chan
        call puts
        mov  al, bl
        add  al, '0'
        call putal
        mov  bh, 5
        mov  cx, [notes + 9*2]  ; A
        call note_on
        mov  cx, 5
        call wait_ticks
        call note_off
        pop  bx
        inc  bl
        jmp  short .sw1
.sw2:
        call silence
        mov  dx, msg_done
        call puts
bye:
        call silence
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; one_octave -- twelve semitones on channel 0 at block [blk]
one_octave:
        push ax
        push bx
        push cx
        push si
        push di
        mov  si, notes
        mov  di, 12
        xor  bl, bl             ; channel 0
.o1:    mov  bh, [blk]
        mov  cx, [si]
        call note_on
        mov  cx, 2              ; ~110 ms per note
        call wait_ticks
        call note_off
        add  si, 2
        dec  di
        jnz  .o1
        pop  di
        pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
; init_chans -- give all nine channels a plain sustained tone.
;
; opl2_lite ignores all of this, but a real OPL2 is silent without it, and a
; tool that only works on the thing it is testing is not a test.
init_chans:
        push ax
        push bx
        push cx
        push si
        xor  bl, bl
.ic1:   cmp  bl, 9
        jae  .ic2
        mov  si, opofs
        mov  bh, bl
        mov  al, bl
        xor  ah, ah
        add  si, ax
        mov  cl, [si]           ; operator 1 offset; operator 2 is +3

        mov  al, 0x20
        add  al, cl
        mov  ah, 0x01           ; multiplier 1, no tremolo/vibrato
        call alout
        mov  al, 0x23
        add  al, cl
        mov  ah, 0x01
        call alout

        mov  al, 0x40
        add  al, cl
        mov  ah, 0x10           ; modulator attenuated a little
        call alout
        mov  al, 0x43
        add  al, cl
        mov  ah, 0x00           ; carrier at full volume
        call alout

        mov  al, 0x60
        add  al, cl
        mov  ah, 0xF0           ; fastest attack, no decay
        call alout
        mov  al, 0x63
        add  al, cl
        mov  ah, 0xF0
        call alout

        mov  al, 0x80
        add  al, cl
        mov  ah, 0x77           ; mid sustain, moderate release
        call alout
        mov  al, 0x83
        add  al, cl
        mov  ah, 0x77
        call alout

        mov  al, 0xE0
        add  al, cl
        mov  ah, 0x00           ; plain sine
        call alout
        mov  al, 0xE3
        add  al, cl
        mov  ah, 0x00
        call alout

        mov  al, 0xC0
        add  al, bl
        mov  ah, 0x00           ; FM, no feedback
        call alout

        inc  bl
        jmp  short .ic1
.ic2:
        pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
; note_on  -- BL = channel, BH = block, CX = F-number
note_on:
        push ax
        mov  al, 0xA0
        add  al, bl
        mov  ah, cl             ; F-number low eight bits
        call alout
        mov  al, 0xB0
        add  al, bl
        mov  ah, bh
        shl  ah, 1
        shl  ah, 1              ; block into bits 4:2
        or   ah, ch             ; F-number high two bits
        or   ah, 0x20           ; key on
        call alout
        pop  ax
        ret

; note_off -- BL = channel
note_off:
        push ax
        mov  al, 0xB0
        add  al, bl
        mov  ah, 0
        call alout
        pop  ax
        ret

; silence -- key off everything, so quitting never leaves a note hanging
silence:
        push bx
        xor  bl, bl
.s1:    cmp  bl, 9
        jae  .s2
        call note_off
        inc  bl
        jmp  short .s1
.s2:    pop  bx
        ret

; ---------------------------------------------------------------------------
; alout -- AL = register index, AH = value.
;
; The dummy reads are the documented settling delays a real OPL2 needs between
; the index write and the data write, and again afterwards. They cost nothing
; here and they are what makes this tool honest on real hardware.
alout:
        push ax
        push cx
        push dx
        mov  dx, ADLIB
        out  dx, al
        mov  cx, 6
.a1:    in   al, dx
        loop .a1
        inc  dx
        mov  al, ah
        out  dx, al
        dec  dx
        mov  cx, 35
.a2:    in   al, dx
        loop .a2
        pop  dx
        pop  cx
        pop  ax
        ret

; ---------------------------------------------------------------------------
; wait_ticks -- CX BIOS ticks of about 55 ms
wait_ticks:
        push ax
        push bx
        push cx
        push es
        mov  ax, 0x40
        mov  es, ax
.w1:    jcxz .w3
        mov  bx, [es:0x6C]
.w2:    cmp  bx, [es:0x6C]
        je   .w2
        dec  cx
        jmp  short .w1
.w3:    pop  es
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
verdict:                        ; AL = 0 means the test passed
        push dx
        mov  dx, msg_ok
        test al, al
        jz   .v1
        mov  dx, msg_bad
.v1:    call puts
        pop  dx
        ret

putal:  push ax
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

puthexb:
        push ax
        push bx
        push cx
        mov  bl, al
        mov  cl, 4
        shr  al, cl
        call .n
        mov  al, bl
        call .n
        pop  cx
        pop  bx
        pop  ax
        ret
.n:     and  al, 0x0F
        cmp  al, 10
        jb   .d
        add  al, 'A'-10
        jmp  short .e
.d:     add  al, '0'
.e:     call putal
        ret

; ---------------------------------------------------------------------------
sreg1     db 0
sreg2     db 0
blk     db 4

; Operator 1 offset for each channel; operator 2 is always +3. The gaps are
; the chip's, not a mistake -- the operator map is not contiguous.
opofs   db 0x00,0x01,0x02, 0x08,0x09,0x0A, 0x10,0x11,0x12

; F-numbers for one octave at block 4, worst case 1.9 cents from equal
; temperament. Higher octaves just raise the block.
notes:  dw 345      ; C
        dw 365      ; C#
        dw 387      ; D
        dw 410      ; D#
        dw 435      ; E
        dw 460      ; F
        dw 488      ; F#
        dw 517      ; G
        dw 547      ; G#
        dw 580      ; A
        dw 615      ; A#
        dw 651      ; B

chord   db 0, 4, 7, 11, 0xFF    ; C E G B -- indices into the table above

msg_hdr db 'ADLIBCHK - bench test for the AdLib at 0x388',13,10
        db '--------------------------------------------',13,10,'$'
msg_t1  db 13,10,'1  detection',13,10,'$'
msg_s1  db '     status1 = $'
msg_want1 db '   want 00 in bits 7-5 : $'
msg_s2  db '     status2 = $'
msg_want2 db '   want C0 in bits 7-5 : $'
msg_ok  db 'OK',13,10,'$'
msg_bad db 'WRONG',13,10,'$'
msg_found db '     -> AdLib detected. Making noise.',13,10,'$'
msg_notfound db '     -> no AdLib here. Nothing would be heard, so stopping.',13,10
        db '        On this board that means opl2_lite is absent from the',13,10
        db '        build, or its timers are not keeping real time.',13,10,'$'
msg_t2  db 13,10,'2  scale   two chromatic octaves, channel 0',13,10,'$'
msg_t3  db 13,10,'3  chord   four channels at once - tests the PWM mixer',13,10,'$'
msg_t4  db 13,10,'4  sweep   each channel alone; listen for a silent one',13,10
        db '     channel $'
msg_chan db ' $'
msg_done db 13,10,13,10,'Done. All channels keyed off.',13,10,'$'
