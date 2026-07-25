; ============================================================================
;  memtest.asm  --  memory integrity / stability test (DOS .COM)
;
;  Written because a BIOS routine stopped completing even though its machine code
;  disassembles correctly, which means instruction fetch returned something other
;  than what is in memory. The BIOS lives at 0xF0000, i.e. in PSRAM behind the
;  4-line/16-byte read cache, so the cache is the prime suspect.
;
;  Tests, in increasing specificity:
;
;   1 PATTERN     each word in 0x20000..0x7FFFF gets a unique value derived from
;                 its address, then all of it is verified. Catches plain bit
;                 errors and address aliasing (two addresses mapping to one cell).
;
;   2 CACHE THRASH  8 addresses spaced 16 bytes apart = 8 distinct cache lines,
;                 against a cache that only holds 4. Written, verified, rewritten
;                 inverted and verified again. A broken eviction or a missing
;                 write-invalidate shows up here and almost nowhere else.
;
;   3 LINE STRADDLE  16-bit accesses placed deliberately across 16-byte line
;                 boundaries, so one operand spans two cache lines.
;
;   4 ROM STABILITY  checksums the whole 64 KB F-segment eight times over. The
;                 BIOS is read-only at runtime, so every checksum MUST be
;                 identical -- if they differ, code fetch itself is unreliable
;                 and that alone explains a routine that never finishes.
;
;  Build:  nasm -f bin memtest.asm -o memtest.com
; ============================================================================

        org  0x100
        bits 16

SEG_LO  equ 0x2000              ; 128 KB -- above DOS and this program
SEG_HI  equ 0x7000              ; 448 KB -- below the COMMAND.COM transient
ROMSEG  equ 0xF000
PASSES  equ 8

start:
        mov  dx, msg_hdr
        call puts

; ---------------------------------------------------------------- 1: pattern
        mov  dx, msg_t1
        call puts
        mov  bp, SEG_LO
.p_fill:
        mov  es, bp
        xor  di, di
.pf_l:
        mov  ax, bp
        xor  ax, di                     ; unique per linear address
        mov  [es:di], ax
        add  di, 2
        jnz  .pf_l                      ; wraps to 0 after 0xFFFE
        add  bp, 0x1000
        cmp  bp, SEG_HI
        jbe  .p_fill

        mov  bp, SEG_LO
.p_chk:
        mov  es, bp
        xor  di, di
.pc_l:
        mov  ax, bp
        xor  ax, di
        cmp  ax, [es:di]
        jne  .p_bad
        add  di, 2
        jnz  .pc_l
        add  bp, 0x1000
        cmp  bp, SEG_HI
        jbe  .p_chk
        call pass
        jmp  short .t2
.p_bad:
        call fail
        mov  dx, msg_at
        call puts
        mov  ax, bp
        call puthex16
        mov  dx, msg_colon
        call puts
        mov  ax, di
        call puthex16
        call crlf

; ------------------------------------------------------- 2: cache thrashing
.t2:
        mov  dx, msg_t2
        call puts
        mov  ax, SEG_LO
        mov  es, ax
        ; write 8 lines
        xor  bx, bx                     ; line index
.c_wr:
        mov  di, bx
        mov  cl, 4
        shl  di, cl                     ; di = bx * 16
        mov  ax, bx
        add  ax, 0x1100
        mov  [es:di], ax
        inc  bx
        cmp  bx, 8
        jb   .c_wr
        ; verify them (forces evictions in a 4-line cache)
        xor  bx, bx
.c_rd:
        mov  di, bx
        mov  cl, 4
        shl  di, cl
        mov  ax, bx
        add  ax, 0x1100
        cmp  ax, [es:di]
        jne  .c_bad
        inc  bx
        cmp  bx, 8
        jb   .c_rd
        ; rewrite inverted -- tests write-invalidate of already-cached lines
        xor  bx, bx
.c_wr2:
        mov  di, bx
        mov  cl, 4
        shl  di, cl
        mov  ax, bx
        add  ax, 0x1100
        not  ax
        mov  [es:di], ax
        inc  bx
        cmp  bx, 8
        jb   .c_wr2
        xor  bx, bx
.c_rd2:
        mov  di, bx
        mov  cl, 4
        shl  di, cl
        mov  ax, bx
        add  ax, 0x1100
        not  ax
        cmp  ax, [es:di]
        jne  .c_bad
        inc  bx
        cmp  bx, 8
        jb   .c_rd2
        call pass
        jmp  short .t3
.c_bad:
        call fail

