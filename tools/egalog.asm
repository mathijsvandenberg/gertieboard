; ============================================================================
;  egalog.asm  --  what does the game actually ask INT 10h for?
;
;  King's Quest draws its text boxes as white rectangles with nothing in them.
;  EGATEXT page 2 already proved the machine can do this correctly: over a
;  white strip, BL=0x8F XOR renders readable black-on-white, BL=0x0F renders
;  white on a cleared cell, BL=0x00 renders a solid black notch. Hardware and
;  BIOS both behave. So the value the GAME passes is not one of the three, and
;  four rounds of guessing it from photographs have each contradicted the last.
;
;  Empty-white narrows it a long way on its own: an opaque draw clears the cell
;  first, so it would leave BLACK rectangles. Only the XOR path can leave the
;  background untouched, and only a colour of 0 makes XOR a no-op. That points
;  at BL having bit 7 set and bits 3:0 clear -- but pointing is not knowing,
;  and this prints the answer instead.
;
;  USE
;      EGALOG            install, then run the game
;      EGALOG D          dump what was recorded
;      EGALOG Z          zero the log without reinstalling
;
;  It hooks INT 10h, records AH/AL/BL for the three character calls -- 09h
;  write char+attribute, 0Ah write char, 0Eh teletype -- and chains onward. The
;  log is a RING of the last 64, because what matters is the calls that drew
;  the box that is on screen now, not the ones from the title sequence.
;
;  The resident copy is found again through INT 60h, whose vector is left
;  pointing at the counter block. DOS does not use it and nothing else here
;  does either.
;
;  Build:  nasm -f bin egalog.asm -o egalog.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

MAXN    equ 128                 ; entries in the ring
ENTSZ   equ 4                   ; ah, al, bl, spare

start:
        jmp  setup

; ---------------------------------------------------------------------------
;  RESIDENT PART -- everything from here to resident_end stays in memory.
; ---------------------------------------------------------------------------
sig     db 'EGALOG01'           ; so a dump can be sure of what it found
cnt     dw 0                    ; total calls seen (may exceed MAXN)   +8
idx     dw 0                    ; next slot, 0..MAXN-1                 +10
frz     dw 0                    ; non-zero = stop recording            +12
old10   dd 0                    ;                                      +14
                                ; buf follows at                       +18
buf     times MAXN*ENTSZ db 0

; The hook. Chains for everything it does not care about, and touches no
; register the caller can observe.
new10:
        ; FROZEN once a dump starts. Without this the log eats itself: the dump
        ; prints through DOS, DOS prints through INT 10h, and the ring would
        ; fill with the very output being used to read it. The command line
        ; echo and the shell prompt would do the same.
        cmp  word [cs:frz], 0
        jne  .chain
        cmp  ah, 0x09
        je   .log
        cmp  ah, 0x0A
        je   .log
        cmp  ah, 0x0E
        je   .log
.chain:
        jmp  far [cs:old10]
.log:
        push ds
        push si
        push ax
        push cs
        pop  ds

        mov  si, [idx]
        shl  si, 1
        shl  si, 1              ; SI = idx * ENTSZ
        mov  [buf+si], ah
        mov  [buf+si+1], al
        mov  al, bl
        mov  [buf+si+2], al

        inc  word [cnt]
        inc  word [idx]
        cmp  word [idx], MAXN
        jb   .done
        mov  word [idx], 0      ; ring: keep the LATEST 64
.done:
        pop  ax
        pop  si
        pop  ds
        jmp  far [cs:old10]

resident_end:

; ---------------------------------------------------------------------------
;  TRANSIENT PART -- runs once and is thrown away (or kept, on install).
; ---------------------------------------------------------------------------
setup:
        cld
        mov  al, [0x80]         ; command tail length
        xor  ah, ah
        mov  si, 0x81
        xor  bl, bl             ; 0 = install, 'D' = dump, 'Z' = zero
.scan:  or   al, al
        jz   .scanned
        push ax
        lodsb
        and  al, 0xDF           ; upper-case
        cmp  al, 'D'
        je   .isd
        cmp  al, 'Z'
        jne  .nx
        mov  bl, 'Z'
        jmp  .nx
.isd:   mov  bl, 'D'
.nx:    pop  ax
        dec  al
        jmp  .scan
.scanned:
        cmp  bl, 'D'
        je   dump
        cmp  bl, 'Z'
        je   zero
        ; fall through to install

; ---- install --------------------------------------------------------------
install:
        call find_res
        jnc  .already

        mov  ax, 0x3510         ; get the current INT 10h
        int  0x21
        mov  [old10], bx
        mov  [old10+2], es

        mov  ax, 0x2510         ; INT 10h -> our hook
        mov  dx, new10
        int  0x21

        mov  ax, 0x2560         ; INT 60h -> our signature block, so a later
        mov  dx, sig            ; run can find this copy again
        int  0x21

        mov  dx, m_inst
        mov  ah, 9
        int  0x21

        ; Paragraphs to keep, counted from the PSP. Computed at run time --
        ; NASM will not divide a label difference in bin output.
        mov  dx, resident_end
        add  dx, 15
        mov  cl, 4
        shr  dx, cl
        mov  ax, 0x3100         ; keep and exit
        int  0x21
