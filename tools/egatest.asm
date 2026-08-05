; ============================================================================
;  egatest.asm  --  does the EGA hardware work, before the BIOS knows it exists?
;
;  Mode 0Dh is 320x200 in 16 colours, four bit planes of 8 KB at 0xA0000. The
;  BIOS cannot set it yet and does not need to: a mode is nothing but a set of
;  register writes, and this makes them itself. Same pattern as CRTCTEST and
;  SCROLLTST -- prove the hardware first, teach the BIOS second, so that when
;  something is wrong there is only one place it can be.
;
;  Four things are tested, and each one fails VISIBLY and DIFFERENTLY:
;
;    1 SIXTEEN COLOUR BARS, painted with write mode 2.
;      Proves all four planes are written and read, that the plane-to-colour
;      mapping is I:R:G:B and not some rotation of it, and that the palette
;      registers are being consulted at all. A missing plane shows as bars in
;      eight colours repeated twice; a swapped pair shows as the right colours
;      in the wrong order. Bar 6 must be BROWN, not dark yellow -- that is the
;      one entry the default palette treats specially.
;
;    2 A BIT MASK over a solid field.
;      Vertical stripes: two pixels of the old colour, four of the new, two of
;      the old, repeating every byte. Proves the mask AND the latches together,
;      because masked-out bits come back FROM THE LATCH -- which is why each
;      write here is preceded by a read of the same address. If the latches are
;      broken the protected pixels come back as whatever was latched last,
;      usually black, and the stripes are the wrong colours rather than absent.
;
;    3 A LATCH COPY, write mode 1.
;      Copies the colour bars into the bottom of the screen, one read and one
;      write per byte, moving all four planes at once. This is what EGA
;      software scrolls with, and it is the test that fails if the latches
;      follow the CPU address instead of holding: every byte would be copied
;      to itself and the bottom of the screen would stay black.
;
;    4 A PALETTE REPROGRAM.
;      Rotates all sixteen colours by one, without touching a single pixel.
;      Proves the attribute controller -- including its single-port index/data
;      flip-flop and the reset of that flip-flop by READING 0x3DA. If the reset
;      is not implemented, the writes land alternately in the wrong registers
;      and the picture goes to nonsense colours rather than shifting cleanly.
;
;  Build:  nasm -f bin egatest.asm -o egatest.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

SEQ_IDX equ 0x3C4
SEQ_DAT equ 0x3C5
GC_IDX  equ 0x3CE
GC_DAT  equ 0x3CF
AC_PORT equ 0x3C0
STATUS  equ 0x3DA
EGABASE equ 0xA000

start:
        mov  dx, msg_intro
        call puts

        ; Does the BIOS admit to an EGA? The test is not the values it returns,
        ; it is that BL comes back CHANGED from the 0x10 passed in -- a machine
        ; with no EGA leaves it alone. This is the call Keen 4 and King's Quest
        ; make before offering their EGA modes.
        mov  ah, 0x12
        mov  bl, 0x10
        int  0x10
        cmp  bl, 0x10
        je   .noega
        mov  dx, msg_det_yes
        jmp  .det
.noega: mov  dx, msg_det_no
.det:   call puts

        ; A "b" on the command line sets the mode through INT 10h instead of by
        ; hand, which is how the BIOS path gets tested rather than assumed.
        mov  cl, [0x80]         ; PSP command-tail length
        xor  ch, ch
        mov  si, 0x81
        xor  bl, bl
.parse: jcxz .pdone
        lodsb
        or   al, 0x20
        cmp  al, 'b'
        jne  .pnext
        mov  bl, 1
.pnext: dec  cx
        jmp  .parse
.pdone: mov  [use_bios], bl

        call getkey

        cmp  byte [use_bios], 0
        je   .direct
        mov  ax, 0x000D         ; INT 10h sets it, including clearing the planes
        int  0x10
        mov  ax, EGABASE
        mov  es, ax
        cld
        jmp  .ready
.direct:
        call mode_0d
