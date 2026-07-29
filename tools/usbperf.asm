; ============================================================================
;  usbperf.asm  --  USB hard disk READ benchmark, with a regression check
;
;  Built to answer one question repeatably: did an optimisation actually make
;  reads faster, and did it break anything doing so. Run it before a change,
;  run it after, compare the two.
;
;  READ-ONLY, and deliberately so. There is an operating system installed on
;  C: now, so a benchmark that writes would destroy the thing being measured.
;  USBSOAK is the one that writes; this one never issues AH=03.
;
;  It reports three things:
;
;    integrity   A checksum of a fixed region, read the same way every time.
;                This is the regression check: the number must not change
;                across runs, across builds, or across optimisations. A faster
;                driver that returns different bytes is not a faster driver.
;
;    throughput  KB/s at five transfer sizes. Every phase moves the SAME
;                number of sectors, so the columns are directly comparable --
;                a change that helps large transfers and hurts small ones
;                shows up as two numbers moving in opposite directions rather
;                than as one average that hides it.
;
;    cost        Controller transactions and NAKs over the whole run. Bytes
;                per transaction should not move when only the CPU-side copy
;                is optimised; if it does, something changed on the wire that
;                was not meant to.
;
;  Timing is the 18.2 Hz BIOS tick, so each phase is sized to run for a couple
;  of seconds. At the current ~85 KB/s that is comfortable; if a change makes
;  reads several times faster the phases get short, so pass a multiplier.
;
;      usbperf            512 sectors per phase (256 KB)
;      usbperf 4          four times that, for finer resolution on a fast build
;
;  Build:  nasm -f bin usbperf.asm -o usbperf.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

HDD      equ 0x80               ; drive C:
U_DIAG   equ 0xEF               ; controller diagnostic window
BASESEC  equ 512                ; sectors per phase, before the multiplier
CHKSEC   equ 64                 ; sectors covered by the integrity checksum
NPHASE   equ 5

start:
        mov  dx, msg_hdr
        call puts

        ; ---- is there a disk, and what shape is it? ----
        mov  ax, 0x40
        mov  es, ax
        cmp  byte [es:0xC1], 0
        jne  .have
        mov  dx, msg_nodisk
        call puts
        jmp  bye
.have:
        mov  al, [es:0xCE]
        mov  ah, 0
        mov  [heads], ax
        mov  al, [es:0xCF]
        mov  ah, 0
        mov  [spt], ax
        mov  ax, [es:0xCC]
        mov  [cyls], ax

        call parse_args

        mov  dx, msg_geo
        call puts
        mov  ax, [cyls]
        call putdec
        mov  dx, msg_x
        call puts
        mov  ax, [heads]
        call putdec
        mov  dx, msg_x
        call puts
        mov  ax, [spt]
        call putdec
        mov  dx, msg_geo2
        call puts
        mov  ax, [persec]
        call putdec
        mov  dx, msg_geo3
        call puts

        ; ---- a 127-sector read needs more buffer than a .COM has ----
        ; AH=4A resizes the block ES points at, so ES must be our own PSP.
        push cs
        pop  es
        mov  bx, 0x1000
        mov  ah, 0x4A
        int  0x21
        mov  bx, 0xFFFF
        mov  ah, 0x48
        int  0x21                       ; always fails; BX = largest block
        cmp  bx, 0x0FE0                 ; 4064 paragraphs = 127 sectors
        jb   .nomem
        cmp  bx, 0x1000
        jbe  .take
        mov  bx, 0x1000
.take:
        mov  ah, 0x48
        int  0x21
        jc   .nomem
        mov  [bufseg], ax

        ; ================= integrity =================
        ; The regression check. Same region, same order, every run.
        mov  dx, msg_int
        call puts
        mov  word [lba], 0
        mov  word [sum], 0
        mov  cx, CHKSEC / 8
.ick:
        push cx
        mov  byte [sect], 8
        call do_io
        jc   .ibad
        call addsum
        add  word [lba], 8
        pop  cx
        loop .ick
        mov  ax, [sum]
        call puthexw
        mov  dx, msg_int2
        call puts
        jmp  short .bench
.ibad:
        pop  cx
        mov  dx, msg_ifail
        call puts
        jmp  bye

        ; ================= throughput =================
.bench:
        mov  dx, msg_cols
        call puts
        call snapshot                   ; counters before
        call gettick
        mov  [t_all], ax

        mov  byte [phase], 0
.ph:
        mov  bl, [phase]
        cmp  bl, NPHASE
        jb   .run
        jmp  .done
