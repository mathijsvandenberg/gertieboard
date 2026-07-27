; ============================================================================
;  spidump.asm  --  read the BIOS image out of the SPI flash the way the BOOT
;                   ROM does, and compare it with the BIOS in memory
;
;  Three things can hold the BIOS: the running image in the F-segment, the copy
;  in flash, and whatever the boot ROM ends up putting in memory. BIOSFLASH
;  proves the first two agree, because it writes and reads back through the
;  BIOS's INT 13h path. The boot ROM does NOT use that path -- it drives the SPI
;  byte engine at ports 98/99/9A directly -- and that read has never once been
;  checked against a known-good image. This checks it, from DOS, where the
;  answer can be printed instead of guessed at.
;
;  It reproduces the loader's spi_x byte-exchange exactly, including the two
;  filler instructions between the write and the status read. flash.vhd latches
;  the transmit on the FALLING edge of the write strobe and only then raises
;  BUSY, so a status read issued too early sees BUSY=0 and hands back the
;  PREVIOUS byte -- which shifts the whole image by one and produces a BIOS
;  that is readable in places and broken everywhere else.
;
;  So it does not just count differences: it counts them at three alignments.
;
;      aligned   flash[i] == bios[i]      the image is correct
;      lag 1     flash[i] == bios[i-1]    every byte arrives one too late
;      lead 1    flash[i] == bios[i+1]    every byte arrives one too early
;
;  Near-zero mismatches at "lag 1" is the race, proven rather than suspected.
;  Near-zero at "aligned" means this read path is sound and the corruption is
;  somewhere else entirely.
;
;      spidump          compare, and report checksums and alignment
;      spidump d        also hex-dump the 128 bytes at image offset C000,
;                       which is where the BIOS code starts
;      spidump n        no gap after the write -- should FAIL, and failing
;                       proves the gap is what matters
;      spidump s        a long gap -- if this passes where the loader's gap
;                       fails, the gap is simply too short
;
;  Build:  nasm -f bin spidump.asm -o spidump.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

SPI_DATA equ 0x98               ; flash.vhd byte engine: write starts a transfer
SPI_STAT equ 0x99               ; bit 7 = BUSY
SPI_CTRL equ 0x9A               ; bit 0 = /CS
BIOS_OFF equ 0x1F               ; flash 0x1F0000 = the reserved top 64 KB
ROMSEG   equ 0xF000
CODE_LO  equ 0xC000             ; the BIOS code region inside the image
CODE_HI  equ 0xF000
CAPOFF   equ 0xC000             ; offset whose bytes we keep for the dump
CAPLEN   equ 128

start:
        mov  dx, msg_hdr
        call puts

        ; ---- which byte-exchange routine? ----
        mov  word [spifn], spi_ldr
        mov  dx, msg_m_ldr
        mov  al, [0x80]                 ; PSP command tail length
        test al, al
        jz   .modeset
        mov  cl, al
        mov  ch, 0
        mov  si, 0x81
.scan:  lodsb
        cmp  al, ' '
        je   .next
        and  al, 0xDF
        cmp  al, 'N'
        jne  .chk_s
        mov  word [spifn], spi_fast
        mov  dx, msg_m_none
        jmp  short .next
.chk_s: cmp  al, 'S'
        jne  .chk_c
        mov  word [spifn], spi_slow
        mov  dx, msg_m_slow
        jmp  short .next
.chk_c: cmp  al, 'C'
        jne  .chk_d
        mov  byte [chunked], 1
        jmp  short .next
.chk_d: cmp  al, 'D'
        jne  .next
        mov  byte [dumpit], 1
.next:  loop .scan
.modeset:
        call puts
        mov  dx, msg_stream
        cmp  byte [chunked], 0
        je   .say
        mov  dx, msg_chunk
