; ============================================================================
;  memtop.asm  --  test the memory a LARGE program actually gets
;
;  MEMTEST covers 0x20000..0x7FFFF -- 128 KB to 512 KB. The top 128 KB of
;  conventional memory has never been tested by anything on this board, and it
;  is precisely the part nothing small ever touches: DOS, COMMAND.COM and every
;  utility here live below it and would not notice if it were made of tin.
;
;  A 500 KB game fills it. If it is bad, the game writes structures up there,
;  reads back something else, and goes wherever the corrupted values send it --
;  stray characters on screen, interrupts left disabled, no BIOS calls, no error
;  message. Everything else on the machine keeps working perfectly, which is
;  what makes it such a convincing impostor for a dozen other faults.
;
;  Rather than hardcode a range, this asks DOS for the largest free block and
;  tests exactly that: it shrinks its own allocation to the minimum first, so
;  what comes back is the same memory a large program would be handed. Nothing
;  DOS is using is written to, so this is safe to run from the command line.
;
;  Every chunk is filled BEFORE any of it is verified. Testing a chunk at a
;  time would pass on aliased memory -- write, read back, agree, move on, while
;  the write quietly landed on top of an earlier chunk. Filling everything
;  first means an alias destroys evidence that is checked afterwards.
;
;  The pattern is the address itself (offset XOR segment), so a cell that
;  answers for the wrong address is caught as well as one that simply holds
;  the wrong bits. Then the whole thing again inverted, so a bit stuck at one
;  and a bit stuck at zero are both covered.
;
;  Progress goes to port 0x80 as it runs, so if the machine dies mid-test the
;  7-segment display shows which chunk it died in.
;
;  Build:  nasm -f bin memtop.asm -o memtop.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

KEEP    equ 0x0100              ; paragraphs we keep for ourselves: 4 KB, which
                                ; is this program plus room for its stack

start:
        cld
        mov  dx, msg_hdr
        call puts

; ---------------------------------------------------------------------------
; Move the stack down into the part we are about to keep.
;
; DOS starts a .COM with SP at the top of the entire 64 KB segment it was
; handed. After SETBLOCK below, that address no longer belongs to us -- it
; belongs to the block we then allocate and fill with the test pattern. The
; first chunk would overwrite this program's own return addresses, and the
; test would wander off into whatever it had just written over itself.
;
; Nothing on the current stack is needed: the only thing DOS put there is the
; return-to-PSP word, and this exits through INT 21h/4Ch instead.
        cli
        mov  sp, KEEP*16 - 2
        sti

; Give back everything but our own working set. A .COM is handed all of memory
; at load, so without this there is no free block to ask for.
        mov  ax, cs
        mov  es, ax
        mov  bx, KEEP
        mov  ah, 0x4A
        int  0x21
        jnc  .shrunk            ; Jcc is short-only on an 8086 and the error
        jmp  noshrink           ; paths are at the far end -- trampoline
.shrunk:

        mov  ah, 0x48           ; how much is there?
        mov  bx, 0xFFFF
        int  0x21               ; fails by design; BX = largest block
        mov  [blkpar], bx
        cmp  bx, 0x0100         ; less than 4 KB is not worth testing
        jae  .enough
        jmp  nomem
.enough:

        mov  ah, 0x48           ; take it
        mov  bx, [blkpar]
        int  0x21
        jnc  .gotit
        jmp  nomem
.gotit:
        mov  [blkseg], ax

; ---- say what is being tested ----
        mov  dx, msg_range
        call puts
        mov  ax, [blkseg]
        call puthexw
        mov  dx, msg_to
        call puts
        mov  ax, [blkseg]
        add  ax, [blkpar]
        dec  ax
        call puthexw
        mov  dx, msg_size
        call puts
        mov  ax, [blkpar]
        mov  cl, 6              ; paragraphs -> KB
        shr  ax, cl
        call putdec
        mov  dx, msg_kb
        call puts

; ---- pass 1: the address pattern ----
        mov  dx, msg_p1
        call puts
        mov  byte [invert], 0
        call fill_all
        call verify_all
        jc   failed
        mov  dx, msg_pass
        call puts

; ---- pass 2: the same, inverted ----
        mov  dx, msg_p2
        call puts
        mov  byte [invert], 0xFF
        call fill_all
        call verify_all
        jc   failed
        mov  dx, msg_pass
        call puts

        mov  dx, msg_ok
        call puts
        jmp  short bye

failed:
        mov  dx, msg_fail
        call puts
        mov  ax, [badseg]
        call puthexw
        mov  dl, ':'
        call putch
        mov  ax, [badoff]
        call puthexw
        mov  dx, msg_want
        call puts
        mov  ax, [wanted]
        call puthexw
        mov  dx, msg_got
        call puts
        mov  ax, [gotten]
        call puthexw
        mov  dx, msg_failtail
        call puts
        jmp  short bye

noshrink:
        mov  dx, msg_noshrink
        call puts
        jmp  short bye
nomem:
        mov  dx, msg_nomem
        call puts
bye:
        mov  ax, 0x4C00
        int  0x21

