; ============================================================================
;  scrolltst.asm  --  does CRTC R12/R13 move the picture by the right amount?
;
;  vga.vhd now honours the 6845's display start address, and Keen 4 came back
;  with the picture partly overlapping itself. Two things could produce that and
;  a photograph cannot tell them apart:
;
;      the addressing arithmetic in vga.vhd is wrong, or
;      the arithmetic is right and Keen wants something else from the card
;
;  So this asks the hardware directly, with a pattern whose position can be read
;  off the screen. There is no game, no BIOS scrolling and no guesswork: set the
;  register, look at where the picture went, compare with what the register says
;  it should be.
;
;  TEXT MODE. The screen is filled with 51 numbered rows -- "00 AAAA...",
;  "01 BBBB...", and so on past the bottom of the visible 25. The 6845 counts
;  one CHARACTER CELL per step here, so:
;
;      start = 80    row 01 must be at the top, and NOTHING else may change
;      start = 1     every row must shift LEFT by one character, and the row
;                    below must wrap into the right-hand end of the row above
;
;  That second one looks broken and is correct: a 6845 has one address counter
;  and no concept of a line, so a start address that is not a multiple of the
;  row length skews the whole screen. If it does anything tidier than skew, the
;  implementation is inventing something the hardware does not do.
;
;  GRAPHICS MODE 4. The same register, but the CGA fetches TWO BYTES per count,
;  so the unit is a word and one step of 40 is one CGA row-pair:
;
;      start = 40    the picture must rise by exactly TWO CGA scanlines, which
;                    is four lines on this 400-line display
;      start = 1     the picture must shift left by two CGA pixels
;
;  The pattern is a rule across the screen every 10 scanlines and a single
;  4-pixel block stepping one byte to the right per scanline. Both are easy to
;  count and the diagonal fixes the absolute position within 80 lines, so a
;  wrong step size shows up immediately rather than looking plausible.
;
;  WHAT EACH OUTCOME MEANS
;
;      moves by the stated amount, cleanly   -> vga.vhd is right, and Keen's
;                                               overlap is Keen expecting
;                                               something else (row stride,
;                                               a redraw racing the scan)
;      moves by half or double               -> the word/cell doubling is wrong
;      moves the right amount but tears      -> the per-field latch is not
;                                               holding for the whole field
;      does not move at all                  -> START is not reaching vga.vhd
;
;  Keys:  arrows, or 8 2 4 6      up/down = one row, left/right = one unit
;         0 = back to start 0
;         ESC = next test / exit
;
;  Build:  nasm -f bin scrolltst.asm -o scrolltst.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

CRTC_IDX  equ 0x3D4
CRTC_DAT  equ 0x3D5
CGA_MODE  equ 0x3D8
CGA_PAL   equ 0x3D9
STATUS    equ 0x3DA
VRAM      equ 0xB800

start:
        cld
        mov  dx, msg_intro
        call puts
        call getkey

; ---------------------------------------------------------------------------
;  Test 1 -- text mode, one count per character cell
; ---------------------------------------------------------------------------
        call text_mode
        call fill_text
        mov  word [step], 80
        call scroll_loop

; ---------------------------------------------------------------------------
;  Test 2 -- graphics mode 4, one count per WORD
; ---------------------------------------------------------------------------
        call text_mode
        mov  dx, msg_gfx
        call puts
        call getkey

        mov  ax, 0x0004
        int  0x10
        ; Forced directly as well as through the BIOS, so the test does not
        ; depend on INT 10h supporting mode 4: 0x3D8 bit 1 = graphics,
        ; bit 3 = video enable. 0x3D9 = palette 1, high intensity.
        mov  dx, CGA_MODE
        mov  al, 0x0A
        out  dx, al
        mov  dx, CGA_PAL
        mov  al, 0x30
        out  dx, al

        call fill_gfx
        mov  word [step], 40
        call scroll_loop

        call text_mode
        mov  dx, msg_done
        call puts
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
;  The loop that drives the register
;
;  The start address is written during vertical retrace, which is what software
;  of the period does and what the per-field latch in vga.vhd expects. Writing
;  it anywhere else is legal on a 6845 -- the register is only consulted once a
;  field -- and if this test behaves differently outside retrace then the latch
;  is not doing its job.
; ---------------------------------------------------------------------------
scroll_loop:
        mov  word [cur], 0
.again: call vretrace
        mov  ax, [cur]
        call set_start
.key:   call getkey
        cmp  al, 27
        je   .out
        or   al, al             ; AL = 0 marks an extended (arrow) key
        jnz  .ascii
        cmp  ah, 0x50
        je   .plus_s            ; down  -> later content, picture rises
        cmp  ah, 0x48
        je   .minus_s           ; up
        cmp  ah, 0x4D
        je   .plus_1            ; right
        cmp  ah, 0x4B
        je   .minus_1           ; left
        jmp  .key
.ascii: cmp  al, '2'
        je   .plus_s
        cmp  al, '8'
        je   .minus_s
        cmp  al, '6'
        je   .plus_1
        cmp  al, '4'
        je   .minus_1
        cmp  al, '0'
        je   .zero
        jmp  .key

.plus_s:  mov ax, [step]
          add [cur], ax
          jmp .again
.minus_s: mov ax, [step]
          sub [cur], ax
          jmp .again
.plus_1:  inc word [cur]
          jmp .again
.minus_1: dec word [cur]
          jmp .again
.zero:    mov word [cur], 0
          jmp .again
.out:     ret