.say:   call puts
        mov  dx, msg_src
        call puts

        ; ---- stream the image, comparing as it arrives ----
        mov  ax, ROMSEG
        mov  es, ax
        xor  di, di                     ; DI counts as well as addresses: it
                                        ; wraps to 0 after exactly 65536 bytes
        call spi_open                   ; opens at DI, which is 0 here
.rl:
        ; Chunked mode starts a fresh command at every 512-byte boundary --
        ; the way the BIOS reads one sector. The boot ROM instead holds /CS
        ; low for a single unbroken 64 KB burst, and that is the one real
        ; difference between the reader that works and the reader that does
        ; not. If chunked reads clean and streaming does not, the burst is
        ; the bug and the boot ROM should read in pieces.
        cmp  byte [chunked], 0
        je   .nore
        test di, di
        jz   .nore                      ; already opened, above
        mov  ax, di
        and  ax, 0x01FF
        jnz  .nore
        call spi_close
        call spi_open
.nore:
        call [spifn]                    ; AL = the next flash byte
        mov  bl, al                     ; keep it: AL is needed for compares
        mov  bh, 0

        ; running checksums, 16-bit, same arithmetic as the boot ROM's
        add  [sum_all], bx
        cmp  di, CODE_LO
        jb   .nocode
        cmp  di, CODE_HI
        jae  .nocode
        add  [sum_code], bx
.nocode:

        ; keep a window of bytes for the optional hex dump
        cmp  di, CAPOFF
        jb   .nocap
        cmp  di, CAPOFF + CAPLEN
        jae  .nocap
        mov  si, di
        sub  si, CAPOFF
        mov  [cap+si], bl
.nocap:

        ; ---- alignment 0: flash[i] vs bios[i] ----
        mov  ah, [es:di]                ; bios[i]
        cmp  bl, ah
        je   .a_ok
        inc  word [mm_al]
        jnz  .a_sat
        dec  word [mm_al]               ; saturate instead of wrapping
.a_sat:
        cmp  byte [havefirst], 0
        jne  .a_ok
        mov  byte [havefirst], 1
        mov  [first_off], di
        mov  [first_fl], bl
        mov  [first_bi], ah
.a_ok:

        ; ---- alignment -1: flash[i] vs bios[i-1] ----
        ; The first byte has no predecessor, so it is simply not counted.
        test di, di
        jz   .l_skip
        mov  al, [prevbios]
        cmp  bl, al
        je   .l_skip
        inc  word [mm_lag]
        jnz  .l_skip
        dec  word [mm_lag]
.l_skip:

        ; ---- alignment +1: flash[i] vs bios[i+1] ----
        mov  si, di
        inc  si
        mov  al, [es:si]
        cmp  bl, al
        je   .d_skip
        inc  word [mm_lead]
        jnz  .d_skip
        dec  word [mm_lead]
.d_skip:

        mov  [prevbios], ah             ; bios[i] becomes bios[i-1]
        inc  di
        jz   .rdone                     ; LOOP cannot reach back this far, and
        jmp  .rl                        ; a backward conditional cannot either
.rdone:

        call spi_close

        ; ---- results ----
        mov  dx, msg_sum
        call puts
        mov  ax, [sum_code]
        call puthexw
        mov  dx, msg_sum2
        call puts
        mov  ax, [sum_all]
        call puthexw
        mov  dx, msg_crlf
        call puts

        mov  dx, msg_mm
        call puts
        mov  ax, [mm_al]
        call putdec5
        mov  dx, msg_mm2
        call puts
        mov  ax, [mm_lag]
        call putdec5
        mov  dx, msg_mm3
        call puts
        mov  ax, [mm_lead]
        call putdec5
        mov  dx, msg_crlf
        call puts

        cmp  byte [havefirst], 0
        je   .nofirst
        mov  dx, msg_first
        call puts
        mov  ax, [first_off]
        call puthexw
        mov  dx, msg_first2
        call puts
        mov  al, [first_fl]
        call puthex
        mov  dx, msg_first3
        call puts
        mov  al, [first_bi]
        call puthex
        mov  dx, msg_crlf
        call puts
