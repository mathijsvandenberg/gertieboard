; ============================================================================
;  egatext.asm  --  which INT 10h text path mangles which character?
;
;  King's Quest draws correctly in mode 0Dh except that every cell which should
;  be BLANK comes out as a C-cedilla. That glyph is character 0x80 in this
;  BIOS's font, and nothing else in the font matches it -- 0x00 and 0x20 are
;  both genuinely blank. So either
;
;      the game asks for 0x80 and a real EGA BIOS draws something else, or
;      one of our INT 10h paths loses AL and renders an attribute byte
;
;  A photograph cannot tell those apart, and three rounds of guessing from
;  screenshots is how the CGA scrolling attempt went wrong. So this asks each
;  path for a KNOWN character and shows what comes back.
;
;  Read it as a table. Every row is labelled, and the expected result is
;  printed beside it:
;
;    09 sp   AH=09h with a space          must be BLANK
;    09 A    AH=09h with 'A'              must be AAAA...
;    09 80   AH=09h with 0x80             must be BLANK. The upper 128 glyphs
;                                         are not in ROM on a real machine --
;                                         they come from INT 1Fh, which DOS
;                                         leaves null -- so a code above 127
;                                         draws nothing until something like
;                                         GRAFTABL installs a table.
;    09 sp*  AH=09h, space, attribute 80  must be BLANK: the attribute must not
;                                         reach the glyph lookup
;    0A sp   AH=0Ah with a space          must be BLANK
;    0E str  AH=0Eh teletype "X Y Z"      must have real gaps between letters
;
;  WHAT EACH OUTCOME MEANS
;
;    every row correct                 -> the BIOS is fine, and King's Quest is
;                                         genuinely passing 0x80. It expects a
;                                         real EGA BIOS to treat it as nothing.
;    "09 sp*" is the only wrong one    -> the attribute is reaching the glyph
;                                         lookup: AL is being lost when BL is
;                                         non-zero
;    "09 sp" and "0A sp" wrong         -> the repeat path mangles the character
;    "0E str" alone wrong              -> the teletype path, not the renderer
;
;  Build:  nasm -f bin egatext.asm -o egatext.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

FILL    equ 12                  ; cells written per test

start:
        mov  dx, msg_intro
        mov  ah, 9
        int  0x21
        xor  ah, ah
        int  0x16

        mov  ax, 0x000D         ; 320x200x16, four planes
        int  0x10

        ; ---- row 1: AH=09h, space. Must be BLANK. ----------------------
        mov  dx, 0x0100
        call gotoxy
        mov  si, l_09sp
        call say
        mov  dx, 0x010A
        call gotoxy
        mov  al, ' '
        mov  bl, 15             ; a REAL colour: BL is honoured now, and a test
        call wr09               ; that passes 0 draws black on black

        ; ---- row 3: AH=09h, 'A'. Must be a run of A. --------------------
        mov  dx, 0x0300
        call gotoxy
        mov  si, l_09a
        call say
        mov  dx, 0x030A
        call gotoxy
        mov  al, 'A'
        mov  bl, 15
        call wr09

        ; ---- row 5: AH=09h, 0x80. THE CONTROL: must be the C-cedilla. ---
        ; If this row is blank the font or the renderer is at fault and every
        ; other row below is meaningless.
        mov  dx, 0x0500
        call gotoxy
        mov  si, l_0980
        call say
        mov  dx, 0x050A
        call gotoxy
        mov  al, 0x80
        mov  bl, 15
        call wr09

        ; ---- row 7: AH=09h, space, ATTRIBUTE 0x80. Must be BLANK. -------
        ; 0x80 as an attribute is blinking black-on-black, which is exactly
        ; what a program would use for an empty cell -- and exactly the byte
        ; that would draw a C-cedilla if it reached the glyph lookup.
        mov  dx, 0x0700
        call gotoxy
        mov  si, l_09spa
        call say
        mov  dx, 0x070A
        call gotoxy
        mov  al, ' '
        mov  bl, 0x80
        call wr09

        ; ---- row 9: AH=0Ah, space. Must be BLANK. -----------------------
        mov  dx, 0x0900
        call gotoxy
        mov  si, l_0asp
        call say
        mov  dx, 0x090A
        call gotoxy
        mov  al, ' '
        mov  ah, 0x0A
        mov  cx, FILL
        xor  bh, bh
        int  0x10

        ; ---- row 11: AH=0Eh teletype, with real spaces ------------------
        mov  dx, 0x0B00
        call gotoxy
        mov  si, l_0estr
        call say
        mov  dx, 0x0B0A
        call gotoxy
        mov  si, s_spaced
        call say

        ; ---- row 14: a reference line, so the font can be judged --------
        mov  dx, 0x0E00
        call gotoxy
        mov  si, s_ref
        call say

        xor  ah, ah
        int  0x16

