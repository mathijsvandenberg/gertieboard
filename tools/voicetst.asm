; voicetst.asm -- prove the hardware voice engine at 0x300.
;
; The voices fetch their samples from ordinary memory, so this builds a 256-byte
; TRIANGLE in its own segment and points the voices at it. A triangle rather
; than a sawtooth deliberately: the engine's stage-one placeholder was a
; sawtooth from the phase accumulator, and a tone that still sounds like one
; would not prove the fetch is doing anything.
;
; A 256-byte wave played at rate R sounds at R/256, so 440 Hz needs the voice
; stepping at 2.35 bytes per output sample -- which also exercises the integer
; part of the step, and with it the address arithmetic and the loop wrap.
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

        ; ---- build the waveform, and work out where it is ----
        ; Physical address = segment*16 + offset, which is exactly what the
        ; engine wants: the samples stay where they were put, with no upload.
        ; SIGNED, so the ramp starts at -128 and not at 0. Building it unsigned
        ; puts a wrap in the middle of the rise, which is a sawtooth with a
        ; discontinuity -- and would have sounded near enough like the stage-one
        ; placeholder to be mistaken for it.
        mov  di, wave
        mov  cx, 128
        mov  al, 0x80                   ; -128
.up:    mov  [di], al
        inc  di
        add  al, 2
        loop .up
        mov  cx, 128
.dn:    mov  [di], al
        inc  di
        sub  al, 2
        loop .dn

        mov  ax, cs
        mov  bx, ax
        mov  cl, 12
        shr  bx, cl                     ; physical bits 19:16
        mov  cl, 4
        shl  ax, cl                     ; segment*16, low 16 bits
        add  ax, wave
        adc  bx, 0
        mov  [phys_lo], ax
        mov  [phys_hi], bl

        mov  dx, msg_at
        call puts
        mov  al, [phys_hi]
        call puthex
        mov  ax, [phys_lo]
        mov  al, ah
        call puthex
        mov  ax, [phys_lo]
        call puthex
        mov  dx, msg_crlf
        call puts

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

        mov  dx, VSTART
        mov  ax, [phys_lo]
        out  dx, al
        inc  dx
        mov  al, ah
        out  dx, al
        inc  dx
        mov  al, [phys_hi]
        out  dx, al

        mov  dx, VEND                   ; start + 256
        mov  ax, [phys_lo]
        add  ax, 256
        mov  cl, [phys_hi]
        adc  cl, 0
        out  dx, al
        inc  dx
        mov  al, ah
        out  dx, al
        inc  dx
        mov  al, cl
        out  dx, al

        mov  dx, VLOOP                  ; loops back to the start
        mov  ax, [phys_lo]
        out  dx, al
        inc  dx
        mov  al, ah
        out  dx, al
        inc  dx
        mov  al, [phys_hi]
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
        mov  si, ints
        add  si, bx
        mov  al, [si]
        out  dx, al                     ; integer part

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
; step = f * 256 / 48000, in 8.16. A 256-byte wave sounds at rate/256, so these
; are the same major scale as before but now with a real integer part -- which
; is what exercises the address arithmetic rather than just the fraction.
steps   dw 0x59B7, 0x0F5C, 0xF2E8, 0xB0A4, 0x82C1, 0x6FD6, 0x8E3C, 0xB36E
ints    db 2, 3, 2, 3, 3, 3, 4, 4
phys_lo dw 0
phys_hi db 0

msg_hdr    db 'VOICETST - hardware voice engine at 300h',13,10,13,10,'$'
msg_probe  db 'signature : $'
msg_found  db '  found - $'
msg_voices db ' voices',13,10,'$'
msg_play   db 'keying    : $'
msg_act    db 13,10,'ACTIVE    : $'
msg_any    db 'sounding - press a key to stop',13,10,'$'
msg_done   db 'stopped.',13,10,'$'
wave       times 256 db 0
msg_absent db 13,10,'no voice engine here - this bitstream does not have one',13,10,'$'
msg_at     db 'wave at   : $'
msg_crlf   db 13,10,'$'
