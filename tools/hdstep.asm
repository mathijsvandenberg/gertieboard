; ============================================================================
;  hdstep.asm  --  single-step ONE INT 13h AH=08 call, with 7-seg markers
;
;  We have a contradiction: the BIOS marker says it received AH=0x08, and the
;  disassembly of that path provably writes 0xB8 before returning -- yet 0xB8
;  never appears. One of those statements has to be wrong, and the missing piece
;  is what happens on the CALLER's side.
;
;  So this does nothing but that single call, writing its own markers to port
;  0x80 (the 7-segment display) around every step. The last code shown says
;  exactly where control was lost:
;
;     11  about to enable the disk (BDA 40:75 = 1)
;     12  enabled; about to execute INT 13h AH=08
;     08  <- written by the BIOS handler on entry (raw AH)
;     B8  <- written by the BIOS .h_params just before it returns
;     13  INT 13h returned to us
;     14  finished, about to exit to DOS
;
;  Ending on 12 means the INT never reached the handler. Ending on 08 means the
;  handler was entered but died before dispatching. Ending on B8 means the BIOS
;  finished and the caller is where things break. Ending on 13/14 means the call
;  works in isolation and something in HDTEST's surroundings is at fault.
;
;  Build:  nasm -f bin hdstep.asm -o hdstep.com
; ============================================================================

        org  0x100
        bits 16

start:
        mov  dx, msg_hdr
        call puts

        mov  al, 0x11
        out  0x80, al

        push ds                     ; advertise the disk so the BIOS accepts calls
        mov  ax, 0x0040
        mov  ds, ax
        mov  byte [0x75], 1
        pop  ds

        mov  al, 0x12
        out  0x80, al

        mov  dx, msg_call
        call puts

        ; ---- the call under test, in isolation ----
        mov  ah, 0x08
        mov  dl, 0x80
        int  0x13

        ; ---- capture everything IMMEDIATELY, print later ----
        ; Doing this before any INT 21h call means the reported values are the
        ; ones the BIOS actually returned, and keeps this tool simple enough to
        ; be obviously correct -- the last thing we need is to debug the probe.
        mov  [r_ax], ax
        mov  [r_cx], cx
        mov  [r_dx], dx
        pushf
        pop  ax
        mov  [r_fl], ax

        mov  al, 0x13               ; we got control back
        out  0x80, al

        mov  dx, msg_back
        call puts

        mov  dx, msg_cf
        call puts
        mov  ax, [r_fl]
        test al, 0x01               ; CF is bit 0 of FLAGS
        jz   .cf0
        mov  dx, msg_1
        call puts
        jmp  short .regs
.cf0:   mov  dx, msg_0
        call puts
.regs:
        mov  dx, msg_ah
        call puts
        mov  ax, [r_ax]
        mov  al, ah
        call puthex8
        mov  dx, msg_ch
        call puts
        mov  ax, [r_cx]
        mov  al, ah
        call puthex8
        mov  dx, msg_cl
        call puts
        mov  ax, [r_cx]
        call puthex8
        mov  dx, msg_dh
        call puts
        mov  ax, [r_dx]
        mov  al, ah
        call puthex8
        mov  dx, msg_dl
        call puts
        mov  ax, [r_dx]
        call puthex8
        call crlf

        push ds                     ; hide the disk again
        mov  ax, 0x0040
        mov  ds, ax
        mov  byte [0x75], 0
        pop  ds

        mov  al, 0x14
        out  0x80, al

        mov  dx, msg_done
        call puts
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 0x09
        int  0x21
        pop  ax
        ret
crlf:   push dx
        mov  dx, msg_crlf
        call puts
        pop  dx
        ret
puthex8:
        push ax
        push bx
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

msg_hdr:  db 'hdstep -- one INT 13h AH=08 call, watch the 7-seg',13,10,'$'
msg_call: db 'calling AH=08 ...',13,10,'$'
msg_back: db 'returned.  $'
msg_cf:   db 'CF=$'
msg_ah:   db '  AH=$'
msg_ch:   db '  CH=$'
msg_cl:   db '  CL=$'
msg_dh:   db '  DH=$'
msg_dl:   db '  DL=$'
msg_0:    db '0$'
msg_1:    db '1$'
msg_done: db 'done.',13,10,'$'
msg_crlf: db 13,10,'$'

r_ax:     dw 0
r_cx:     dw 0
r_dx:     dw 0
r_fl:     dw 0