; ===========================================================================
;  fill_all -- write the pattern across every chunk, largest unit first.
;
;  ES walks the block in 64 KB steps. The value stored at each word is its own
;  offset XOR the segment holding it, so no two words in the region share a
;  value by construction and a cell that responds to the wrong address gives
;  itself away on the verify pass.
; ===========================================================================
fill_all:
        push ax
        push bx
        push cx
        push dx
        push di
        push si
        push bp
        push es
        ; The invert mask goes in a register, not memory. Reading it from
        ; memory twice per word doubled the bus traffic of the whole test for
        ; no reason -- and on this board the bus is the slow part.
        mov  al, [invert]
        mov  ah, al
        mov  bp, ax
        mov  ax, [blkseg]
        mov  dx, [blkpar]
        xor  bl, bl             ; chunk number, for the display
.chunk:
        test dx, dx
        jz   .done
        push ax                 ; AX is the chunk segment -- the display write
        mov  al, bl             ; below would otherwise eat the low half of it
        or   al, 0x10           ; 1x on the 7-segment = filling
        out  0x80, al
        pop  ax
        call chunk_words        ; CX = words here, DX = paragraphs left after
        mov  es, ax
        mov  si, ax             ; SI = this chunk's segment, part of the pattern
        xor  di, di
.f1:    mov  ax, di
        xor  ax, si
        xor  ax, bp
        mov  [es:di], ax
        inc  di
        inc  di
        loop .f1
        mov  ax, es
        add  ax, 0x1000         ; next 64 KB
        inc  bl
        jmp  short .chunk
.done:
        pop  es
        pop  bp
        pop  si
        pop  di
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ===========================================================================
;  verify_all -- read it all back. CF=1 and badseg/badoff/wanted/gotten set on
;  the first disagreement.
; ===========================================================================
verify_all:
        push ax
        push bx
        push cx
        push dx
        push di
        push si
        push bp
        push es
        mov  al, [invert]       ; as in fill_all: keep it out of memory
        mov  ah, al
        mov  bp, ax
        mov  ax, [blkseg]
        mov  dx, [blkpar]
        xor  bl, bl
.chunk:
        test dx, dx
        jz   .good
        push ax                 ; as above: keep the segment out of AL's way
        mov  al, bl
        or   al, 0x20           ; 2x on the 7-segment = verifying
        out  0x80, al
        pop  ax
        call chunk_words
        mov  es, ax
        mov  si, ax
        xor  di, di
.v1:    mov  ax, di
        xor  ax, si
        xor  ax, bp
        cmp  ax, [es:di]
        jne  .bad
        inc  di
        inc  di
        loop .v1
        mov  ax, es
        add  ax, 0x1000
        inc  bl
        jmp  short .chunk
.bad:
        mov  [wanted], ax
        mov  ax, [es:di]
        mov  [gotten], ax
        mov  ax, es
        mov  [badseg], ax
        mov  [badoff], di
        stc
        jmp  short .out
.good:
        clc
.out:
        pop  es
        pop  bp
        pop  si
        pop  di
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
; chunk_words -- DX = paragraphs remaining. Returns CX = words in this chunk
; and DX reduced by the paragraphs it covers. A full chunk is 0x1000
; paragraphs = 0x8000 words; CX never reaches zero, so LOOP is safe.
chunk_words:
        push ax
        mov  ax, 0x1000
        cmp  dx, ax
        jae  .full
        mov  ax, dx
.full:
        sub  dx, ax
        mov  cx, ax
        shl  cx, 1
        shl  cx, 1
        shl  cx, 1              ; paragraphs * 8 = words
        pop  ax
        ret

; ---------------------------------------------------------------------------
putch:  push ax
        push dx
        mov  dl, al
        mov  ah, 2
        int  0x21
        pop  dx
        pop  ax
        ret
puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret
puthexw:
        push ax
        mov  al, ah
        call puthexb
        pop  ax
        call puthexb
        ret
puthexb:
        push ax
        push bx
        push cx
        mov  bl, al
        mov  cl, 4
        shr  al, cl
        call .nib
        mov  al, bl
        call .nib
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
.n1:    call putch
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
        call putch
        loop .d2
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
blkseg  dw 0
blkpar  dw 0
invert  db 0
badseg  dw 0
badoff  dw 0
wanted  dw 0
gotten  dw 0

msg_hdr db 'MEMTOP - the memory a large program actually gets',13,10
        db '-------------------------------------------------',13,10
        db 'MEMTEST stops at 512 KB. Everything above that has never been',13,10
        db 'tested, and it is exactly what a 500 KB game fills.',13,10,13,10,'$'
msg_range db 'Testing the largest free block: $'
msg_to  db '0 .. $'
msg_size db 'F   =  $'
msg_kb  db ' KB',13,10,13,10,'$'
msg_p1  db '  pass 1  address pattern   : $'
msg_p2  db '  pass 2  inverted          : $'
msg_pass db 'PASS',13,10,'$'
msg_fail db 'FAIL',13,10,13,10,'  first bad word at $'
msg_want db '   wanted $'
msg_got db '   got $'
msg_failtail db 13,10,13,10
        db 'This memory does not hold what is written to it. A program large',13,10
        db 'enough to reach here will read back values it never stored and go',13,10
        db 'wherever they send it -- which looks like a hang, a corrupt screen,',13,10
        db 'or anything else. Nothing above this is worth debugging.',13,10,'$'
msg_ok  db 13,10,'All of it holds what was written to it, at both polarities.',13,10
        db 'Memory is not the fault.',13,10,'$'
msg_noshrink db 'Could not release memory back to DOS.',13,10,'$'
msg_nomem db 'No free block worth testing.',13,10,'$'
