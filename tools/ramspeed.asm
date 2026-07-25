; ============================================================================
;  ramspeed.asm  --  measure PSRAM vs on-chip M9K read latency (DOS .COM)
;
;  mem_hybrid splits the memory map:
;     0x00000-0x07FFF  m9k_mem   on-chip M9K, ready in ~60 ns
;     0x08000-0x9FFFF  psram_ctrl QPI PSRAM, 16+RD_LAT SCK cycles per byte
;  DOS loads programs above 0x08000, so game code runs from the slow half.
;
;  METHOD: time an identical "rep lodsb" sweep over 32 KB, once with DS in low
;  RAM (M9K) and once with DS in PSRAM. Instruction fetch and loop overhead are
;  identical in both passes, so the DIFFERENCE isolates the per-byte memory
;  penalty. Timing comes from the BIOS tick count at 0040:006C (54.925 ms).
;
;  Then it re-runs the PSRAM pass for several CTRL (I/O 0xE4) settings and
;  integrity-checks 4 KB of PSRAM at each, to find the fastest reliable timing:
;     CTRL(2:0) = SCK_DIV  (SCK half-period in 50 MHz clocks; 1 = 25 MHz SCK)
;     CTRL(6:3) = RD_LAT   (extra read-capture latency)
;
;  !! WARNING !! This program itself executes from PSRAM, so a CTRL value that
;  breaks reads will hang or crash the machine mid-sweep. That is still a useful
;  result: the last value PRINTED before the hang is the one that failed. Just
;  reset and report what you saw. The good settings all print a PASS line.
;
;  Build:  nasm -f bin ramspeed.asm -o ramspeed.com
; ============================================================================

        org  0x100
        bits 16

TICKLO  equ 0x6C                ; BDA offset of the low tick word
REPS    equ 24                  ; 32 KB sweeps per measurement
TESTSEG equ 0x8000              ; PSRAM integrity-test area (linear 0x80000)
CTRLPORT equ 0xE4

start:
        mov  dx, msg_hdr
        call puts

        ; ---------- baseline: M9K (low RAM) ----------
        mov  ax, 0x0000
        call measure
        mov  [t_m9k], ax
        mov  dx, msg_m9k
        call puts
        mov  ax, [t_m9k]
        call putdec
        call crlf

        ; ---------- baseline: PSRAM at current CTRL ----------
        mov  ax, 0x2000
        call measure
        mov  [t_ps], ax
        mov  dx, msg_ps
        call puts
        mov  ax, [t_ps]
        call putdec
        call crlf

        ; ---------- per-byte penalty in ns ----------
        ; ns = (t_ps - t_m9k) * 54925 us / (REPS*32767) , computed as
        ;      delta * 54925000 ns / 786408  ~=  delta * 69.8 ns
        mov  dx, msg_pen
        call puts
        mov  ax, [t_ps]
        sub  ax, [t_m9k]
        mov  bx, 70                  ; ~69.8 ns per tick of difference
        mul  bx                      ; DX:AX
        call putdec                   ; AX only (values stay < 65536)
        mov  dx, msg_nsb
        call puts

        ; ---------- sweep candidate CTRL values ----------
        mov  dx, msg_sweep
        call puts
        mov  si, ctrl_tab
.sw_loop:
        mov  al, [si]
        cmp  al, 0xFF
        je   .sw_done
        mov  [cur_ctrl], al

        mov  dx, msg_try             ; announce BEFORE applying, so a hang
        call puts                    ; still tells us which value died
        mov  al, [cur_ctrl]
        call puthex
        mov  dx, msg_arrow
        call puts

        mov  al, [cur_ctrl]
        out  CTRLPORT, al            ; <-- retimes PSRAM live
        jmp  short $+2               ; small settle

        call integrity               ; AL = 1 pass, 0 fail
        test al, al
        jz   .sw_fail
        mov  dx, msg_pass
        call puts
        mov  ax, 0x2000
        call measure
        call putdec
        mov  dx, msg_ticks
        call puts
        jmp  short .sw_next
.sw_fail:
        mov  dx, msg_fail
        call puts
.sw_next:
        inc  si
        jmp  .sw_loop
.sw_done:
        ; restore the known-good default
        mov  al, 0x02
        out  CTRLPORT, al
        mov  dx, msg_rest
        call puts
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; measure: AX = segment to sweep -> AX = elapsed BIOS ticks
;   ES stays on the BDA; DS is the segment under test, so all locals are
;   unreachable during the loop -> everything is kept in registers.
; ---------------------------------------------------------------------------
measure:
        push ds
        push es
        push bx
        push cx
        push si
        push bp
        mov  dx, ax                  ; DX = segment under test
        mov  ax, 0x0040
        mov  es, ax
        mov  bp, REPS
        mov  ax, [es:TICKLO]
