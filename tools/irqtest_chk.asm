;==============================================================================
; irqtest_chk.asm -- faithful, LOOPING replica of Ruud's CheckINT0
;
; Ruud programs counter 0 as LSB-only / mode 0 / count 24, unmasks ONLY IRQ0,
; then spins a tight CX=24 loop waiting for its INT 08h handler to set AH. This
; harness does EXACTLY that, but:
;   * loops it forever and tallies OK vs FAIL passes (like Ruud's pass counter),
;   * uses ONE 8259 init -- NO fresh ICW1 per pass -- so any left-behind
;     in-service state accumulates across passes just as it does in Ruud,
;   * shows the 8259 IRR/ISR and stray-vector info live.
;
; Reading the numbers:
;   OK climbing, FAIL 0       -> CheckINT0 itself is fine on a used-but-clean
;                                PIC; Ruud's failure is its OTHER inter-test
;                                activity, not this sequence
;   OK = 1 then FAIL climbing -> fires once, then a stuck in-service bit blocks
;                                every later pass  (ISR will read 01)
;   OK = 0, FAIL climbing     -> never fires, even from a clean init -> a core
;                                timing / handler / tight-loop problem
;   ISR = 01 while failing    -> confirmed: in-service IR0 not being cleared
;   Stray vec nonzero         -> INTA delivered the wrong vector
;
; Build:
;   nasm -f bin irqtest_chk.asm -o irqtest_chk.bin
;   python make64k.py irqtest_chk.bin -o irqtest_chk.64k
;   serve irqtest_chk.64k via floppy_host --bios
;==============================================================================

        BITS 16
        CPU  8086               ; mandatory: see docs/gotchas.md
        ORG 0xE000

VID     equ 0xB800

V_LOOP  equ 0x0500                  ; word: total passes run
V_PASS  equ 0x0502                  ; word: passes where IRQ0 fired
V_FAIL  equ 0x0504                  ; word: passes that timed out
V_SVEC  equ 0x0506                  ; byte: last stray vector
V_SCNT  equ 0x0508                  ; word: stray count

O_LOOP  equ (2*80+12)*2
O_PASS  equ (3*80+12)*2
O_FAIL  equ (4*80+12)*2
O_IRR   equ (5*80+12)*2
O_ISR   equ (6*80+12)*2
O_SVEC  equ (7*80+12)*2
O_SCNT  equ (7*80+24)*2

;------------------------------------------------------------------------------
entry:
        cli
        cld
        xor ax, ax
        mov ds, ax
        mov ss, ax
        mov sp, 0x7C00
        mov es, ax

        mov word [V_LOOP], 0
        mov word [V_PASS], 0
        mov word [V_FAIL], 0
        mov word [V_SVEC], 0
        mov word [V_SCNT], 0

        call setup_ivt
        call cls
        call draw_labels

        ; ---- ONE-TIME 8259 init: edge, single, ICW4, base 0x08, normal EOI ----
        mov al, 0x13
        out 0x20, al                ; ICW1
        mov al, 0x08
        out 0x21, al                ; ICW2  (vector base 0x08)
        mov al, 0x09
        out 0x21, al                ; ICW4  (8086 mode, NON-auto EOI -- XT style)
        mov al, 0xFF
        out 0x21, al                ; OCW1: everything masked for now

;------------------------------------------------------------------------------
; main: each iteration is one pass = Ruud's CheckINT0, verbatim
;------------------------------------------------------------------------------
main:
        cli
        mov ax, 0x00FE
        out 0x21, al                ; IMR = 0xFE: unmask IR0 only.  AH = 0 = flag
        mov al, 0x10
        out 0x43, al                ; counter 0, LSB-only, mode 0, binary
        mov ax, 24
        out 0x40, al                ; count = 24 (single byte)
        mov cx, ax                  ; cx = 24  (the timeout)
        sti
.L10:
        or ah, ah                   ; did the ISR set the flag?
        jne .ok
        loop .L10                   ; spin up to 24 times
        ; ---- timed out: FAILED ----
        cli
        inc word [V_FAIL]
        jmp .after
.ok:
        cli
        inc word [V_PASS]
.after:
        mov al, 0xFF
        out 0x21, al                ; re-mask all between passes

        mov ax, VID
        mov es, ax

        mov al, 0x0A                ; OCW3: read IRR
        out 0x20, al
        in  al, 0x20
        mov di, O_IRR
        call phex8

        mov al, 0x0B                ; OCW3: read ISR
        out 0x20, al
        in  al, 0x20
        mov di, O_ISR
        call phex8

        mov bx, [V_LOOP]
        mov di, O_LOOP
        call phex16
        mov bx, [V_PASS]
        mov di, O_PASS
        call phex16
        mov bx, [V_FAIL]
        mov di, O_FAIL
        call phex16
        mov al, [V_SVEC]
        mov di, O_SVEC
        call phex8
        mov bx, [V_SCNT]
        mov di, O_SCNT
        call phex16

        inc word [V_LOOP]
        mov cx, 0x2000              ; readable pacing
.dly:   loop .dly
        jmp main

;------------------------------------------------------------------------------
; INT 08h handler -- Ruud-style: bump AH (the flag), normal EOI, return.
; AH is modified in the interrupted context and survives IRET, which is exactly
; how CheckINT0's "or ah,ah" sees that an interrupt happened.
;------------------------------------------------------------------------------
irq0:
        inc ah
        push ax
        mov al, 0x20
        out 0x20, al                ; non-specific EOI
        pop ax
        iret

;------------------------------------------------------------------------------
; stray catcher: any vector except 0x08 lands here (records which one)
;   stack at entry: [bp+6]=vector  [bp+8]=IP  [bp+10]=CS  [bp+12]=FLAGS
;------------------------------------------------------------------------------
stray_common:
        push ds
        push bx
        mov bl, al                  ; vector number, passed in AL by the stub
        xor ax, ax
        mov ds, ax
        mov [V_SVEC], bl
        inc word [V_SCNT]
        mov al, 0x20
        out 0x20, al                ; EOI so a mis-vectored IR0 keeps firing
        pop bx
        pop ds
        pop ax                      ; the AX the stub pushed
        iret

;------------------------------------------------------------------------------
setup_ivt:
        push es
        xor ax, ax
        mov es, ax
        xor di, di
        mov cx, 256
        mov bx, stubs
.f:
        mov ax, bx
        stosw
        mov ax, 0xF000
        stosw
        add bx, 6
        loop .f
        mov word [es:8*4],   irq0
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
        mov ax, 0x0720
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
        mov di, (0*80+24)*2
        call puts
        mov si, s_loop
        mov di, (2*80+0)*2
        call puts
        mov si, s_pass
        mov di, (3*80+0)*2
        call puts
        mov si, s_fail
        mov di, (4*80+0)*2
        call puts
        mov si, s_irr
        mov di, (5*80+0)*2
        call puts
        mov si, s_isr
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
        shr al, 1
        shr al, 1
        shr al, 1
        shr al, 1      ; 8086: no shift-by-immediate (see docs/gotchas.md)
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
; 256 per-vector catch stubs (6 bytes each)
;------------------------------------------------------------------------------
stubs:
%assign v 0
%rep 256
        push ax                     ; 8086 has no PUSH imm16, so the stub saves AX
        mov  al, v                  ; and passes the vector in AL instead
        jmp near stray_common       ; still exactly 6 bytes: 50 / B0 xx / E9 xx xx
%assign v v+1
%endrep

;------------------------------------------------------------------------------
s_title db 'RUUD CheckINT0 REPLICA (looping)',0
s_loop  db 'Pass loop :',0
s_pass  db 'IRQ0 OK   :',0
s_fail  db 'IRQ0 FAIL :',0
s_irr   db '8259 IRR  :',0
s_isr   db '8259 ISR  :',0
s_stray db 'Stray vec :',0
s_scnt  db 'cnt:',0
s_l0    db 'Look for:',0
s_l1    db ' OK climbing, FAIL 0   -> CheckINT0 fine; cause is other tests',0
s_l2    db ' OK=1 then FAIL climbs -> in-service bit sticks (ISR=01)',0
s_l3    db ' OK=0, FAIL climbs     -> never fires on a clean PIC',0
s_l4    db ' Stray vec nonzero     -> wrong vector delivered on INTA',0

;------------------------------------------------------------------------------
; reset vector at 0xFFFF0 (offset 0x1FF0 of this 8 KB image)
;------------------------------------------------------------------------------
        times 0x1FF0 - ($ - $$) db 0x90
        jmp 0xF000:entry
        times 0x2000 - ($ - $$) db 0xFF
