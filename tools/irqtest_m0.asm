;==============================================================================
; irqtest_m0.asm  --  MODE 0 IRQ0 diagnostic for gertieboard (Ruud CheckINT0 clone)
;
; Runs as the "BIOS": loads top-aligned into the F-segment, reset vector at
; 0xFFFF0 jumps to entry. No BIOS services are used -- it programs the 8259 and
; 8253 itself and writes the CGA buffer (0xB8000) directly.
;
; It does three things that make the IRQ0 failure self-locating:
;   1. Installs a real INT 08h handler that counts ticks.
;   2. Poisons ALL 256 IVT entries with per-vector catch stubs, so if the INTA
;      cycle delivers the WRONG vector (e.g. open-bus 0xFF fighting the PIC's
;      0x08), the CPU lands in a stub instead of crashing -- and we display
;      exactly which vector was delivered.
;   3. Shows tick count, 8259 IRR/ISR, timer counter 0, and stray-vector info
;      live on screen.
;
; Reading the screen:
;   ticks climbing                 -> IRQ0 works end-to-end (problem is gone)
;   ticks 0, IRR = 01 (stuck)      -> PIC latched IR0 but INT isn't reaching CPU
;   ticks 0, IRR = 00              -> OUT0 not reaching IR0 (timer/wiring)
;   stray vec nonzero, cnt climbing-> INTA delivered the wrong vector (bus fight
;                                     between the PIC vector and the 0xFF
;                                     open-bus terminator) <-- the prime suspect
;   Timer cnt0 changing            -> the counter is clocked and counting
;
; Build:
;   nasm -f bin irqtest.asm -o irqtest.bin
;   python make64k.py irqtest.bin -o irqtest.64k
;   floppy_host.py --port ... --image floppy.img --bios irqtest.64k
;==============================================================================

        BITS 16
        ORG 0xE000                  ; top 8 KB of the F-segment -> 0xFE000

VID     equ 0xB800                  ; CGA text buffer segment

; --- scratch variables in reliable M9K low RAM ---
V_TICK  equ 0x0500                  ; word: IRQ0 tick count
V_SVEC  equ 0x0502                  ; byte: last stray vector seen
V_SCNT  equ 0x0504                  ; word: stray interrupt count
V_HB    equ 0x0506                  ; word: heartbeat (main-loop counter)

; --- screen value positions (row,col) -> byte offset, values start at col 12 ---
O_HB    equ (2*80+12)*2
O_TICK  equ (3*80+12)*2
O_IRR   equ (4*80+12)*2
O_ISR   equ (5*80+12)*2
O_CNT   equ (6*80+12)*2
O_SVEC  equ (7*80+12)*2
O_SCNT  equ (7*80+24)*2

;------------------------------------------------------------------------------
entry:
        cli
        cld
        xor ax, ax
        mov ds, ax                  ; DS = 0  -> IVT + variables
        mov ss, ax
        mov sp, 0x7C00              ; stack in M9K low RAM
        mov es, ax

        mov word [V_TICK], 0
        mov word [V_SVEC], 0
        mov word [V_SCNT], 0
        mov word [V_HB],   0

        call setup_ivt
        call cls
        call draw_labels

        ; ---- program the 8259: edge, single, ICW4; base 0x08; 8086 mode ----
        mov al, 0x13
        out 0x20, al                ; ICW1
        mov al, 0x08
        out 0x21, al                ; ICW2 (vector base)
        mov al, 0x01
        out 0x21, al                ; ICW4 (8086 mode, normal EOI)
        mov al, 0xFE
        out 0x21, al                ; OCW1: unmask IR0 only

        ; ---- program timer counter 0 EXACTLY like Ruud's CheckINT0 ----
        ; control word 0x10 = counter 0, LSB-only, MODE 0, binary
        ; then a single one-byte count = 24
        mov al, 0x10
        out 0x43, al
        mov al, 24
        out 0x40, al                ; one byte, LSB-only -> count = 0x0018

        sti

;------------------------------------------------------------------------------
main:
        mov ax, VID
        mov es, ax

        inc word [V_HB]             ; heartbeat
        mov bx, [V_HB]
        mov di, O_HB
        call phex16

        mov bx, [V_TICK]            ; IRQ0 ticks
        mov di, O_TICK
        call phex16

        mov al, 0x0A                ; read IRR
        out 0x20, al
        in  al, 0x20
        mov di, O_IRR
        call phex8

        mov al, 0x0B                ; read ISR
        out 0x20, al
        in  al, 0x20
        mov di, O_ISR
        call phex8

        xor al, al                  ; latch + read timer counter 0
        out 0x43, al
        in  al, 0x40
        mov bl, al
        in  al, 0x40
        mov bh, al
        mov di, O_CNT
        call phex16

        mov al, [V_SVEC]            ; stray vector + count
        mov di, O_SVEC
        call phex8
        mov bx, [V_SCNT]
        mov di, O_SCNT
        call phex16

        mov cx, 0x1000              ; brief delay so the display is readable
.dly:   loop .dly

        jmp main

;------------------------------------------------------------------------------
; INT 08h (IRQ0) handler: count the tick, send EOI.
;------------------------------------------------------------------------------
irq0:
        push ax
        push ds
        xor ax, ax
        mov ds, ax
        inc word [V_TICK]
        ; Re-arm the mode-0 one-shot, but with count 0 (=65536) NOT 24.
        ; 24 would re-fire every ~19us (~52kHz) and the handler -- running from
        ; slow PSRAM -- would never finish before the next interrupt, live-locking
        ; the CPU in here and freezing the screen. 65536 gives ~19Hz: visibly
        ; climbing, zero risk of a storm. The FIRST fire still used Ruud's exact
        ; count of 24, so a climbing tick proves mode 0 works with his parameters.
        mov al, 0
        out 0x40, al
        mov al, 0x20
        out 0x20, al                ; non-specific EOI
        pop ds
        pop ax
        iret