.ready:
        call bars
        call maskbars
        call latchcopy

        call getkey             ; look at it before anything moves

        call pal_rot            ; 4 -- same pixels, different colours
        call getkey
        call pal_std            ; and back
        call getkey

        ; BACK TO TEXT, AND GC 6 FIRST.
        ;
        ; INT 10h does not know this mode exists yet, so setting mode 3 alone
        ; would leave GC 6 at 0x05, EGA_ON high, and the display still scanning
        ; four bit planes -- with DOS typing into a text page nobody is looking
        ; at. 0x0E is alphanumeric with the window back at 0xB8000, which is
        ; what the BIOS's own mode set will assume when it clears the screen.
        ;
        ; When INT 10h learns mode 0Dh it will have to write this register on
        ; every mode set for the same reason.
        mov  ax, 0x060E
        call gc_set
        mov  ax, 0x0003         ; now the BIOS can clear a screen we can see
        int  0x10
        mov  dx, msg_done
        call puts
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
;  Mode 0Dh, by hand.
;
;  GC 6 is the register that decides what this card IS. Bit 0 selects graphics
;  over alphanumeric, and bits 3:2 select the host window: 01 means 0xA0000 for
;  64 KB. 0x05 is both, and it is what makes the display switch -- there is no
;  private "EGA on" bit on this board any more than there is on a real card.
; ---------------------------------------------------------------------------
mode_0d:
        mov  ax, 0x0000         ; GC 0  set/reset       = 0
        call gc_set
        mov  ax, 0x0100         ; GC 1  enable set/res  = 0
        call gc_set
        mov  ax, 0x0200         ; GC 2  colour compare  = 0
        call gc_set
        mov  ax, 0x0300         ; GC 3  rotate / func   = 0 (replace)
        call gc_set
        mov  ax, 0x0400         ; GC 4  read map        = plane 0
        call gc_set
        mov  ax, 0x0500         ; GC 5  write mode 0, read mode 0
        call gc_set
        mov  ax, 0x070F         ; GC 7  colour dont care
        call gc_set
        mov  ax, 0x08FF         ; GC 8  bit mask        = all bits
        call gc_set
        mov  ax, 0x020F         ; SEQ 2 map mask        = all four planes
        call seq_set
        mov  ax, 0x0605         ; GC 6  graphics, 0xA0000 -- LAST, it switches
        call gc_set

        call pal_std

        ; clear all four planes at once
        mov  ax, EGABASE
        mov  es, ax
        xor  di, di
        mov  cx, 8000
        xor  al, al
        cld
        rep  stosb
        ret

; ---------------------------------------------------------------------------
;  1  Sixteen colour bars, six rows each -- rows 0..95.
;
;  Write mode 2 takes the LOW NIBBLE of the CPU byte as a colour and paints all
;  eight pixels of the addressed byte with it, in one bus cycle. No read is
;  needed because the bit mask is all-ones, so nothing comes from the latches.
; ---------------------------------------------------------------------------
bars:
        mov  ax, 0x0502         ; GC 5 = write mode 2
        call gc_set
        xor  di, di
        xor  bl, bl             ; colour 0..15
.bar:   mov  cx, 6*40           ; six rows of 40 bytes
        mov  al, bl
        rep  stosb
        inc  bl
        cmp  bl, 16
        jb   .bar
        ret

; ---------------------------------------------------------------------------
;  2  Bit mask -- rows 100..139.
;
;  Fill solid blue, then paint yellow through a mask of 0x3C: bits 5,4,3,2, so
;  pixels 2..5 of every byte change and pixels 0,1,6,7 must not.
;
;  THE READ IS NOT OPTIONAL. Masked-out bits are written back from the latch,
;  not left alone, so without a read of the same address first they come back
;  holding whatever was latched last. That is the single most common way to get
;  EGA code subtly wrong, and here it would show as the wrong colour in the
;  protected pixels rather than as no change at all.
; ---------------------------------------------------------------------------
maskbars:
        mov  ax, 0x0502         ; still write mode 2
        call gc_set
        mov  di, 100*40
        mov  cx, 40*40
        mov  al, 1              ; blue
        rep  stosb

        mov  ax, 0x083C         ; GC 8 bit mask = 0x3C
        call gc_set
        mov  di, 100*40
        mov  cx, 40*40
.bm:    mov  al, [es:di]        ; read -> the latches
        mov  al, 14             ; yellow
        mov  [es:di], al        ; write -> only the masked pixels move
        inc  di
        loop .bm

        mov  ax, 0x08FF         ; put the mask back
        call gc_set
        ret

; ---------------------------------------------------------------------------
;  3  Latch copy -- rows 140..199, from the colour bars at the top.
;
;  Write mode 1 ignores the CPU data entirely and writes the latches straight
;  through to every plane the map mask allows. One read and one write move all
;  four planes, which is why EGA scrolling is fast and CGA scrolling is not.
; ---------------------------------------------------------------------------
latchcopy:
        mov  ax, 0x0501         ; GC 5 = write mode 1
        call gc_set
        xor  si, si             ; from the bars
        mov  di, 140*40
        mov  cx, 60*40