.nofirst:

        ; ---- verdict ----
        mov  dx, msg_crlf
        call puts
        cmp  word [mm_al], 0
        jne  .not_clean
        mov  dx, msg_v_ok
        call puts
        jmp  .dump
.not_clean:
        ; a near-zero count at a shifted alignment is the race, not damage
        mov  ax, [mm_lag]
        cmp  ax, 64
        ja   .chk_lead
        mov  dx, msg_v_lag
        call puts
        jmp  .dump
.chk_lead:
        mov  ax, [mm_lead]
        cmp  ax, 64
        ja   .v_other
        mov  dx, msg_v_lead
        call puts
        jmp  .dump
.v_other:
        mov  dx, msg_v_diff
        call puts

.dump:
        cmp  byte [dumpit], 0
        je   .fin
        mov  dx, msg_dump
        call puts
        xor  si, si
.dl:
        mov  ax, si
        add  ax, CAPOFF
        call puthexw
        mov  dx, msg_colon
        call puts
        mov  cx, 16
        push si
.dh:    mov  al, [cap+si]
        call puthex
        mov  dl, ' '
        mov  ah, 2
        int  0x21
        inc  si
        loop .dh
        pop  si
        mov  dx, msg_bar
        call puts
        mov  cx, 16
.da:    mov  al, [cap+si]
        cmp  al, 0x20
        jb   .dot
        cmp  al, 0x7F
        jb   .prn
.dot:   mov  al, '.'
.prn:   mov  dl, al
        mov  ah, 2
        int  0x21
        inc  si
        loop .da
        mov  dx, msg_crlf
        call puts
        cmp  si, CAPLEN
        jb   .dl
.fin:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; spi_open -- assert /CS and send READ (0x03) plus the 24-bit address, exactly
;             as the boot ROM's flash_load does.
spi_open:                               ; opens a READ at 0x1F0000 + DI
        push ax
        xor  al, al
        out  SPI_CTRL, al               ; /CS low
        mov  al, 0x03                   ; READ
        call [spifn]
        mov  al, BIOS_OFF               ; addr[23:16]
        call [spifn]
        mov  ax, di
        mov  al, ah                     ; addr[15:8] = DI >> 8
        call [spifn]
        xor  al, al                     ; addr[7:0]: always on a 512 boundary
        call [spifn]
        pop  ax
        ret

spi_close:
        push ax
        mov  al, 1
        out  SPI_CTRL, al               ; /CS high
        pop  ax
        ret

; ---------------------------------------------------------------------------
; The three byte-exchange variants. Each takes AL out, returns AL in, and
; preserves everything else -- the compare loop keeps its state in BX, CX, DI.

; Exactly the boot ROM's spi_x: two filler instructions before the status read.
spi_ldr:
        out  SPI_DATA, al
        jmp  short $+2
        jmp  short $+2
.w:     in   al, SPI_STAT
        test al, 0x80
        jnz  .w
        in   al, SPI_DATA
        ret

; No gap at all. This is what the loader looked like before the race was
; found; it should fail, and its failing is the control for the experiment.
spi_fast:
        out  SPI_DATA, al
.w:     in   al, SPI_STAT
        test al, 0x80
        jnz  .w
        in   al, SPI_DATA
        ret

; A generous gap. If this succeeds where spi_ldr fails, the loader's gap is
; real but too short, and the fix is in flash.vhd's BUSY timing rather than in
; adding yet more filler.
spi_slow:
        out  SPI_DATA, al
        jmp  short $+2
        jmp  short $+2
        jmp  short $+2
        jmp  short $+2
        jmp  short $+2
        jmp  short $+2
        jmp  short $+2
        jmp  short $+2
.w:     in   al, SPI_STAT
        test al, 0x80
        jnz  .w
        in   al, SPI_DATA
        ret

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthexw:
        push ax
        push ax
        mov  al, ah
        call puthex
        pop  ax
        call puthex
        pop  ax
        ret

