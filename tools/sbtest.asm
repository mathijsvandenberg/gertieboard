; sbtest.asm -- prove the Sound Blaster DSP works, one stage at a time.
;
; Each stage prints what it found rather than just passing or failing, because
; "no sound" has half a dozen causes and they need separating: the DSP not
; answering its reset is a different fault from the DSP answering and the DMA
; never running, which is different again from both working and the interrupt
; never arriving.
;
;   sbtest        detect, then play a tone
;   sbtest -d     detect only, no DMA
;   sbtest -p     play using the direct DAC (command 0x10), no DMA at all
;
; The direct-DAC mode matters: if -p makes a noise and the default does not,
; the DSP and the audio path are fine and the fault is in the DMA. That splits
; the problem in half without a logic analyser.

CPU 8086
org 0x100

SB      equ 0x220
RESETP  equ SB+6
READP   equ SB+0x0A
WRITEP  equ SB+0x0C
RSTATP  equ SB+0x0E

RATE    equ 11025
TCONST  equ 256 - (1000000 / RATE)      ; 0xA6 -> 11025 Hz
BUFLEN  equ 8192                        ; ~0.74 s at 11 kHz

start:
        mov  dx, msg_hdr
        call puts

        ; ---- which mode? ----
        mov  byte [mode], 0
        mov  si, 0x81
.scan:
        lodsb
        cmp  al, 13
        je   .scanned
        cmp  al, 'd'
        jne  .n_d
        mov  byte [mode], 1
.n_d:
        cmp  al, 'p'
        jne  .n_p
        mov  byte [mode], 2
.n_p:
        jmp  .scan
.scanned:

        ; =================== 1. reset ===================
        ; Write 1, wait, write 0. The DSP answers 0xAA. A card that is not
        ; there reads back 0xFF from an open bus, which is why the value is
        ; checked rather than just the ready bit.
        mov  dx, msg_reset
        call puts
        mov  dx, RESETP
        mov  al, 1
        out  dx, al
        mov  cx, 100
.rwait: in   al, 0x80                   ; ~1 us apiece, no timer needed
        loop .rwait
        xor  al, al
        out  dx, al

        mov  cx, 1000
.rpoll: mov  dx, RSTATP
        in   al, dx
        test al, 0x80
        jnz  .rgot
        loop .rpoll
        mov  dx, msg_nordy
        call puts
        jmp  .fail
.rgot:
        mov  dx, READP
        in   al, dx
        mov  [rstval], al
        call puthex
        cmp  al, 0xAA
        je   .rok
        mov  dx, msg_notaa
        call puts
        jmp  .fail
.rok:
        mov  dx, msg_ok
        call puts

        ; =================== 2. version ===================
        mov  dx, msg_ver
        call puts
        mov  al, 0xE1
        call dspwr
        call dsprd
        mov  [vmaj], al
        call putdec
        mov  dx, msg_dot
        call puts
        call dsprd
        call putdec
        mov  dx, msg_crlf
        call puts

        cmp  byte [mode], 1
        jne  .go
        jmp  .done
.go:

        ; =================== 3. build a tone ===================
        ; A square wave, because it is unmistakable: if the DAC is only getting
        ; every other byte, or the rate is wrong, a square wave still tells you
        ; so by its pitch. A sine would just sound quiet and odd.
        mov  dx, msg_fill
        call puts
        mov  ax, cs
        add  ax, 0x1000                 ; well clear of this program
        mov  es, ax
        xor  di, di
        mov  cx, BUFLEN
        xor  bx, bx
.fill:
        mov  al, 0x40
        test bh, 0x10                   ; ~430 Hz at 11 kHz
        jz   .lo
        mov  al, 0xC0
.lo:    stosb
        inc  bx
        loop .fill
        mov  dx, msg_ok
        call puts

        ; =================== 4. speaker on ===================
        mov  al, 0xD1
        call dspwr

        cmp  byte [mode], 2
        jne  .dma
        jmp  .direct
.dma:

        ; =================== 5. programme DMA channel 1 ===================
        ; The physical address is ES:0 flattened. The buffer must not cross a
        ; 64 KB boundary -- the 8237 counts within a page and simply wraps,
        ; which sounds like the tail of the buffer being replaced by whatever
        ; is at the start of the page.
        mov  dx, msg_dma
        call puts
        ; 8086: shifts are by 1 or by CL. An immediate count above 1 is a 186
        ; instruction and this machine must not need one.
        mov  ax, es
        mov  bx, ax
        mov  cl, 12
        shr  bx, cl                     ; page = physical bits 19:16
        mov  cl, 4
        shl  ax, cl                     ; offset within the page

        mov  [physlo], ax
        mov  [physpg], bl

        mov  al, 0x05                   ; mask channel 1
        out  0x0A, al
        xor  al, al
        out  0x0C, al                   ; clear the byte pointer
        mov  al, 0x49                   ; single mode, read from memory, ch1
        out  0x0B, al

        mov  ax, [physlo]
        out  0x02, al
        mov  al, ah
        out  0x02, al
        mov  al, [physpg]
        out  0x83, al                   ; page register for channel 1

        mov  ax, BUFLEN-1
        out  0x03, al
        mov  al, ah
        out  0x03, al

        mov  al, 0x01                   ; unmask channel 1
        out  0x0A, al
        mov  dx, msg_ok
        call puts

        ; =================== 6. rate, then go ===================
        mov  dx, msg_play
        call puts
        mov  al, 0x40
        call dspwr
        mov  al, TCONST
        call dspwr

        mov  al, 0x14                   ; single-cycle 8-bit DMA output
        call dspwr
        mov  ax, BUFLEN-1
        call dspwr                      ; low
        mov  al, ah
        call dspwr                      ; high

        ; ---- wait for the buffer to finish ----
        ; Polling the DMA count rather than the interrupt: this says whether
        ; the transfer is MOVING, which is the question. An interrupt that
        ; never arrives cannot distinguish "DMA never started" from "DMA ran
        ; and the IRQ is misrouted", and those need different fixes.
        mov  cx, 0
