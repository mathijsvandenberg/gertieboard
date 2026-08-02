; ============================================================================
;  adlibsng.asm  --  play a real tune through the AdLib, in three voices
;
;  ADLIBCHK proves the card answers and that each channel makes a noise. It
;  cannot tell you whether the thing SOUNDS right, because a scale sounds fine
;  even when the octaves are wrong and a sweep sounds fine when the timing is.
;  Music is a much harsher test: a wrong octave, a stuck note, a channel that
;  never releases or a mixer that clips are all obvious the moment you hear a
;  melody you know, and nearly invisible on a test tone.
;
;  Three voices at once, which is the part that matters most here -- the melody
;  in the middle register, the bass beneath it, and the bass doubled an octave
;  up. That exercises three simultaneous channels, three different blocks, and
;  the PWM mixer, continuously and under changing load.
;
;  The piece is the "Ode to Joy" theme from Beethoven's Ninth Symphony -- 1824,
;  long out of copyright, and about as recognisable as music gets, which is
;  exactly what makes a wrong note stand out.
;
;  Tempo comes from the 18.2 Hz BIOS tick, so a beat is 8 ticks = 440 ms, about
;  136 BPM. Coarse, but every duration in the score is a whole number of ticks,
;  so nothing is rounded and the rhythm stays even.
;
;      adlibsng          play once
;      adlibsng r        repeat until a key is pressed
;
;  Build:  nasm -f bin adlibsng.asm -o adlibsng.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

ADLIB   equ 0x388
VOICES  equ 3

start:
        mov  dx, msg_hdr
        call puts

        call detect
        jc   .nocard

        mov  al, [0x80]         ; any command tail at all means "repeat"
        test al, al
        jz   .once
        mov  byte [loopit], 1
.once:
        call init_chans

.again:
        call play
        call silence
        cmp  byte [loopit], 0
        je   .fin
        mov  ah, 1              ; a key ends the loop
        int  0x16
        jz   .again
        mov  ah, 0
        int  0x16
.fin:
        mov  dx, msg_done
        call puts
        jmp  short bye
.nocard:
        mov  dx, msg_nocard
        call puts
bye:
        call silence
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
;  play -- step all three voices together, one BIOS tick at a time
;
;  Each voice holds a position in its own score and a countdown. When a
;  countdown reaches zero the voice releases its note, reads the next pair, and
;  keys on again. Voices finish independently, so the bass can hold under a
;  melody that has already moved on -- which is the whole point of testing with
;  three of them.
; ---------------------------------------------------------------------------
play:
        push ax
        push bx
        push cx
        push si
        push di

        xor  si, si             ; voice index
.init:
        mov  byte [vrem+si], 0
        mov  byte [vdone+si], 0
        mov  bl, [vscore+si]    ; which score this voice reads
        mov  bh, 0
        shl  bx, 1
        mov  ax, [scores+bx]    ; -> its start address
        mov  bx, si
        shl  bx, 1
        mov  [vptr+bx], ax
        inc  si
        cmp  si, VOICES
        jb   .init

.tick:
        xor  si, si
.svc:
        cmp  byte [vdone+si], 0
        jne  .nextv
        cmp  byte [vrem+si], 0
        jne  .nextv

        ; this voice needs its next event
        mov  bl, [vchan+si]
        call note_off

        mov  bx, si
        shl  bx, 1
        mov  di, [vptr+bx]
        mov  al, [di]           ; note, or 0xFF rest, or 0xFE end
        inc  di
        cmp  al, 0xFE
        jne  .havenote
        mov  byte [vdone+si], 1
        jmp  short .nextv
.havenote:
        mov  ah, [di]           ; duration in ticks
        inc  di
        mov  [vptr+bx], di
        mov  [vrem+si], ah
        cmp  al, 0xFF
        je   .nextv             ; a rest: counted, but nothing keyed on
        add  al, [voct+si]      ; the voice's octave offset
        mov  bl, [vchan+si]
        call sem_on