puthex: push ax
        push bx
        push cx
        push dx
        mov  bl, al
        mov  cl, 4
        shr  al, cl
        call .nib
        mov  al, bl
        and  al, 0x0F
        call .nib
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret
.nib:   and  al, 0x0F
        cmp  al, 10
        jb   .n0
        add  al, 'A'-10
        jmp  short .n1
.n0:    add  al, '0'
.n1:    mov  dl, al
        mov  ah, 2
        int  0x21
        ret

putdec5:                        ; AX right-aligned in five columns
        push ax
        push bx
        push cx
        push dx
        push si
        mov  si, ax             ; DOS output needs AH and returns AL, so the
        mov  cx, 0              ; value cannot live in AX across the padding
        mov  bx, 10
.count: xor  dx, dx
        div  bx
        inc  cx
        test ax, ax
        jnz  .count
        mov  bx, 5
        sub  bx, cx
        jbe  .num
        mov  cx, bx
.pad:   push cx
        mov  dl, ' '
        mov  ah, 2
        int  0x21
        pop  cx
        loop .pad
.num:   mov  ax, si
        call putdec
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

putdec: push ax
        push bx
        push cx
        push dx
        xor  cx, cx
        mov  bx, 10
.d1:    xor  dx, dx
        div  bx
        push dx
        inc  cx
        test ax, ax
        jnz  .d1
.d2:    pop  ax
        add  al, '0'
        mov  dl, al
        mov  ah, 2
        int  0x21
        loop .d2
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
msg_hdr   db 'SPIDUMP - read the BIOS from SPI flash the way the boot ROM does',13,10
          db '---------------------------------------------------------------',13,10,'$'
msg_m_ldr  db 'gap      : two instructions after each write (as the boot ROM)',13,10,'$'
msg_m_none db 'gap      : NONE - this is the control, it is expected to fail',13,10,'$'
msg_m_slow db 'gap      : eight instructions - deliberately generous',13,10,'$'
msg_stream db 'reads    : ONE continuous burst, /CS held low (as the boot ROM)',13,10,'$'
msg_chunk  db 'reads    : a fresh command every 512 bytes (as the BIOS does)',13,10,'$'
msg_src   db 'source   : flash 0x1F0000, 65536 bytes, vs the BIOS at F000:0000',13,10,13,10,'$'
msg_sum   db 'checksum : code C000-EFFF = $'
msg_sum2  db '   full 64 KB = $'
msg_mm    db 'mismatch : aligned $'
msg_mm2   db '   lag 1 $'
msg_mm3   db '   lead 1 $'
msg_first db 'first    : offset $'
msg_first2 db '  flash $'
msg_first3 db '  BIOS $'
msg_v_ok  db 'The flash image is IDENTICAL to the running BIOS, read through the',13,10
          db 'boot ROM method. This read path is sound.',13,10,'$'
msg_v_lag db 'Almost every byte matches the PREVIOUS one: the read lags by one.',13,10
          db 'The status read is overtaking the write, so BUSY is sampled before',13,10
          db 'flash.vhd raises it and the engine hands back the previous byte.',13,10,'$'
msg_v_lead db 'Almost every byte matches the NEXT one: the stream leads by one,',13,10
          db 'so a byte is being consumed that should not have been.',13,10,'$'
msg_v_diff db 'The flash image genuinely differs, and not by a simple shift.',13,10,'$'
msg_dump  db 13,10,'image offset C000 (start of the BIOS code):',13,10,'$'
msg_colon db ' : $'
msg_bar   db '| $'
msg_crlf  db 13,10,'$'

spifn      dw 0
dumpit     db 0
chunked    db 0
havefirst  db 0
prevbios   db 0
first_off  dw 0
first_fl   db 0
first_bi   db 0
sum_all    dw 0
sum_code   dw 0
mm_al      dw 0
mm_lag     dw 0
mm_lead    dw 0
cap        times CAPLEN db 0