.wait:
        push cx
        xor  al, al
        out  0x0C, al
        in   al, 0x03
        mov  bl, al
        in   al, 0x03
        mov  bh, al
        pop  cx
        ; Done when the count reaches zero. A real 8237 wraps past it to FFFF
        ; and this model stops at 0, so accept either rather than assuming.
        cmp  bx, 0
        je   .played
        cmp  bx, 0xFFFF
        je   .played
        loop .wait

        ; BX still holds the last count read, which is the useful number: if it
        ; equals BUFLEN-1 the DMA never moved at all, and anything between says
        ; it started and stalled. Printing a stored copy here once printed 0000
        ; regardless, which looks exactly like the first case.
        mov  dx, msg_stuck
        call puts
        mov  ax, bx
        call puthexw
        mov  dx, msg_crlf
        call puts
        jmp  .fail
.played:
        mov  dx, msg_ok
        call puts
        jmp  .quiet

.direct:
        ; Direct DAC: no DMA, no interrupt, just the CPU writing samples. If
        ; this makes a noise the audio path is proven and anything wrong is in
        ; the DMA; if it does not, nothing downstream is worth debugging yet.
        mov  dx, msg_dac
        call puts
        mov  cx, 4000
.dloop:
        mov  al, 0x10
        call dspwr
        ; Toggle on a LOW bit of the counter. Using CH toggled once every 512
        ; samples, which at this loop's rate is about 33 Hz -- individual pops,
        ; not a tone, and it sounded exactly like a fault in the hardware.
        mov  al, 0x40
        test cl, 0x08                   ; ~1 kHz
        jz   .dlo
        mov  al, 0xC0
.dlo:   call dspwr
        push cx
        mov  cx, 60                     ; crude rate, this is a smoke test
.dwait: in   al, 0x80
        loop .dwait
        pop  cx
        loop .dloop
        mov  dx, msg_ok
        call puts

.quiet:
        mov  al, 0xD3                   ; speaker off
        call dspwr
.done:
        mov  dx, msg_fin
        call puts
        mov  ax, 0x4C00
        int  0x21
.fail:
        mov  dx, msg_fail
        call puts
        mov  ax, 0x4C01
        int  0x21

; ---- DSP write: poll bit 7 of the write port, then send ---------------------
dspwr:
        push ax
        push cx
        push dx
        mov  cx, 4000
        mov  dx, WRITEP
.w:     in   al, dx
        test al, 0x80
        jz   .ready
        loop .w
.ready:
        pop  dx
        pop  cx
        pop  ax
        push dx
        mov  dx, WRITEP
        out  dx, al
        pop  dx
        ret

; ---- DSP read: poll bit 7 of the status port, then fetch -------------------
dsprd:
        push cx
        push dx
        mov  cx, 4000
.r:     mov  dx, RSTATP
        in   al, dx
        test al, 0x80
        jnz  .got
        loop .r
        xor  al, al
        pop  dx
        pop  cx
        ret
.got:
        mov  dx, READP
        in   al, dx
        pop  dx
        pop  cx
        ret

; ---- output helpers --------------------------------------------------------
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
        shr  al, 1
        shr  al, 1
        shr  al, 1
        shr  al, 1
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

puthexw:
        push ax
        mov  al, ah
        call puthex
        pop  ax
        call puthex
        ret

putdec:
        push ax
        push bx
        push cx
        push dx
        xor  ah, ah
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
mode    db 0
rstval  db 0
vmaj    db 0
physlo  dw 0
physpg  db 0

msg_hdr   db 'SBTEST - Sound Blaster DSP at 220h, IRQ 5, DMA 1',13,10,13,10,'$'
msg_reset db 'reset    : $'
msg_ver   db 'version  : $'
msg_fill  db 'tone buf : $'
msg_dma   db 'DMA ch1  : $'
msg_play  db 'playing  : $'
msg_dac   db 'direct   : $'
msg_ok    db ' ok',13,10,'$'
msg_dot   db '.$'
msg_crlf  db 13,10,'$'
msg_nordy db ' NO RESPONSE - the DSP never raised the ready bit',13,10,'$'
msg_notaa db ' not AA - something answered, but it is not a DSP',13,10,'$'
msg_stuck db ' DMA DID NOT MOVE, count still $'
msg_fin   db 13,10,'done.',13,10,'$'
msg_fail  db 13,10,'FAILED.',13,10,'$'