; ===========================================================================
;  PAGE 2 -- drawing text ONTO something, which is what a status bar is.
;
;  King's Quest paints a white strip and puts BLACK text on it. That cannot be
;  said as "foreground here, background there": it is done by XOR, flipping the
;  set pixels against what is already on screen. This draws a white strip and
;  then the same word over it three ways, so the one that works is visible and
;  the ones that do not are visible too.
;
;  EGATEST never covered XOR -- it tested replace, write mode 1 and write mode
;  2 -- so if the XOR row is wrong, the fault is in the hardware's function
;  select and not in the BIOS.
; ===========================================================================
        mov  ax, 0x0003         ; clear everything and come back, so page 2
        int  0x10               ; is not read against page 1's leftovers
        mov  ax, 0x000D
        int  0x10

        mov  dx, 0x0000
        call gotoxy
        mov  si, l_p2
        call say

        ; ---- a white strip across rows 4..5, drawn straight to the planes --
        ; Not via the BIOS: this is the BACKGROUND the text has to work over,
        ; and it has to be there regardless of whether the BIOS can draw.
        call white_strip

        ; ---- the same word, three ways, on top of the strip ---------------
        mov  dx, 0x0400
        call gotoxy
        mov  bl, 0x0F           ; opaque WHITE  -> white on black cells
        mov  si, s_word
        call sayc

        mov  dx, 0x040A
        call gotoxy
        mov  bl, 0x00           ; opaque BLACK  -> black on black cells
        mov  si, s_word
        call sayc

        mov  dx, 0x0414
        call gotoxy
        mov  bl, 0x8F           ; XOR white     -> BLACK ON WHITE. This is the
        mov  si, s_word         ; one King's Quest needs.
        call sayc

        mov  dx, 0x0700
        call gotoxy
        mov  si, l_p2exp
        call say

        xor  ah, ah
        int  0x16

        mov  ax, 0x060E         ; GC 6 back to alphanumeric before mode 3
        mov  dx, 0x03CE
        out  dx, al
        mov  al, ah
        inc  dx
        out  dx, al
        mov  ax, 0x0003
        int  0x10
        mov  dx, msg_done
        mov  ah, 9
        int  0x21
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; gotoxy -- cursor to DH,DL  (not "at": NASM already has a macro by that name)
gotoxy:
        push ax
        push bx
        mov  ah, 2
        xor  bh, bh
        int  0x10
        pop  bx
        pop  ax
        ret

; wr09 -- AL = character, BL = attribute, FILL cells
wr09:
        push ax
        push bx
        push cx
        mov  ah, 9
        xor  bh, bh
        mov  cx, FILL
        int  0x10
        pop  cx
        pop  bx
        pop  ax
        ret