;------------------------------------------------------------------------------
; Stray catcher: every IVT entry except 0x08 points to a stub that pushes its
; vector number then jumps here. We record the number, EOI (in case it was a
; mis-vectored IR0), and return. Stack at entry:
;   [bp+6]=vector  [bp+8]=IP  [bp+10]=CS  [bp+12]=FLAGS
;------------------------------------------------------------------------------
stray_common:
        push ax
        push ds
        push bp
        mov bp, sp
        xor ax, ax
        mov ds, ax
        mov ax, [bp+6]              ; pushed vector word
        mov [V_SVEC], al
        inc word [V_SCNT]
        mov al, 0x20
        out 0x20, al                ; EOI so a mis-vectored IR0 keeps firing
        pop bp
        pop ds
        pop ax
        add sp, 2                   ; discard pushed vector
        iret

;------------------------------------------------------------------------------
; Fill all 256 IVT entries with stub addresses (seg F000), then override 0x08.
;------------------------------------------------------------------------------
setup_ivt:
        push es
        xor ax, ax
        mov es, ax
        xor di, di
        mov cx, 256
        mov bx, stubs               ; offset of stub 0
.f:
        mov ax, bx
        stosw                       ; IVT[n].offset
        mov ax, 0xF000
        stosw                       ; IVT[n].segment
        add bx, 6                   ; each stub is exactly 6 bytes
        loop .f
        mov word [es:8*4],   irq0   ; override INT 08h
        mov word [es:8*4+2], 0xF000
        pop es
        ret

;------------------------------------------------------------------------------
cls:
        push es
        push di
        push cx
        push ax
        mov ax, VID
        mov es, ax
        xor di, di
        mov ax, 0x0720              ; space, attr grey-on-black
        mov cx, 80*25
        rep stosw
        pop ax
        pop cx
        pop di
        pop es
        ret

;------------------------------------------------------------------------------
draw_labels:
        push es
        mov ax, VID
        mov es, ax
        mov si, s_title
        mov di, (0*80+26)*2
        call puts
        mov si, s_hb
        mov di, (2*80+0)*2
        call puts
        mov si, s_tick
        mov di, (3*80+0)*2
        call puts
        mov si, s_irr
        mov di, (4*80+0)*2
        call puts
        mov si, s_isr
        mov di, (5*80+0)*2
        call puts
        mov si, s_cnt
        mov di, (6*80+0)*2
        call puts
        mov si, s_stray
        mov di, (7*80+0)*2
        call puts
        mov si, s_scnt
        mov di, (7*80+19)*2
        call puts
        mov si, s_l0
        mov di, (9*80+0)*2
        call puts
        mov si, s_l1
        mov di, (10*80+0)*2
        call puts
        mov si, s_l2
        mov di, (11*80+0)*2
        call puts
        mov si, s_l3
        mov di, (12*80+0)*2
        call puts
        mov si, s_l4
        mov di, (13*80+0)*2
        call puts
        pop es
        ret

;------------------------------------------------------------------------------
; puts: CS:SI = ASCIIZ string, ES:DI = screen position
;------------------------------------------------------------------------------
puts:
        push ax
.l:
        cs lodsb
        test al, al
        jz .e
        mov ah, 0x0F
        stosw
        jmp .l
.e:
        pop ax
        ret

;------------------------------------------------------------------------------
; phex8 : AL = byte  -> 2 hex chars at ES:DI (DI advances)
; phex16: BX = word  -> 4 hex chars at ES:DI
;------------------------------------------------------------------------------
phex16:
        mov al, bh
        call phex8
        mov al, bl
        call phex8
        ret

phex8:
        push ax
        push cx
        mov cl, al
        mov al, cl
        shr al, 4
        call .n
        mov al, cl
        call .n
        pop cx
        pop ax
        ret
.n:
        and al, 0x0F
        cmp al, 10
        jb .d
        add al, 'A'-10
        jmp .p
.d:
        add al, '0'
.p:
        mov ah, 0x0F
        stosw
        ret

;------------------------------------------------------------------------------
; 256 per-vector catch stubs (6 bytes each: push word n ; jmp near common)
;------------------------------------------------------------------------------
stubs:
%assign v 0
%rep 256
        push strict word v
        jmp near stray_common
%assign v v+1
%endrep

;------------------------------------------------------------------------------
s_title db 'IRQ0 / TIMER INTERRUPT TEST',0
s_hb    db 'Heartbeat :',0
s_tick  db 'IRQ0 ticks:',0
s_irr   db '8259 IRR  :',0
s_isr   db '8259 ISR  :',0
s_cnt   db 'Timer cnt0:',0
s_stray db 'Stray vec :',0
s_scnt  db 'cnt:',0
s_l0    db 'Look for:',0
s_l1    db ' ticks climbing        -> IRQ0 works end to end',0
s_l2    db ' ticks 0, IRR=01 stuck -> INT not reaching CPU',0
s_l3    db ' ticks 0, IRR=00       -> OUT0 not reaching IR0',0
s_l4    db ' stray vec nonzero     -> wrong vector on INTA (bus fight)',0

;------------------------------------------------------------------------------
; reset vector at 0xFFFF0 (offset 0x1FF0 of this 8 KB image)
;------------------------------------------------------------------------------
        times 0x1FF0 - ($ - $$) db 0x90
        jmp 0xF000:entry
        times 0x2000 - ($ - $$) db 0xFF