.nextv:
        inc  si
        cmp  si, VOICES
        jb   .svc

        ; all finished?
        mov  al, [vdone]
        and  al, [vdone+1]
        and  al, [vdone+2]
        test al, al
        jnz  .fin

        mov  cx, 1
        call wait_ticks

        xor  si, si
.dec:   cmp  byte [vrem+si], 0
        je   .dec2
        dec  byte [vrem+si]
.dec2:  inc  si
        cmp  si, VOICES
        jb   .dec
        jmp  short .tick
.fin:
        pop  di
        pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
; sem_on -- AL = semitone index, BL = channel.
;
; Index 0 is C at block 3, and every twelve steps is one octave, so the block
; and the F-number both fall out of one division. This is the only arithmetic
; in the tool, which is a good sign: the OPL2's pitch model does the rest.
sem_on:
        push ax
        push cx
        push si
        xor  ah, ah
        mov  cl, 12
        div  cl                 ; AL = octave, AH = note within it
        add  al, 3              ; blocks start at 3
        mov  bh, al
        mov  al, ah
        xor  ah, ah
        shl  ax, 1
        mov  si, notes
        add  si, ax
        mov  cx, [si]
        call note_on
        pop  si
        pop  cx
        pop  ax
        ret

; ---------------------------------------------------------------------------
; detect -- CF=0 if the AdLib answered. Same handshake as ADLIBCHK.
detect:
        push ax
        push cx
        push dx
        mov  al, 4
        mov  ah, 0x60
        call alout
        mov  al, 4
        mov  ah, 0x80
        call alout
        mov  dx, ADLIB
        in   al, dx
        mov  [sv1], al
        mov  al, 2
        mov  ah, 0xFF
        call alout
        mov  al, 4
        mov  ah, 0x21
        call alout
        mov  cx, 0
.d1:    loop .d1
        mov  dx, ADLIB
        in   al, dx
        mov  [sv2], al
        mov  al, 4
        mov  ah, 0x60
        call alout
        mov  al, 4
        mov  ah, 0x80
        call alout
        mov  al, [sv1]
        and  al, 0xE0
        jnz  .no
        mov  al, [sv2]
        and  al, 0xE0
        cmp  al, 0xC0
        jne  .no
        clc
        jmp  short .out
.no:    stc
.out:   pop  dx
        pop  cx
        pop  ax
        ret

; ---------------------------------------------------------------------------
; init_chans -- a plain sustained tone on all nine channels.
; opl2_lite ignores every one of these, but a real OPL2 is silent without them.
init_chans:
        push ax
        push bx
        push cx
        push si
        xor  bl, bl
.c1:    cmp  bl, 9
        jae  .c2
        mov  si, opofs
        mov  al, bl
        xor  ah, ah
        add  si, ax
        mov  cl, [si]

        mov  al, 0x20
        add  al, cl
        mov  ah, 0x01
        call alout
        mov  al, 0x23
        add  al, cl
        mov  ah, 0x01
        call alout
        mov  al, 0x40
        add  al, cl
        mov  ah, 0x10
        call alout
        mov  al, 0x43
        add  al, cl
        mov  ah, 0x00
        call alout
        mov  al, 0x60
        add  al, cl
        mov  ah, 0xF0
        call alout
        mov  al, 0x63
        add  al, cl
        mov  ah, 0xF0
        call alout
        mov  al, 0x80
        add  al, cl
        mov  ah, 0x77
        call alout
        mov  al, 0x83
        add  al, cl
        mov  ah, 0x77
        call alout
        mov  al, 0xE0
        add  al, cl
        mov  ah, 0x00
        call alout
        mov  al, 0xE3
        add  al, cl
        mov  ah, 0x00
        call alout
        mov  al, 0xC0
        add  al, bl
        mov  ah, 0x00
        call alout
        inc  bl
        jmp  short .c1