; white_strip -- rows 4 and 5 solid white, written directly to all four planes.
; Map mask open, write mode 0, replace, every bit: one store paints eight pixels
; white on every plane at once.
white_strip:
        push ax
        push cx
        push di
        push es
        mov  ax, 0xA000
        mov  es, ax
        mov  ax, 0x020F         ; SEQ 2 map mask = all four planes
        call seqout
        mov  ax, 0x08FF         ; GC 8 bit mask = every bit
        call gcout
        mov  ax, 0x0300         ; GC 3 function = replace
        call gcout
        mov  ax, 0x0100         ; GC 1 enable set/reset off
        call gcout
        mov  di, 4*8*40         ; first scanline of character row 4
        mov  cx, 16*40          ; two character rows
        mov  al, 0xFF
        cld
        rep  stosb
        pop  es
        pop  di
        pop  cx
        pop  ax
        ret

; sayc -- like say, but through AH=09h so the colour in BL is honoured, and
; advancing the cursor by hand because AH=09h does not move it.
sayc:
        push ax
        push bx
        push cx
        push dx
        push si
        cld
.c:     lodsb
        or   al, al
        jz   .cd
        mov  ah, 9
        xor  bh, bh
        mov  cx, 1
        int  0x10
        inc  dl
        call gotoxy
        jmp  .c
.cd:    pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; seqout / gcout -- AH = index, AL = value
seqout:
        push dx
        push ax
        mov  dx, 0x3C4
        mov  al, ah
        out  dx, al
        pop  ax
        mov  dx, 0x3C5
        out  dx, al
        pop  dx
        ret

gcout:
        push dx
        push ax
        mov  dx, 0x3CE
        mov  al, ah
        out  dx, al
        pop  ax
        mov  dx, 0x3CF
        out  dx, al
        pop  dx
        ret

; say -- teletype the NUL-terminated string at DS:SI
say:
        push ax
        push bx
        push si
        cld
.s:     lodsb
        or   al, al
        jz   .d
        mov  ah, 0x0E
        xor  bh, bh
        mov  bl, 15
        int  0x10
        jmp  .s
.d:     pop  si
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
l_09sp   db '09 sp',0
l_09a    db '09 A',0
l_0980   db '09 80',0
l_09spa  db '09 sp*',0
l_0asp   db '0A sp',0
l_0estr  db '0E str',0
s_spaced db 'X Y Z',0
s_ref    db 'abc ABC 123',0
s_word   db 'Score',0
l_p2     db 'page 2: text over a white strip',0
l_p2exp  db 'left 0F white  mid 00 black  right 8F XOR',0

msg_intro:
        db 'EGATEXT - which INT 10h path mangles which character?',13,10
        db '-----------------------------------------------------',13,10
        db 'Mode 0Dh renders text now, but cells that should be BLANK',13,10
        db 'come out as a C-cedilla. That is character 0x80 in this',13,10
        db "BIOS's font, and 0x00 and 0x20 are both genuinely blank --",13,10
        db 'so something is asking for 0x80 where it means nothing.',13,10,13,10
        db 'Six rows, each labelled. Expected:',13,10
        db '  09 sp    BLANK',13,10
        db '  09 A     AAAAAAAA',13,10
        db '  09 80    BLANK       <- codes above 127 come from INT 1Fh,',13,10
        db '                          which DOS leaves null',13,10
        db '  09 sp*   BLANK       <- space, but attribute 0x80',13,10
        db '  0A sp    BLANK',13,10
        db '  0E str   X Y Z, with real gaps',13,10,13,10
        db 'If only "09 sp*" is wrong, the attribute is reaching the',13,10
        db 'glyph lookup. If every row is right, the BIOS is innocent',13,10
        db 'and the game is passing 0x80 on purpose.',13,10,13,10
        db 'Press a key. A second page then draws text OVER a white',13,10
        db 'strip three ways -- opaque white, opaque black, and XOR.',13,10
        db 'Only XOR can put black text on a light background, and it',13,10
        db 'is the one King&s status bar needs. If the XOR word is not',13,10
        db 'readable black-on-white, the fault is in the hardware.',13,10,'$'

msg_done:
        db 13,10,'Back in text mode.',13,10,'$'