.run:
        mov  bh, 0
        mov  al, [ph_sect+bx]
        mov  [sect], al

        ; commands = sectors-per-phase / sectors-per-command
        mov  ah, 0
        mov  [secpc], ax
        mov  ax, [persec]
        xor  dx, dx
        div  word [secpc]
        mov  [cmds], ax                 ; may truncate: 127 does not divide
        mul  word [secpc]
        mov  [moved], ax                ; the sectors actually read

        mov  word [lba], 0
        call gettick
        mov  [t0], ax

        mov  cx, [cmds]
.rd:
        push cx
        call do_io
        pop  cx
        jc   .rdbad
        mov  al, [sect]
        mov  ah, 0
        add  [lba], ax
        loop .rd

        call gettick
        sub  ax, [t0]                   ; unsigned: correct across a wrap
        jnz  .gott
        mov  ax, 1                      ; never divide by zero
.gott:
        mov  [ticks], ax
        call report
        inc  byte [phase]
        jmp  .ph
.rdbad:
        mov  dx, msg_rdfail
        call puts
        jmp  bye

.done:
        call gettick
        sub  ax, [t_all]
        mov  [ticks], ax
        mov  dx, msg_cost
        call puts
        call delta
        jmp  short bye

.nomem:
        mov  dx, msg_nomem
        call puts
bye:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; report -- one row: size, commands, sectors, ticks, KB/s
report:
        push ax
        push bx
        push dx
        mov  bl, [phase]
        mov  bh, 0
        shl  bl, 1
        mov  dx, [ph_name+bx]
        call puts
        mov  ax, [cmds]
        call putdec6
        mov  ax, [moved]
        call putdec6
        mov  ax, [moved]
        shr  ax, 1                      ; sectors -> KB
        call putdec6
        mov  ax, [ticks]
        call putdec6
        call kbps
        call putdec6
        mov  dx, msg_crlf
        call puts
        pop  dx
        pop  bx
        pop  ax
        ret

; kbps -- AX = KB/s from [moved] sectors in [ticks] ticks.
;   KB/s = (sectors/2) * 182 / (ticks * 10)     -- 18.2 Hz as a fraction, so
;   the arithmetic stays in integers. The dividend is 32-bit; the phase sizes
;   are chosen so the quotient always fits 16 bits.
kbps:
        push bx
        push cx
        push dx
        mov  ax, [moved]
        shr  ax, 1                      ; KB
        mov  bx, 182
        mul  bx                         ; DX:AX = KB * 182
        mov  bx, [ticks]
        mov  cx, 10
        push ax
        mov  ax, bx
        mul  cx
        mov  bx, ax                     ; BX = ticks * 10
        pop  ax
        div  bx
        pop  dx
        pop  cx
        pop  bx
        ret

; ---------------------------------------------------------------------------
; do_io -- read [sect] sectors from [lba] into the buffer. Read only.
do_io:
        push ax
        push bx
        push cx
        push dx
        push es
        mov  ax, [lba]
        xor  dx, dx
        div  word [spt]
        mov  bl, dl
        inc  bl                         ; sector, 1-based
        xor  dx, dx
        div  word [heads]               ; ax = cylinder, dx = head
        mov  ch, al
        mov  cl, 6
        shl  ah, cl
        mov  cl, ah
        and  cl, 0xC0
        or   cl, bl
        mov  dh, dl
        mov  dl, HDD
        mov  es, [bufseg]
        xor  bx, bx
        mov  ah, 0x02                   ; READ. This program never writes.
        mov  al, [sect]
        int  0x13
        pop  es
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; addsum -- fold [sect] sectors of the buffer into the running checksum
addsum:
        push ax
        push bx
        push cx
        push si
        push ds
        mov  ax, [sect]
        mov  ah, 0
        mov  cl, 9
        shl  ax, cl                     ; bytes = sectors * 512
        mov  cx, ax
        mov  bx, [sum]
        mov  ax, [bufseg]
        mov  ds, ax
        xor  si, si
.as:    mov  al, [si]
        mov  ah, 0
        add  bx, ax
        inc  si
        loop .as
        pop  ds
        mov  [sum], bx
        pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

; gettick -- AX = the low word of the BIOS tick count at 0040:006C
gettick:
        push ds
        push bx
        mov  bx, 0x40
        mov  ds, bx
        mov  ax, [0x6C]
        pop  bx
        pop  ds
        ret

; ---------------------------------------------------------------------------
; controller counters
snapshot:
        push ax
        push bx
        push cx
        push di
        push si
        mov  si, cur
        mov  di, prev
        mov  cx, 12
.cp:    mov  al, [si]
        mov  [di], al
        inc  si
        inc  di
        loop .cp
        xor  bx, bx
        mov  cx, 12