; ---------------------------------------------------------------------------
; set_start -- AX into R12/R13, high byte first
set_start:
        push ax
        push bx
        push dx
        mov  bx, ax
        mov  dx, CRTC_IDX
        mov  al, 12
        out  dx, al
        inc  dx
        mov  al, bh
        out  dx, al
        dec  dx
        mov  al, 13
        out  dx, al
        inc  dx
        mov  al, bl
        out  dx, al
        pop  dx
        pop  bx
        pop  ax
        ret

; vretrace -- wait for the START of the vertical retrace window, not merely for
; the bit to be set. Entering while retrace is already half over would leave
; almost no time before the next field begins.
vretrace:
        push ax
        push dx
        mov  dx, STATUS
.v1:    in   al, dx
        test al, 8
        jnz  .v1                ; wait until NOT retracing
.v2:    in   al, dx
        test al, 8
        jz   .v2                ; then for retrace to begin
        pop  dx
        pop  ax
        ret

text_mode:
        push ax
        push dx
        mov  ax, 0x0003
        int  0x10
        mov  dx, CGA_MODE
        mov  al, 0x29           ; 80 column text, video enabled, blink
        out  dx, al
        pop  dx
        pop  ax
        ret

; ---------------------------------------------------------------------------
; fill_text -- 51 rows of "NN L L L L ...", each row a different letter and a
; different attribute. 51 rows is 4080 cells, which is more than the 4096-cell
; address space the start register can reach, so there is always something to
; scroll TO.
fill_text:
        push es
        mov  ax, VRAM
        mov  es, ax
        xor  di, di
        xor  bp, bp             ; row
.row:
        mov  ax, bp
        mov  bl, 7
        div  bl
        mov  dl, ah
        inc  dl                 ; attribute 1..7, never black on black

        mov  ax, bp
        mov  bl, 26
        div  bl
        mov  dh, ah
        add  dh, 'A'            ; row letter

        mov  ax, bp
        mov  bl, 10
        div  bl                 ; AL tens, AH units
        add  al, '0'
        add  ah, '0'
        mov  bh, ah             ; keep the units digit
        mov  ah, dl             ; attribute into the high half
        stosw                   ; tens
        mov  al, bh
        stosw                   ; units
        mov  al, ' '
        stosw

        mov  al, dh
        mov  cx, 77
        rep  stosw

        inc  bp
        cmp  bp, 51
        jb   .row
        pop  es
        ret

; ---------------------------------------------------------------------------
; fill_gfx -- mode 4. A solid rule every 10th CGA scanline, plus one 4-pixel
; block per scanline stepping one byte right each line. The rules give the
; vertical step size; the diagonal gives the absolute position, so a shift of
; the wrong size cannot be mistaken for the right one.
;
; CGA interleave: even scanlines at +0x0000, odd at +0x2000, 80 bytes each.
fill_gfx:
        push es
        mov  ax, VRAM
        mov  es, ax
        xor  si, si             ; CGA scanline 0..199
.line:
        mov  ax, si
        shr  ax, 1
        mov  bx, 80
        mul  bx                 ; (y / 2) * 80
        test si, 1
        jz   .bank0
        add  ax, 0x2000         ; odd scanlines live in the second bank
.bank0: mov  di, ax
        push di

        mov  ax, si
        mov  bl, 10
        div  bl
        mov  al, 0x00
        cmp  ah, 0
        jne  .plain
        mov  al, 0xAA           ; four pixels of colour 2
.plain: mov  cx, 80
        rep  stosb
        pop  di

        mov  ax, si
        mov  bl, 80
        div  bl
        mov  bl, ah
        xor  bh, bh
        mov  byte [es:di+bx], 0xFF   ; four pixels of colour 3

        inc  si
        cmp  si, 200
        jb   .line
        pop  es
        ret

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

getkey: xor  ah, ah
        int  0x16
        ret

; ---------------------------------------------------------------------------
cur     dw 0
step    dw 80

msg_intro:
        db 'SCROLLTST - is the CRTC start address applied correctly?',13,10
        db '--------------------------------------------------------',13,10
        db 'Two tests. In each, the arrow keys move CRTC R12/R13 and the',13,10
        db 'picture must follow by a KNOWN amount.',13,10,13,10
        db '  up / down     one row   (80 cells text, 40 words graphics)',13,10
        db '  left / right  one count',13,10
        db '  0             back to zero',13,10
        db '  ESC           next test',13,10,13,10
        db 'TEXT: 51 numbered rows. One press of DOWN must put row 01 at the',13,10
        db 'top and change nothing else. One press of RIGHT must skew the whole',13,10
        db 'screen left by one character -- that is correct, a 6845 has one',13,10
        db 'counter and no idea what a line is.',13,10,13,10
        db 'Press a key to begin.',13,10,'$'

msg_gfx:
        db 13,10,'GRAPHICS mode 4. Rules every 10 CGA scanlines, and one block',13,10
        db 'per scanline stepping right.',13,10,13,10
        db 'The count is a WORD here, not a cell, so one press of DOWN is 40',13,10
        db 'counts = 80 bytes = TWO CGA scanlines = four lines on this display.',13,10
        db 'If it moves four CGA scanlines the doubling is applied twice; if it',13,10
        db 'moves one, it is not applied at all.',13,10,13,10
        db 'Press a key.',13,10,'$'

msg_done:
        db 13,10,'Done. What matters is the SIZE of the step and whether the',13,10
        db 'whole field moves together. If both are right then vga.vhd is not',13,10
        db 'the fault and Keen wants something else from the card.',13,10,'$'