; ------------------------------------------------- 3: straddling line edges
.t3:
        mov  dx, msg_t3
        call puts
        mov  ax, SEG_LO
        mov  es, ax
        mov  di, 0x200
        mov  bx, 0
.s_l:
        mov  di, bx
        add  di, 0x20F                  ; 0x20F, 0x21F, ... = last byte of a line
        mov  ax, bx
        add  ax, 0x5A00
        mov  [es:di], ax                ; word spans two cache lines
        add  bx, 16
        cmp  bx, 128
        jb   .s_l
        mov  bx, 0
.s_c:
        mov  di, bx
        add  di, 0x20F
        mov  ax, bx
        add  ax, 0x5A00
        cmp  ax, [es:di]
        jne  .s_bad
        add  bx, 16
        cmp  bx, 128
        jb   .s_c
        call pass
        jmp  short .t4
.s_bad:
        call fail

; ------------------------------------------------------ 4: ROM/BIOS stability
.t4:
        mov  dx, msg_t4
        call puts
        mov  cx, PASSES
        xor  bp, bp                     ; bp = reference checksum (pass 1)
.r_pass:
        push cx
        call rom_sum                    ; -> AX
        pop  cx
        cmp  cx, PASSES
        jne  .r_cmp
        mov  bp, ax                     ; first pass sets the reference
        jmp  short .r_next
.r_cmp:
        cmp  ax, bp
        jne  .r_bad
.r_next:
        loop .r_pass
        call pass
        mov  dx, msg_sum
        call puts
        mov  ax, bp
        call puthex16
        call crlf
        jmp  short .fin
.r_bad:
        call fail
        mov  dx, msg_sumdiff
        call puts
        mov  ax, bp
        call puthex16
        mov  dx, msg_vs
        call puts
        call crlf

.fin:
        mov  dx, msg_done
        call puts
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; rom_sum: 16-bit sum of the whole F-segment -> AX
rom_sum:
        push bx
        push cx
        push si
        push ds
        mov  ax, ROMSEG
        mov  ds, ax
        xor  bx, bx                     ; running sum
        xor  si, si
        mov  cx, 0x8000                 ; 32768 words = 64 KB
.rs_l:
        mov  ax, [si]
        add  bx, ax
        add  si, 2
        loop .rs_l
        mov  ax, bx
        pop  ds
        pop  si
        pop  cx
        pop  bx
        ret

pass:   push dx
        mov  dx, msg_pass
        call puts
        pop  dx
        ret
fail:   push dx
        mov  dx, msg_fail
        call puts
        pop  dx
        ret
crlf:   push dx
        mov  dx, msg_crlf
        call puts
        pop  dx
        ret
puts:   push ax
        mov  ah, 0x09
        int  0x21
        pop  ax
        ret

puthex16:                                ; AX -> 4 hex digits
        push ax
        push cx
        mov  cx, ax
        mov  al, ch
        call puthex8
        mov  al, cl
        call puthex8
        pop  cx
        pop  ax
        ret
puthex8:                                 ; the shift count must live in CL, and
        push ax                          ; .nib clobbers AH, so stash the byte in
        push bx                          ; BL rather than AH
        push cx
        mov  bl, al
        mov  cl, 4
        shr  al, cl
        call .nib
        mov  al, bl
        and  al, 0x0F
        call .nib
        pop  cx
        pop  bx
        pop  ax
        ret
.nib:   cmp  al, 10
        jb   .d
        add  al, 'A'-10
        jmp  short .o
.d:     add  al, '0'
.o:     push dx
        mov  dl, al
        mov  ah, 0x02
        int  0x21
        pop  dx
        ret

msg_hdr:     db 'gertieboard memory test',13,10
             db 'PSRAM 0x20000-0x7FFFF, cache behaviour, and BIOS stability',13,10,13,10,'$'
msg_t1:      db '1 unique pattern over 384 KB   : $'
msg_t2:      db '2 cache thrash (8 lines of 4)  : $'
msg_t3:      db '3 words across line boundaries : $'
msg_t4:      db '4 BIOS checksum stable x8      : $'
msg_at:      db '   first bad at $'
msg_colon:   db ':$'
msg_sum:     db '   F-seg checksum = $'
msg_sumdiff: db '   checksum CHANGED between passes, ref = $'
msg_vs:      db '  <-- code fetch is unreliable$'
msg_pass:    db 'PASS',13,10,'$'
msg_fail:    db 'FAIL',13,10,'$'
msg_done:    db 'done.',13,10,'$'
msg_crlf:    db 13,10,'$'