.c2:    pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
note_on:                        ; BL = channel, BH = block, CX = F-number
        push ax
        mov  al, 0xA0
        add  al, bl
        mov  ah, cl
        call alout
        mov  al, 0xB0
        add  al, bl
        mov  ah, bh
        shl  ah, 1
        shl  ah, 1
        or   ah, ch
        or   ah, 0x20
        call alout
        pop  ax
        ret

note_off:                       ; BL = channel
        push ax
        mov  al, 0xB0
        add  al, bl
        mov  ah, 0
        call alout
        pop  ax
        ret

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

alout:                          ; AL = register, AH = value
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

wait_ticks:                     ; CX BIOS ticks
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

puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

; ---------------------------------------------------------------------------
;  state
; ---------------------------------------------------------------------------
sv1     db 0
sv2     db 0
loopit  db 0

vchan   db 0, 1, 2              ; OPL channel per voice
voct    db 0, 0, 12             ; semitones added: voice 2 doubles the bass up
vscore  db 0, 1, 1              ; which score each voice reads
vrem    db 0, 0, 0
vdone   db 0, 0, 0
vptr    dw 0, 0, 0

scores  dw melody, bass

opofs   db 0x00,0x01,0x02, 0x08,0x09,0x0A, 0x10,0x11,0x12

; F-numbers for one octave; worst case 1.9 cents from equal temperament.
notes:  dw 345, 365, 387, 410, 435, 460, 488, 517, 547, 580, 615, 651
;          C    C#   D    D#   E    F    F#   G    G#   A    A#   B

; ---------------------------------------------------------------------------
;  The score.  Note index, then duration in ticks.
;
;  Index 0 = C at block 3, so 12 = C4 and 24 = C5.  0xFF is a rest, 0xFE ends
;  the part.  A beat is 8 ticks, so 4 = eighth, 8 = quarter, 12 = dotted
;  quarter, 16 = half, 32 = whole.
;
;  Beethoven, Symphony No. 9 (1824) -- public domain.
; ---------------------------------------------------------------------------
E4      equ 16
F4      equ 17
G4      equ 19
D4      equ 14
C4      equ 12

melody:
        db E4,8, E4,8, F4,8, G4,8          ; bar 1
        db G4,8, F4,8, E4,8, D4,8          ; bar 2
        db C4,8, C4,8, D4,8, E4,8          ; bar 3
        db E4,12, D4,4, D4,16              ; bar 4
        db E4,8, E4,8, F4,8, G4,8          ; bar 5
        db G4,8, F4,8, E4,8, D4,8          ; bar 6
        db C4,8, C4,8, D4,8, E4,8          ; bar 7
        db D4,12, C4,4, C4,16              ; bar 8
        db 0xFE

; One root per bar, held. Deliberately plain: this is here to put a second and
; third channel under load at a different block, not to be an arrangement.
C3      equ 0
G3      equ 7

bass:
        db C3,32                           ; bar 1
        db G3,32                           ; bar 2
        db C3,32                           ; bar 3
        db G3,32                           ; bar 4
        db C3,32                           ; bar 5
        db G3,32                           ; bar 6
        db G3,32                           ; bar 7
        db C3,32                           ; bar 8
        db 0xFE

msg_hdr db 'ADLIBSNG - three-voice tune through the AdLib at 0x388',13,10
        db '-----------------------------------------------------',13,10
        db 'Melody, bass, and the bass doubled an octave up: three',13,10
        db 'channels, three blocks, and the mixer under real load.',13,10,13,10
        db 'Listen for wrong octaves, notes that never release, and',13,10
        db 'the bass dropping out when the melody is busy.',13,10,13,10,'$'
msg_nocard db 'No AdLib answered at 0x388. Run ADLIBCHK to see which half',13,10
        db 'of the detection handshake failed.',13,10,'$'
msg_done db 13,10,'Done. All channels keyed off.',13,10,'$'