.rd:    mov  al, bl
        out  U_DIAG, al
        in   al, U_DIAG
        mov  di, cur
        add  di, bx
        mov  [di], al
        inc  bx
        loop .rd
        pop  si
        pop  di
        pop  cx
        pop  bx
        pop  ax
        ret

; delta -- transactions, NAKs and timeouts over the whole run, plus the
; bytes-per-transaction figure that should NOT move when only the CPU-side
; copy changes.
delta:
        push ax
        push bx
        push cx
        push dx
        call snapshot
        mov  ah, [cur+11]
        mov  al, [cur+10]
        mov  bh, [prev+11]
        mov  bl, [prev+10]
        sub  ax, bx
        mov  [txn], ax
        call putdec6
        mov  dx, msg_cost2
        call puts
        mov  ah, [cur+9]
        mov  al, [cur+3]
        mov  bh, [prev+9]
        mov  bl, [prev+3]
        sub  ax, bx
        call putdec6
        mov  dx, msg_cost3
        call puts
        mov  al, [cur+2]
        sub  al, [prev+2]
        mov  ah, 0
        call putdec6
        mov  dx, msg_cost4
        call puts
        mov  ax, [ticks]
        call putdec6
        mov  dx, msg_crlf
        call puts
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
parse_args:
        push ax
        push bx
        push cx
        push dx
        push si
        mov  ax, BASESEC
        mov  [persec], ax
        mov  al, [0x80]
        test al, al
        jz   .out
        mov  cl, al
        mov  ch, 0
        mov  si, 0x81
        xor  bx, bx
.scan:  lodsb
        cmp  al, '0'
        jb   .next
        cmp  al, '9'
        ja   .next
        sub  al, '0'
        mov  ah, 0
        push ax
        mov  ax, bx
        mov  dx, 10
        mul  dx
        mov  bx, ax
        pop  ax
        add  bx, ax
.next:  loop .scan
        test bx, bx
        jz   .out
        cmp  bx, 8                      ; clamp: the KB/s quotient must fit
        jbe  .mul
        mov  bx, 8
.mul:   mov  ax, BASESEC
        mul  bx
        mov  [persec], ax
.out:
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
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

putdec6:                        ; AX right-aligned in six columns
        push ax
        push bx
        push cx
        push dx
        push si
        mov  si, ax             ; DOS output needs AH and returns AL, so the
        xor  cx, cx             ; value cannot live in AX across the padding
        mov  bx, 10
.count: xor  dx, dx
        div  bx
        inc  cx
        test ax, ax
        jnz  .count
        mov  bx, 6
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
msg_hdr   db 'USBPERF - USB hard disk read benchmark',13,10
          db 'Read-only: it never issues AH=03, so it is safe with DOS on C:.',13,10
          db '----------------------------------------------------------------',13,10,'$'
msg_nodisk db 'No USB disk enumerated at POST.',13,10,'$'
msg_nomem  db 'Could not allocate a 64 KB buffer.',13,10,'$'
msg_geo   db 'geometry  : $'
msg_x     db ' x $'
msg_geo2  db '     per phase: $'
msg_geo3  db ' sectors',13,10,'$'
msg_int   db 'integrity : checksum of the first 32 KB = $'
msg_int2  db 13,10
          db '            This must NOT change between runs. A faster driver',13,10
          db '            that returns different bytes is not a faster driver.',13,10,'$'
msg_ifail db 13,10,'Integrity read FAILED - stopping.',13,10,'$'
msg_rdfail db 13,10,'Read failed during the benchmark - stopping.',13,10,'$'
msg_cols  db 13,10
          db '  size    cmds  sects      KB  ticks    KB/s',13,10
          db '  ------------------------------------------',13,10,'$'
msg_cost  db 13,10,'cost      : transactions $'
msg_cost2 db '   NAKs $'
msg_cost3 db '   timeouts $'
msg_cost4 db '   total ticks $'
msg_crlf  db 13,10,'$'

n_512     db '  512B $'
n_1k      db '  1K   $'
n_4k      db '  4K   $'
n_32k     db '  32K  $'
n_63k     db '  63.5K$'
ph_name   dw n_512, n_1k, n_4k, n_32k, n_63k
ph_sect   db 1, 2, 8, 64, 127

; ---------------------------------------------------------------------------
bufseg  dw 0
heads   dw 16
spt     dw 63
cyls    dw 0
lba     dw 0
sect    db 1
secpc   dw 0
cmds    dw 0
moved   dw 0
persec  dw BASESEC
phase   db 0
ticks   dw 0
t0      dw 0
t_all   dw 0
txn     dw 0
sum     dw 0
prev    times 12 db 0
cur     times 12 db 0