.already:
        mov  dx, m_already
        jmp  bye

; ---- zero -----------------------------------------------------------------
zero:
        call find_res
        jc   .none
        xor  ax, ax
        mov  [es:di+8], ax      ; cnt
        mov  [es:di+10], ax     ; idx
        mov  [es:di+12], ax     ; and start recording again
        mov  dx, m_zero
        jmp  bye
.none:  mov  dx, m_none
        jmp  bye

; ---- dump -----------------------------------------------------------------
dump:
        call find_res
        jc   .none

        mov  word [es:di+12], 1 ; freeze BEFORE printing anything

        mov  dx, m_head
        mov  ah, 9
        int  0x21

        mov  ax, [es:di+8]      ; total seen
        call puthex16
        mov  dx, m_head2
        mov  ah, 9
        int  0x21

        ; Walk the ring from the oldest still held. If fewer than MAXN calls
        ; happened the ring never wrapped, so start at 0.
        mov  cx, [es:di+8]
        cmp  cx, MAXN
        jbe  .from0
        mov  cx, MAXN
        mov  si, [es:di+10]     ; oldest = the next slot to be written
        jmp  .walk
.from0: mov  si, 0
.walk:
        or   cx, cx
        jz   .end
        push cx
        push si

        mov  bx, si
        shl  bx, 1
        shl  bx, 1
        add  bx, di
        add  bx, 18             ; sig 0, cnt 8, idx 10, frz 12, old10 14, buf 18

        mov  al, [es:bx]        ; AH of the call
        call puthex8
        mov  dl, '/'
        call putc
        mov  al, [es:bx+1]      ; AL -- the character
        call puthex8
        mov  dl, '/'
        call putc
        mov  al, [es:bx+2]      ; BL -- colour and flags
        call puthex8

        mov  dl, ' '
        call putc

        pop  si
        pop  cx
        inc  si
        cmp  si, MAXN
        jb   .nowrap
        xor  si, si
.nowrap:
        dec  cx
        jmp  .walk
.end:
        mov  dx, m_tail
        jmp  bye
.none:  mov  dx, m_none
        jmp  bye

bye:
        mov  ah, 9
        int  0x21
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; find_res -- ES:DI = the resident signature block, CF set if not installed.
find_res:
        push ax
        push bx
        push si
        mov  ax, 0x3560         ; INT 60h vector
        int  0x21
        mov  di, bx
        mov  ax, es
        or   ax, di
        jz   .no                ; never installed
        ; verify the signature, so a stray INT 60h owner is not mistaken for us
        mov  si, sig
        mov  bx, 0
.cmp:   mov  al, [es:di+bx]
        cmp  al, [si+bx]
        jne  .no
        inc  bx
        cmp  bx, 8
        jb   .cmp
        clc
        jmp  .out
.no:    stc
.out:   pop  si
        pop  bx
        pop  ax
        ret

putc:
        push ax
        mov  ah, 2
        int  0x21
        pop  ax
        ret

puthex8:
        push ax
        push cx
        mov  cl, al
        shr  al, 1
        shr  al, 1
        shr  al, 1
        shr  al, 1
        call .nib
        mov  al, cl
        and  al, 0x0F
        call .nib
        pop  cx
        pop  ax
        ret
.nib:   add  al, '0'
        cmp  al, '9'
        jbe  .p
        add  al, 7
.p:     mov  dl, al
        push ax
        mov  ah, 2
        int  0x21
        pop  ax
        ret

puthex16:
        push ax
        mov  al, ah
        call puthex8
        pop  ax
        call puthex8
        ret

; ---------------------------------------------------------------------------
m_inst    db 'EGALOG installed. Run the game, then EGALOG D.',13,10,'$'
m_already db 'EGALOG is already installed. Use EGALOG D or EGALOG Z.',13,10,'$'
m_none    db 'EGALOG is not installed.',13,10,'$'
m_zero    db 'Log cleared, and recording resumed.',13,10,'$'
m_head    db 'INT 10h character calls, AH/AL/BL. Total seen: 0x','$'
m_head2   db 13,10,'(the last 128, oldest first; recording is now FROZEN --',13,10
          db 'run EGALOG Z to clear and resume)',13,10,'$'
m_tail    db 13,10,13,10
          db 'AL is the character, BL the colour byte. Bit 7 of BL means XOR;',13,10
          db 'bits 3:0 are the colour. A BL with bit 7 set and a colour of 0',13,10
          db 'is a no-op -- it XORs with black -- which is what an empty white',13,10
          db 'box looks like.',13,10,'$'
