; ============================================================================
;  crtctest.asm  --  can this graphics card be DETECTED?
;
;  A machine can display a perfect picture and still be told it has no graphics
;  card, because nothing detects a card by looking at the screen. The standard
;  test writes a value into a CRTC register and reads it back:
;
;      out 3D4h, 0Fh        select R15, cursor address low
;      in  al, 3D5h         what is there now
;      out 3D5h, 66h        write a pattern
;      in  al, 3D5h         does the chip remember it?
;
;  Prince of Persia does this and refuses to start when it fails. So does a lot
;  of other software, and the failure is always reported as "no graphics card",
;  which sends you looking at the video output -- the one part that was working.
;
;  On a real MC6845 the answers are asymmetric, and that asymmetry is the
;  signature being looked for:
;
;      R14/R15   cursor address    readable; R14 is 6 bits wide, R15 is 8
;      R16/R17   light pen         read only
;      R0-R13    everything else   WRITE ONLY -- they read back as 0
;
;  A register file that echoed all eighteen registers would be wrong in a way
;  that matters. So would one that returns 0xFF, which is what an unanswered
;  I/O read floats to and what this board did before crtc6845 existed.
;
;  The cursor is put back through INT 10h at the end rather than by restoring
;  what was read, because on a board that fails this test what was read is 0xFF
;  and writing it back would leave the cursor somewhere strange.
;
;  Build:  nasm -f bin crtctest.asm -o crtctest.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

start:
        mov  dx, msg_hdr
        call puts

        ; the CRTC port comes from the BDA, not a constant -- a mono card
        ; would put it at 0x3B4 and the test should follow it
        mov  ax, 0x40
        mov  es, ax
        mov  ax, [es:0x63]
        mov  [crtc], ax

        mov  dx, msg_port
        call puts
        mov  ax, [crtc]
        call puthexw
        mov  dx, msg_crlf
        call puts

        mov  ah, 3              ; remember where the cursor is
        mov  bh, 0
        int  0x10
        mov  [savcur], dx

        mov  byte [fails], 0

        ; ---- R15: eight bits, fully readable ----
        mov  bl, 0x0F
        mov  bh, 0x66
        mov  cl, 0x66
        mov  si, n_r15
        call probe

        mov  bl, 0x0F
        mov  bh, 0x99           ; a second pattern: a stuck bus can match one
        mov  cl, 0x99
        mov  si, n_r15
        call probe

        ; ---- R14: six bits, so the top two must come back clear ----
        mov  bl, 0x0E
        mov  bh, 0x66
        mov  cl, 0x26
        mov  si, n_r14
        call probe

        ; ---- R10: write-only, so it must read back as zero ----
        mov  bl, 0x0A
        mov  bh, 0x55
        mov  cl, 0x00
        mov  si, n_r10
        call probe

        ; ---- put the cursor back the tidy way ----
        mov  ah, 2
        mov  bh, 0
        mov  dx, [savcur]
        int  0x10

        mov  dx, msg_crlf
        call puts
        cmp  byte [fails], 0
        jne  .bad
        mov  dx, msg_good
        call puts
        jmp  short bye
.bad:
        mov  dx, msg_badhdr
        call puts
        cmp  byte [sawff], 0
        je   bye
        mov  dx, msg_ff
        call puts
bye:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; probe -- BL = register, BH = value to write, CL = value expected back,
;          SI = name string. Prints one line and counts failures.
probe:
        push ax
        push bx
        push cx
        push dx

        mov  dx, si             ; name
        call puts

        mov  al, bh             ; "write NN"
        call puthexb
        mov  dx, msg_arrow
        call puts

        mov  al, bl
        mov  ah, bh
        call crtc_wr
        mov  al, bl
        call crtc_rd
        mov  [got], al

        call puthexb
        mov  dx, msg_gap
        call puts

        mov  al, [got]
        cmp  al, cl
        je   .ok
        inc  byte [fails]
        cmp  al, 0xFF           ; the open-bus signature, worth calling out
        jne  .say
        mov  byte [sawff], 1
.say:
        mov  dx, msg_bad
        call puts
        jmp  short .out
.ok:
        mov  dx, msg_ok
        call puts
.out:
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; crtc_wr -- AL = register index, AH = value
crtc_wr:
        push ax
        push dx
        mov  dx, [crtc]
        out  dx, al
        inc  dx
        mov  al, ah
        out  dx, al
        pop  dx
        pop  ax
        ret

; crtc_rd -- AL = register index, returns AL = value
crtc_rd:
        push dx
        mov  dx, [crtc]
        out  dx, al
        inc  dx
        in   al, dx
        pop  dx
        ret

; ---------------------------------------------------------------------------
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
        push dx
        mov  bl, al
        mov  cl, 4
        shr  al, cl
        call .n
        mov  al, bl
        call .n
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret
.n:     and  al, 0x0F
        cmp  al, 10
        jb   .d
        add  al, 'A'-10
        jmp  short .e
.d:     add  al, '0'
.e:     mov  dl, al
        mov  ah, 2
        int  0x21
        ret

; ---------------------------------------------------------------------------
crtc    dw 0x03D4
savcur  dw 0
got     db 0
fails   db 0
sawff   db 0

msg_hdr db 'CRTCTEST - can this graphics card be detected?',13,10
        db '----------------------------------------------',13,10
        db 'Writes CRTC registers and reads them back, which is how',13,10
        db 'software decides a card is present. Nothing here looks',13,10
        db 'at the picture.',13,10,13,10,'$'
msg_port db 'CRTC index port from BDA 40:63 : $'
msg_arrow db ' -> read $'
msg_gap db '   $'
msg_ok  db 'OK',13,10,'$'
msg_bad db 'WRONG',13,10,'$'

n_r15   db '  R15 cursor low    readable   write $'
n_r14   db '  R14 cursor high   6 bits     write $'
n_r10   db '  R10 cursor start  write-only write $'

msg_good db 'The card answers for itself. Software that probes the CRTC',13,10
        db 'will find it.',13,10,'$'
msg_badhdr db 'This card cannot be detected by the usual probe.',13,10,'$'
msg_ff  db 13,10
        db 'The 0xFF readings are the giveaway: nothing is answering the',13,10
        db 'CRTC data port at all, so the read floats to open bus. Every',13,10
        db 'program that probes the CRTC will conclude there is no',13,10
        db 'graphics card -- while displaying that conclusion perfectly.',13,10,'$'
msg_crlf db 13,10,'$'
