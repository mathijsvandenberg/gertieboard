; voicetst.asm -- prove the hardware voice engine at 0x300.
;
; Stage one: the engine's sample source is a sawtooth taken from its own phase
; accumulator, not memory. So a voice keyed with a given step sounds a tone at
; that pitch, and this can exercise the registers, the pitch arithmetic, the
; clock crossing, the volume multiply and the summing without the memory
; controller being involved at all.
;
;   voicetst      probe, then play eight voices as a chord
;   voicetst -1   one voice only, to hear a single clean tone
;
; USBAUDIO has to be streaming first: the voices sum into the same PCM path the
; OPL2 and the Sound Blaster already share.

CPU 8086
org 0x100

VB      equ 0x300               ; VOICESEL / ID0
VCTL    equ VB+1
VVOL    equ VB+2
VSTART  equ VB+3
VEND    equ VB+6
VLOOP   equ VB+9
VSTEP   equ VB+0x0C
VACTIVE equ VB+0x0F

start:
        mov  dx, msg_hdr
        call puts

        ; ---- probe ----
        ; A positive signature, not "did something answer". An absent engine
        ; reads FF from an open bus or 00 from a decoded-but-empty one, and
        ; neither spells GV.
        mov  dx, msg_probe
        call puts
        mov  dx, VB
        in   al, dx
        mov  [id0], al
        call puthex
        inc  dx
        in   al, dx
        mov  [id1], al
        call puthex
        cmp  byte [id0], 'G'
        jne  .none
        cmp  byte [id1], 'V'
        jne  .none
        mov  dx, msg_found
        call puts

        mov  dx, VB+2
        in   al, dx
        mov  [nvoice], al
        xor  ah, ah
        call putdec
        mov  dx, msg_voices
        call puts

        ; ---- how many to sound? ----
        mov  al, [nvoice]
        mov  [nplay], al
        mov  si, 0x81
.scan:
        lodsb
        cmp  al, 13
        je   .scanned
        cmp  al, '1'
        jne  .scan
        mov  byte [nplay], 1
        jmp  .scan
.scanned:

        ; ---- key them ----
        mov  dx, msg_play
        call puts
        xor  bx, bx                     ; voice number
.vloop:
        mov  al, bl
        cmp  al, [nplay]
        jae  .keyed

        mov  dx, VB                     ; select the voice
        mov  al, bl
        out  dx, al

        ; the sawtooth runs from the phase, so start/end/loop only have to be
        ; a range it will not leave: the step below advances the integer part
        ; once every few hundred ticks.
        mov  dx, VSTART
        xor  al, al
        out  dx, al
        inc  dx
        out  dx, al
        inc  dx
        out  dx, al

        mov  dx, VEND                   ; 0xFFFFF
        mov  al, 0xFF
        out  dx, al
        inc  dx
        out  dx, al
        inc  dx
        mov  al, 0x0F
        out  dx, al

        mov  dx, VLOOP
        xor  al, al
        out  dx, al
        inc  dx
        out  dx, al
        inc  dx
        out  dx, al

        mov  dx, VVOL                   ; quieter with more voices sounding, so
        mov  al, 64                     ; eight together do not clip the sum
        cmp  byte [nplay], 1
        je   .volset
        mov  al, 16
.volset:
        out  dx, al

        ; step = f * 65536 / 48000, from the table
        mov  si, steps
        add  si, bx
        add  si, bx
        mov  ax, [si]
        mov  dx, VSTEP
        out  dx, al                     ; fraction low
        inc  dx
        mov  al, ah
        out  dx, al                     ; fraction high
        inc  dx
        xor  al, al
        out  dx, al                     ; integer part: none of these reach 1.0

        mov  dx, VCTL                   ; RUN | LOOP | KEYON
        mov  al, 0x07
        out  dx, al

        inc  bx
        jmp  .vloop
.keyed:

        ; ---- what does the engine say is playing? ----
        mov  dx, msg_act
        call puts
        mov  dx, VACTIVE
        in   al, dx
        call puthex
        mov  dx, msg_crlf
        call puts

        mov  dx, msg_any
        call puts
        mov  ah, 0
        int  0x16

        ; ---- silence every voice ----
        xor  bx, bx
.off:
        mov  dx, VB
        mov  al, bl
        out  dx, al
        mov  dx, VCTL
        xor  al, al                     ; RUN clear
        out  dx, al
        inc  bx
        cmp  bl, 8
        jb   .off

        mov  dx, msg_done
        call puts
        mov  ax, 0x4C00
        int  0x21

.none:
        mov  dx, msg_absent
        call puts
        mov  ax, 0x4C01
        int  0x21

; ---- helpers ---------------------------------------------------------------
puts:
        push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthex:
        push ax
        push bx
        mov  bl, al
        mov  cl, 4
        shr  al, cl
        call .nib
        mov  al, bl
        and  al, 0x0F
        call .nib
        pop  bx
        pop  ax
        ret
.nib:
        add  al, '0'
        cmp  al, '9'
        jbe  .em
        add  al, 7
.em:
        push dx
        mov  dl, al
        mov  ah, 2
        int  0x21
        pop  dx
        ret

putdec:
        push ax
        push bx
        push cx
        push dx
        mov  bx, 10
        xor  cx, cx
.dv:    xor  dx, dx
        div  bx
        push dx
        inc  cx
        test ax, ax
        jnz  .dv
.pr:    pop  dx
        add  dl, '0'
        mov  ah, 2
        int  0x21
        loop .pr
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---- data ------------------------------------------------------------------
id0     db 0
id1     db 0
nvoice  db 0
nplay   db 0

; step = frequency * 65536 / 48000. A major scale, so eight voices sounding
; together are recognisable as eight rather than as a noise.
steps   dw 601, 674, 756, 801, 900, 1010, 1134, 1201

msg_hdr    db 'VOICETST - hardware voice engine at 300h',13,10,13,10,'$'
msg_probe  db 'signature : $'
msg_found  db '  found - $'
msg_voices db ' voices',13,10,'$'
msg_play   db 'keying    : $'
msg_act    db 13,10,'ACTIVE    : $'
msg_any    db 'sounding - press a key to stop',13,10,'$'
msg_done   db 'stopped.',13,10,'$'
msg_absent db 13,10,'no voice engine here - this bitstream does not have one',13,10,'$'
msg_crlf   db 13,10,'$'