.align:                              ; start on a fresh tick edge
        cmp  ax, [es:TICKLO]
        je   .align
        mov  di, [es:TICKLO]
        cld
.rep_loop:
        mov  ds, dx
        xor  si, si
        mov  cx, 0x7FFF              ; 32767 bytes
        rep  lodsb
        dec  bp
        jnz  .rep_loop
        mov  ax, [es:TICKLO]
        sub  ax, di
        pop  bp
        pop  si
        pop  cx
        pop  bx
        pop  es
        pop  ds
        ret

; ---------------------------------------------------------------------------
; integrity: write/verify 4 KB of PSRAM at TESTSEG -> AL = 1 pass / 0 fail
;   Uses a shifting pattern so a stuck or mis-latched nibble shows up.
; ---------------------------------------------------------------------------
integrity:
        push bx
        push cx
        push dx
        push di
        push es
        mov  ax, TESTSEG
        mov  es, ax
        cld
        xor  di, di
        mov  cx, 0x1000
        mov  bl, 0x5A
.wr:    mov  al, bl
        stosb
        add  bl, 0x25                ; walk through many bit patterns
        loop .wr

        xor  di, di
        mov  cx, 0x1000
        mov  bl, 0x5A
        mov  dl, 1                   ; assume pass
.rd:    mov  al, [es:di]
        cmp  al, bl
        je   .ok
        xor  dl, dl
.ok:    inc  di
        add  bl, 0x25
        loop .rd
        mov  al, dl
        pop  es
        pop  di
        pop  dx
        pop  cx
        pop  bx
        ret

; ---------------------------------------------------------------------------
; small output helpers
; ---------------------------------------------------------------------------
puts:                                ; DS:DX = '$'-terminated string
        push ax
        mov  ah, 0x09
        int  0x21
        pop  ax
        ret

crlf:
        push dx
        mov  dx, msg_crlf
        call puts
        pop  dx
        ret

putdec:                              ; AX unsigned -> decimal
        push ax
        push bx
        push cx
        push dx
        xor  cx, cx
        mov  bx, 10
.dv:    xor  dx, dx
        div  bx
        push dx
        inc  cx
        test ax, ax
        jnz  .dv
.pr:    pop  dx
        add  dl, '0'
        mov  ah, 0x02
        int  0x21
        loop .pr
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

puthex:                              ; AL -> two hex digits
        push ax
        push cx
        mov  cl, al
        shr  al, 4
        call .nib
        mov  al, cl
        and  al, 0x0F
        call .nib
        pop  cx
        pop  ax
        ret
.nib:   cmp  al, 10
        jb   .dig
        add  al, 'A'-10
        jmp  short .out
.dig:   add  al, '0'
.out:   mov  dl, al
        mov  ah, 0x02
        int  0x21
        ret

; ---------------------------------------------------------------------------
cur_ctrl: db 0
t_m9k:    dw 0
t_ps:     dw 0

; SCK_DIV in bits 2:0, RD_LAT in bits 6:3.  0x02 = the default.
;
; Only RD_LAT=0 is usable on this board: RD_LAT aligns the read-capture window,
; so any non-zero value scrambles every byte and freezes the machine instantly.
; The old table swept 0x09/0x11/0x0A (RD_LAT 1/2/1) and always died on the first
; of them, which told us nothing we did not already know -- so it now sweeps only
; the SCK_DIV values, which is the parameter actually worth measuring.
ctrl_tab: db 0x02, 0x01, 0xFF

msg_hdr:   db 'gertieboard RAM speed test',13,10
           db '32KB rep-lodsb sweeps, x24, timed on BIOS ticks',13,10,13,10,'$'
msg_m9k:   db 'M9K   (0000:0000, on-chip) ticks = $'
msg_ps:    db 'PSRAM (2000:0000)          ticks = $'
msg_pen:   db 'extra per-byte cost        ~ $'
msg_nsb:   db ' ns',13,10,13,10,'$'
msg_sweep: db 'CTRL sweep (DIV=bits2:0, LAT=bits6:3):',13,10,'$'
msg_try:   db '  CTRL 0x$'
msg_arrow: db ' -> $'
msg_pass:  db 'PASS  ticks=$'
msg_fail:  db 'FAIL (data mismatch)',13,10,'$'
msg_ticks: db 13,10,'$'
msg_rest:  db 13,10,'CTRL restored to 0x02.',13,10,'$'
msg_crlf:  db 13,10,'$'