.lc:    mov  al, [es:si]        ; read  -> latches
        mov  [es:di], al        ; write -> latches to all four planes
        inc  si
        inc  di
        loop .lc
        mov  ax, 0x0500         ; back to write mode 0
        call gc_set
        ret

; ---------------------------------------------------------------------------
;  4  The palette.
;
;  pal_std writes the sixteen defaults; pal_rot writes them rotated by one, so
;  every colour on screen changes and no pixel does.
; ---------------------------------------------------------------------------
pal_std:
        xor  bl, bl             ; index
.p:     mov  al, bl
        xor  ah, ah
        mov  si, ax
        mov  al, [pal_def + si]
        mov  ah, bl
        call ac_set
        inc  bl
        cmp  bl, 16
        jb   .p
        ret

pal_rot:
        xor  bl, bl
.p:     mov  al, bl
        inc  al
        and  al, 15             ; the NEXT colour's value
        xor  ah, ah
        mov  si, ax
        mov  al, [pal_def + si]
        mov  ah, bl
        call ac_set
        inc  bl
        cmp  bl, 16
        jb   .p
        ret

; ---------------------------------------------------------------------------
;  Register helpers.  AH = index, AL = value.
; ---------------------------------------------------------------------------
seq_set:
        push dx
        push ax
        mov  dx, SEQ_IDX
        mov  al, ah
        out  dx, al
        pop  ax
        mov  dx, SEQ_DAT
        out  dx, al
        pop  dx
        ret

gc_set:
        push dx
        push ax
        mov  dx, GC_IDX
        mov  al, ah
        out  dx, al
        pop  ax
        mov  dx, GC_DAT
        out  dx, al
        pop  dx
        ret

; The attribute controller has ONE port for index and data, and which one the
; next write means is held in a flip-flop. Reading the status port resets it to
; "index". Every EGA program does this read first, precisely because it cannot
; know which half of the alternation the previous program left it in.
ac_set:
        push dx
        push ax
        mov  dx, STATUS
        in   al, dx             ; resets the index/data flip-flop
        mov  dx, AC_PORT
        pop  ax
        push ax
        mov  al, ah
        out  dx, al             ; index
        pop  ax
        out  dx, al             ; data, same port
        pop  dx
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

use_bios db 0

; ---------------------------------------------------------------------------
; The default EGA palette. Entry 6 is 0x14 and not 0x06: that is what makes
; colour 6 BROWN rather than dark yellow, the same exception the CGA palette
; carries. Every period game uses it for wood, earth and skin, so it is obvious
; on screen when it is wrong.
pal_def db 0x00,0x01,0x02,0x03,0x04,0x05,0x14,0x07
        db 0x38,0x39,0x3A,0x3B,0x3C,0x3D,0x3E,0x3F

msg_intro:
        db 'EGATEST - EGA mode 0Dh, 320x200x16, four planes at 0xA0000',13,10
        db '----------------------------------------------------------',13,10
        db 'The BIOS does not know this mode yet. This programs the',13,10
        db 'sequencer, graphics controller and attribute controller',13,10
        db 'directly, which is all a mode set is.',13,10,13,10
        db 'You should see, top to bottom:',13,10
        db '  rows   0-95   sixteen colour bars. Bar 6 must be BROWN.',13,10
        db '  rows 100-139  vertical stripes: 2 blue, 4 yellow, 2 blue,',13,10
        db '                repeating. That is the bit mask and the',13,10
        db '                latches working together.',13,10
        db '  rows 140-199  a copy of the colour bars, moved by write',13,10
        db '                mode 1. Black here means the latches do not',13,10
        db '                hold across the address change.',13,10,13,10
        db 'Then a key rotates the palette -- every colour changes and',13,10
        db 'no pixel does -- and another key puts it back.',13,10,13,10
        db 'Run as "EGATEST B" to set the mode through INT 10h instead,',13,10
        db 'which tests the BIOS rather than the hardware underneath it.',13,10,13,10
        db 'Press a key to begin.',13,10,'$'

msg_det_yes:
        db 13,10,'INT 10h AH=12h BL=10h: BL came back changed -- the BIOS',13,10
        db 'reports an EGA. Software that asks will offer its EGA modes.',13,10,'$'
msg_det_no:
        db 13,10,'INT 10h AH=12h BL=10h: BL came back as 0x10, unchanged.',13,10
        db 'The BIOS does NOT report an EGA, so software will not offer',13,10
        db 'its EGA modes however well the hardware works.',13,10,'$'

msg_done:
        db 13,10,'Back in text mode. If the bars were right but the bottom',13,10
        db 'third was black, the latches are the fault; if the stripes',13,10
        db 'were solid, the bit mask is.',13,10,'$'
