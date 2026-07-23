; ============================================================================
;  cgatest3.asm  --  timer / INT 8 test (DOS .COM)
;
;  cgatest + cgatest2 proved the CGA hardware and the BIOS mode-set both work,
;  so Digger's blank screen must be a hang AFTER the mode set.  The usual
;  culprit: Digger reprograms PIT channel 0 to a fast rate and runs its game
;  loop (including the first frame draw) from the INT 8 timer interrupt.  If
;  INT 8 stops firing once the divisor is changed, the game freezes blank.
;
;  This test reproduces that setup in isolation:
;    - set CGA mode 4 (so we can see), clear screen, draw a static white top
;      row as a "we got here" reference,
;    - hook INT 8 with a tiny ISR that (a) grows a white trail across the
;      screen and (b) writes a running counter to port 0x80 (the 7-seg display),
;    - reprogram PIT ch0 to ~1 kHz (divisor 1193), exactly the kind of thing
;      Digger does,
;    - idle until a key is pressed, then cleanly restore.
;
;  Interpreting it:
;    * White trail grows AND the 7-seg keeps changing -> a reprogrammed timer
;      still delivers INT 8.  The timer path is NOT Digger's problem; the hang
;      is elsewhere (keyboard INT 9, a CPU-speed calibration loop, or a feature
;      check) and I'll chase that next.
;    * Static top row shows but the trail is FROZEN and the 7-seg is STUCK ->
;      INT 8 stops after the PIT is reprogrammed.  That is the Digger hang, and
;      the fix is in timer8253.vhd / the PIC path.
;
;  Build:  nasm -f bin cgatest3.asm -o cgatest3.com
; ============================================================================

        org  0x100
        bits 16

VID     equ 0xB800

start:
        mov  ax, 0x0004         ; BIOS: CGA mode 4
        int  0x10

        ; clear both interleave banks, then draw a static white top row
        mov  ax, VID
        mov  es, ax
        xor  di, di
        xor  al, al
        mov  cx, 0x4000
        rep  stosb
        xor  di, di
        mov  al, 0xFF
        mov  cx, 80             ; top scanline = solid white reference
        rep  stosb

        mov  word [counter], 0

        ; ---- hook INT 8 (save old vector) ----
        cli
        xor  ax, ax
        mov  es, ax
        mov  ax, [es:0x20]
        mov  [oldint8], ax
        mov  ax, [es:0x22]
        mov  [oldint8+2], ax
        mov  word [es:0x20], isr8
        mov  [es:0x22], cs

        ; ---- reprogram PIT channel 0 to ~1 kHz (divisor 1193) ----
        mov  al, 0x36           ; ch0, lo/hi, mode 3, binary
        out  0x43, al
        mov  ax, 1193
        out  0x40, al           ; divisor low
        mov  al, ah
        out  0x40, al           ; divisor high
        sti

.wait:
        mov  ah, 0x01
        int  0x16
        jz   .wait
        xor  ah, ah
        int  0x16               ; consume the key

        ; ---- restore PIT to 18.2 Hz and the old INT 8 vector ----
        cli
        mov  al, 0x36
        out  0x43, al
        xor  al, al
        out  0x40, al           ; divisor 0 = 65536 -> 18.2 Hz
        out  0x40, al
        xor  ax, ax
        mov  es, ax
        mov  ax, [oldint8]
        mov  [es:0x20], ax
        mov  ax, [oldint8+2]
        mov  [es:0x22], ax
        sti

        mov  ax, 0x0003
        int  0x10
        mov  ax, 0x4C00
        int  0x21

; ---- INT 8 handler: animate a trail + drive the 7-seg, then EOI ----
isr8:
        push ax
        push bx
        push ds
        push es
        push cs
        pop  ds
        inc  word [counter]
        mov  ax, VID
        mov  es, ax
        mov  bx, [counter]
        and  bx, 0x1FFF
        mov  byte [es:bx], 0xFF ; white trail marches across VRAM
        mov  ax, [counter]
        mov  al, ah             ; high byte -> changes a few times/sec
        out  0x80, al           ; 7-seg activity indicator
        mov  al, 0x20
        out  0x20, al           ; EOI to 8259
        pop  es
        pop  ds
        pop  bx
        pop  ax
        iret

counter:  dw 0
oldint8:  dd 0
