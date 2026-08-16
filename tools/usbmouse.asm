; ============================================================================
;  usbmouse.asm  --  a USB HID boot-protocol mouse, moving a cursor on screen
;
;  The first thing on this board to make a USB input device DO something. It
;  enumerates whatever is on the hybrid port, finds the boot-protocol mouse
;  interface, puts it in boot protocol, and then polls its interrupt endpoint
;  and moves a block cursor around the text screen.
;
;  Build:  nasm -f bin usbmouse.asm -o usbmouse.com
;  Usage:  usbmouse        port 1, the hybrid port
;          usbmouse 0      port 0 -- resets the fixed disk, do not use with C:
;          ESC to quit
;
;  WHY BOOT PROTOCOL. A HID device normally describes its reports with a report
;  descriptor, which is a small stack language a driver has to parse. Boot
;  protocol is the escape hatch the spec provides for exactly this situation:
;  ask for it with SET_PROTOCOL and the device promises a FIXED three-byte
;  report instead, whatever it really is underneath:
;
;      byte 0   buttons, bit 0 left, bit 1 right, bit 2 middle
;      byte 1   X movement, SIGNED, positive right
;      byte 2   Y movement, SIGNED, positive DOWN
;
;  So no report-descriptor parser is needed. A Logitech Unifying receiver
;  offers boot protocol on its mouse interface, which is what makes it a
;  reasonable first target.
;
;  NAK IS THE NORMAL ANSWER. An interrupt endpoint with nothing to say NAKs,
;  and a mouse says nothing most of the time. So the poll below must NOT use
;  the retrying transaction helper the control transfers use -- it issues one
;  IN and takes NAK as "no news". Retrying here would block for as long as the
;  budget allowed and then report a failure that is really an idle mouse.
;
;  SET_IDLE is sent for the same reason: with an idle rate of 0 the device
;  reports only when something CHANGES, instead of re-sending the same position
;  every interval. Fewer packets, and no risk of a stream of identical reports
;  being mistaken for movement.
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

; ---- register offsets from the window base ---------------------------------
O_CMD   equ 0
O_ADDR  equ 1
O_ENDP  equ 2
O_LEN   equ 3
O_DATA  equ 4
O_PTR   equ 5
O_CTRL  equ 6
O_DIAG  equ 7

BASE_P0 equ 0x00E8
BASE_P1 equ 0x00A8

OP_SETUP equ 1
OP_IN    equ 2
OP_OUT   equ 3
GO       equ 0x80
DATA1    equ 0x08

ST_BUSY  equ 0x01
ST_ACK   equ 0x02
ST_NAK   equ 0x04
ST_STALL equ 0x08
ST_TMO   equ 0x10
ST_ERR   equ 0x20
ST_RXD1  equ 0x40
ST_RXV   equ 0x80

C_RESET  equ 0x02
C_SOFEN  equ 0x04

L_FS     equ 0x04
L_LS     equ 0x08
L_LOCK   equ 0x20

D_WINDOW equ 0x0E
D_BUILD  equ 0x0F

DT_DEVICE equ 1
DT_CONFIG equ 2

VIDSEG   equ 0xB800
COLS     equ 80
ROWS     equ 25

; The cursor moves one cell per this many mouse counts. A mouse reports a few
; hundred counts per inch, so 1:1 would cross the screen on a twitch.
SENS     equ 4
MAXX     equ COLS*SENS - 1
MAXY     equ ROWS*SENS - 1

%macro SETDX 1
        mov  dx, [ubase]
        add  dl, %1
%endmacro

; ============================================================================
start:
        mov  dx, msg_hdr
        call puts

        mov  word [ubase], BASE_P1
        mov  si, 0x81
        mov  cl, [0x80]
        xor  ch, ch
        jcxz .parsed
.scan:
        lodsb
        cmp  al, '0'
        jne  .s1
        mov  word [ubase], BASE_P0
.s1:
        loop .scan
.parsed:

; ---------------- is the right engine there? --------------------------------
        mov  al, D_BUILD
        SETDX O_DIAG
        out  dx, al
        in   al, dx
        cmp  al, 0xA5
        je   .sig_ok
        mov  dx, msg_nosig
        call puts
        jmp  quit
.sig_ok:
        mov  al, D_WINDOW
        SETDX O_DIAG
        out  dx, al
        in   al, dx
        mov  bl, al
        mov  ax, [ubase]
        cmp  al, bl
        je   .win_ok
        mov  dx, msg_wrongwin
        call puts
        jmp  quit
.win_ok:
        SETDX O_CTRL
        in   al, dx
        test al, L_LOCK
        jnz  .pll_ok
        mov  dx, msg_nopll
        call puts
        jmp  quit
.pll_ok:
        test al, L_FS
        jnz  .dev_ok
        test al, L_LS
        jz   .nodev
        mov  dx, msg_ls
        call puts
        jmp  quit
.nodev:
        mov  dx, msg_nodev
        call puts
        jmp  quit
.dev_ok:

; ---------------- reset, SOF ------------------------------------------------
        SETDX O_CTRL
        mov  al, C_RESET
        out  dx, al
        call delay_tick
        SETDX O_CTRL
        xor  al, al
        out  dx, al
        call delay_tick
        SETDX O_CTRL
        mov  al, C_SOFEN
        out  dx, al

; ---------------- enumerate -------------------------------------------------
        xor  al, al
        SETDX O_ADDR
        out  dx, al
        mov  byte [ep0max], 8

        mov  si, sp_getdev8
        mov  di, devbuf
        push ds
        pop  es
        mov  cx, 8
        call ctl_xfer
        jc   .enum_bad
        mov  al, [devbuf+7]
        mov  [ep0max], al

        mov  si, sp_setaddr
        mov  di, devbuf
        xor  cx, cx
        call ctl_xfer
        jc   .enum_bad
        mov  al, 1
        SETDX O_ADDR
        out  dx, al
        call delay_tick

        mov  si, sp_getcfg9
        mov  di, cfgbuf
        mov  cx, 9
        call ctl_xfer
        jc   .enum_bad
        mov  ax, [cfgbuf+2]
        cmp  ax, CFGMAX
        jbe  .fits
        mov  ax, CFGMAX
.fits:
        mov  [cfglen], ax
        mov  [sp_getcfgn+6], ax
        mov  si, sp_getcfgn
        mov  di, cfgbuf
        mov  cx, [cfglen]
        call ctl_xfer
        jc   .enum_bad
        mov  al, [cfgbuf+5]             ; bConfigurationValue
        mov  [cfgval], al
        jmp  short .enum_ok
.enum_bad:
        mov  dx, msg_enumfail
        call puts
        jmp  quit
.enum_ok:

; ---------------- find the boot mouse ---------------------------------------
        call find_mouse
        jnc  .got_mouse
        mov  dx, msg_nomouse
        call puts
        jmp  quit
.got_mouse:

; ---------------- configure it ----------------------------------------------
        mov  al, [cfgval]
        mov  [sp_setcfg+2], al
        mov  si, sp_setcfg
        mov  di, devbuf
        xor  cx, cx
        call ctl_xfer
        jc   .cfg_bad
        call delay_tick

        ; SET_IDLE(0) and SET_PROTOCOL(boot) both address the INTERFACE, so
        ; wIndex carries its number -- sending them to interface 0 by accident
        ; configures the keyboard and leaves the mouse in report protocol.
        mov  al, [mouse_if]
        mov  [sp_setidle+4], al
        mov  si, sp_setidle
        mov  di, devbuf
        xor  cx, cx
        call ctl_xfer           ; a STALL here is survivable, so ignore CF

        mov  al, [mouse_if]
        mov  [sp_setproto+4], al
        mov  si, sp_setproto
        mov  di, devbuf
        xor  cx, cx
        call ctl_xfer
        jnc  .proto_ok
.cfg_bad:
        mov  dx, msg_cfgfail
        call puts
        jmp  quit
.proto_ok:

; ---------------- report what we found --------------------------------------
        mov  dx, msg_found
        call puts
        mov  al, [mouse_if]
        call putdec
        mov  dx, msg_onep
        call puts
        mov  al, [mouse_ep]
        call puthex
        mov  dx, msg_every
        call puts
        mov  al, [mouse_int]
        call putdec
        mov  dx, msg_msrun
        call puts

; ---------------- poll ------------------------------------------------------
        mov  al, [mouse_ep]
        and  al, 0x0F
        SETDX O_ENDP
        out  dx, al

        mov  word [accx], (COLS/2)*SENS
        mov  word [accy], (ROWS/2)*SENS
        call cursor_draw

.loop:
        ; Pace on the 1 ms frame counter rather than spinning flat out: the
        ; bus clock is programmable, so a delay loop is a different rate at
        ; every speed step, and hammering the endpoint just multiplies NAKs.
        SETDX O_DIAG
        xor  al, al
        out  dx, al
        in   al, dx
        cmp  al, [lastframe]
        je   .keys
        mov  [lastframe], al

        call poll_in
        jc   .keys                      ; NAK or nothing: not an error

        ; A boot report is 3 bytes. Anything shorter is not one.
        SETDX O_LEN
        in   al, dx
        cmp  al, 3
        jb   .keys

        call setptr
        SETDX O_DATA
        in   al, dx
        mov  [btns], al
        in   al, dx
        mov  [dxb], al
        in   al, dx
        mov  [dyb], al

        call cursor_erase

        mov  al, [dxb]
        cbw                             ; SIGNED: 0xFF is -1, not +255
        add  ax, [accx]
        or   ax, ax
        jns  .xlo
        xor  ax, ax
.xlo:
        cmp  ax, MAXX
        jbe  .xok
        mov  ax, MAXX
.xok:
        mov  [accx], ax

        mov  al, [dyb]
        cbw
        add  ax, [accy]
        or   ax, ax
        jns  .ylo
        xor  ax, ax
.ylo:
        cmp  ax, MAXY
        jbe  .yok
        mov  ax, MAXY
.yok:
        mov  [accy], ax

        call cursor_draw
        call show_status

.keys:
        mov  ah, 1
        int  0x16
        jz   .loop
        xor  ah, ah
        int  0x16
        cmp  al, 27
        jne  .loop

        call cursor_erase
        mov  dx, msg_bye
        call puts
quit:
        mov  ah, 0x4C
        xor  al, al
        int  0x21

; ============================================================================
;  find_mouse -- walk the configuration for a boot-protocol mouse interface
;                and the interrupt IN endpoint that belongs to it.
;
;  The chain is a linked list by bLength, and a HID descriptor sits between an
;  interface and its endpoints, so a fixed stride would read the HID
;  descriptor where it expected the endpoint. Follow bLength.
;
;  "Belongs to it" matters on a composite device: a Unifying receiver has
;  three interfaces, and the endpoint that follows interface 1 is the mouse's
;  while the one following interface 0 is the keyboard's. So the endpoint is
;  only taken while the last interface seen was the mouse.
;  Returns CF set if not found.
; ============================================================================
find_mouse:
        push si
        push cx
        mov  byte [in_mouse], 0
        mov  si, cfgbuf
        mov  cx, [cfglen]
.walk:
        cmp  cx, 2
        jb   .none
        mov  al, [si]
        or   al, al
        jz   .none                      ; a zero length would never terminate
        mov  bl, [si+1]
        cmp  bl, 4
        je   .iface
        cmp  bl, 5
        je   .endp
        jmp  short .next
.iface:
        mov  byte [in_mouse], 0
        cmp  byte [si+5], 3             ; bInterfaceClass = HID
        jne  .next
        cmp  byte [si+6], 1             ; bInterfaceSubClass = boot
        jne  .next
        cmp  byte [si+7], 2             ; bInterfaceProtocol = mouse
        jne  .next
        mov  byte [in_mouse], 1
        mov  al, [si+2]
        mov  [mouse_if], al
        jmp  short .next
.endp:
        cmp  byte [in_mouse], 1
        jne  .next
        mov  al, [si+2]
        test al, 0x80                   ; IN only
        jz   .next
        mov  [mouse_ep], al
        mov  al, [si+6]
        mov  [mouse_int], al
        pop  cx
        pop  si
        clc
        ret
.next:
        mov  al, [si]
        xor  ah, ah
        add  si, ax
        sub  cx, ax
        ja   .walk
.none:
        pop  cx
        pop  si
        stc
        ret

; ============================================================================
;  poll_in -- ONE interrupt IN transaction. CF set means "no report", which
;             includes NAK and is the normal case for an idle mouse.
; ============================================================================
poll_in:
        push dx
        call setptr
        mov  al, OP_IN | GO
        SETDX O_CMD
        out  dx, al
        call wait_done
        jc   .no
        test al, ST_RXV
        jz   .no
        call setptr
        pop  dx
        clc
        ret
.no:
        pop  dx
        stc
        ret

; ============================================================================
;  ctl_xfer -- a complete control transfer. Same shape as usbenum's, including
;              the short-packet rule: the data stage ends on a packet shorter
;              than THIS ENDPOINT's max, not shorter than 64. See docs/gotchas.
; ============================================================================
ctl_xfer:
        push ax
        push bx
        push dx
        push si
        push di
        push bp
        mov  bp, cx
        mov  al, [si]
        mov  [reqtype], al
        xor  al, al
        SETDX O_ENDP
        out  dx, al
        call setptr
        mov  cx, 8
        SETDX O_DATA
.fill:
        lodsb
        out  dx, al
        loop .fill
        mov  al, 8
        SETDX O_LEN
        out  dx, al
        mov  al, OP_SETUP | GO
        call txn
        jc   .bad
        test al, ST_ACK
        jz   .bad
        xor  bx, bx
        test bp, bp
        jz   .status
.data:
        call setptr
        mov  al, OP_IN | GO
        call txn
        jc   .bad
        test al, ST_RXV
        jz   .bad
        SETDX O_LEN
        in   al, dx
        xor  ah, ah
        mov  cx, ax
        jcxz .status
        push cx
        call setptr
        SETDX O_DATA
.copy:
        in   al, dx
        stosb
        inc  bx
        loop .copy
        pop  cx
        mov  al, [ep0max]
        xor  ah, ah
        cmp  cx, ax
        jb   .status
        cmp  bx, bp
        jb   .data
.status:
        push bx
        call setptr
        xor  al, al
        SETDX O_LEN
        out  dx, al
        mov  al, [reqtype]
        test al, 0x80
        jz   .st_in
        mov  al, OP_OUT | GO | DATA1
        jmp  short .st_go
.st_in:
        mov  al, OP_IN | GO | DATA1
.st_go:
        call txn
        pop  bx
        jc   .bad
        mov  cx, bx
        clc
        jmp  short .out
.bad:
        xor  cx, cx
        stc
.out:
        pop  bp
        pop  di
        pop  si
        pop  dx
        pop  bx
        pop  ax
        ret

; txn -- retrying transaction, for CONTROL transfers only. NAK is flow control
;        and gets retried; a lost packet gets a few goes; STALL is a refusal.
txn:
        push bx
        push cx
        push dx
        mov  bl, al
        mov  bh, 3
.attempt:
        mov  cx, 400
.try:
        push cx
        mov  al, bl
        SETDX O_CMD
        out  dx, al
        call wait_done
        pop  cx
        jc   .fail
        test al, ST_NAK
        jz   .settled
        loop .try
        jmp  short .fail
.settled:
        test al, ST_STALL
        jnz  .fail
        test al, ST_ERR | ST_TMO
        jz   .ok
        dec  bh
        jnz  .attempt
        jmp  short .fail
.ok:
        clc
        jmp  short .txout
.fail:
        stc
.txout:
        pop  dx
        pop  cx
        pop  bx
        ret

wait_done:
        push cx
        push dx
        mov  cx, 0
.wd:
        SETDX O_CMD
        in   al, dx
        test al, ST_BUSY
        jz   .ok
        loop .wd
        stc
        jmp  short .out
.ok:
        clc
.out:
        pop  dx
        pop  cx
        ret

setptr:
        push ax
        push dx
        xor  al, al
        SETDX O_PTR
        out  dx, al
        pop  dx
        pop  ax
        ret

; delay_tick: up to 55 ms, from the 18.2 Hz BIOS tick. Clock-independent,
;             which a spin loop is not on a board with a programmable clock.
delay_tick:
        push ax
        push bx
        push cx
        push es
        xor  ax, ax
        mov  es, ax
        mov  bx, [es:0x46C]
        mov  cx, 0
.l:
        mov  ax, [es:0x46C]
        cmp  ax, bx
        jne  .out
        loop .l
.out:
        pop  es
        pop  cx
        pop  bx
        pop  ax
        ret

; ============================================================================
;  the cursor -- an inverted cell, written straight to video memory
; ============================================================================
; cell_off: AX = byte offset of the ATTRIBUTE at (accx,accy)
cell_off:
        push bx
        push cx
        push dx
        mov  ax, [accy]
        mov  cl, 2                      ; /SENS. Shift by CL: an immediate > 1
        shr  ax, cl                     ; is 80186+, see docs/gotchas.md
        mov  bx, COLS*2
        mul  bx
        mov  bx, ax
        mov  ax, [accx]
        shr  ax, cl
        shl  ax, 1
        add  ax, bx
        inc  ax                         ; attribute byte, not the character
        pop  dx
        pop  cx
        pop  bx
        ret

cursor_draw:
        push ax
        push bx
        push es
        mov  ax, VIDSEG
        mov  es, ax
        call cell_off
        mov  bx, ax
        mov  [curoff], bx
        mov  al, [es:bx]
        mov  [curattr], al              ; remember what was there
        ; Highlight. Left button held paints it red so the button is visible
        ; without having to read the status line.
        mov  al, [btns]
        test al, 1
        jz   .plain
        mov  al, 0x4F                   ; white on red
        jmp  short .put
.plain:
        mov  al, [curattr]
        xor  al, 0x77                   ; swap foreground and background
.put:
        mov  [es:bx], al
        pop  es
        pop  bx
        pop  ax
        ret

cursor_erase:
        push ax
        push bx
        push es
        mov  ax, VIDSEG
        mov  es, ax
        mov  bx, [curoff]
        mov  al, [curattr]
        mov  [es:bx], al
        pop  es
        pop  bx
        pop  ax
        ret

; show_status: X, Y and the button byte on the top line, written directly so
;              the poll loop never leaves for DOS.
show_status:
        push ax
        push bx
        push cx                         ; the shifts below need CL
        push es
        mov  ax, VIDSEG
        mov  es, ax
        mov  bx, 2*66
        mov  ax, [accx]
        mov  cl, 2
        shr  ax, cl
        call put2
        mov  al, ','
        call putc
        mov  ax, [accy]
        mov  cl, 2
        shr  ax, cl
        call put2
        mov  al, ' '
        call putc
        mov  al, [btns]
        call puthexv
        pop  es
        pop  cx
        pop  bx
        pop  ax
        ret

; put2: AL as two decimal digits at ES:BX, advancing BX
put2:
        push ax
        push dx
        xor  ah, ah
        mov  dl, 10
        div  dl
        add  al, '0'
        call putc
        mov  al, ah
        add  al, '0'
        call putc
        pop  dx
        pop  ax
        ret

; putc: AL to ES:BX with a normal attribute, advancing BX
putc:
        mov  [es:bx], al
        inc  bx
        mov  byte [es:bx], 0x0F
        inc  bx
        ret

; puthexv: AL as two hex digits, to video
puthexv:
        push ax
        push cx
        push ax
        mov  cl, 4
        shr  al, cl
        call .n
        pop  ax
        and  al, 0x0F
        call .n
        pop  cx
        pop  ax
        ret
.n:
        and  al, 0x0F
        cmp  al, 10
        jb   .d
        add  al, 'A'-10
        jmp  short .w
.d:     add  al, '0'
.w:     call putc
        ret

; ============================================================================
;  DOS output helpers
; ============================================================================
puts:
        push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthex:
        push ax
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
.nib:
        and  al, 0x0F
        cmp  al, 10
        jb   .n0
        add  al, 'A'-10
        jmp  short .n1
.n0:    add  al, '0'
.n1:    mov  dl, al
        mov  ah, 2
        int  0x21
        ret

putdec:
        push ax
        push bx
        push cx
        push dx
        xor  ah, ah
        mov  bl, 10
        xor  cx, cx
.div:
        xor  ah, ah
        div  bl
        push ax
        inc  cx
        or   al, al
        jnz  .div
.emit:
        pop  ax
        mov  dl, ah
        add  dl, '0'
        mov  ah, 2
        int  0x21
        loop .emit
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ============================================================================
;  data
; ============================================================================
CFGMAX  equ 256

ubase     dw BASE_P1
ep0max    db 8
reqtype   db 0
cfglen    dw 0
cfgval    db 1
mouse_if  db 0
mouse_ep  db 0
mouse_int db 0
in_mouse  db 0
lastframe db 0
accx      dw 0
accy      dw 0
curoff    dw 0
curattr   db 0x07
btns      db 0
dxb       db 0
dyb       db 0

sp_getdev8   db 0x80, 6, 0x00, DT_DEVICE, 0, 0, 8, 0
sp_setaddr   db 0x00, 5, 1, 0, 0, 0, 0, 0
sp_getcfg9   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 9, 0
sp_getcfgn   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 0, 0
sp_setcfg    db 0x00, 9, 1, 0, 0, 0, 0, 0
; class requests to the interface: bmRequestType 0x21. Byte 4 is wIndex low,
; patched with the mouse's interface number before each is sent.
sp_setidle   db 0x21, 0x0A, 0x00, 0x00, 0, 0, 0, 0
sp_setproto  db 0x21, 0x0B, 0x00, 0x00, 0, 0, 0, 0

msg_hdr      db 'USBMOUSE -- HID boot mouse on the hybrid port', 13, 10, '$'
msg_nosig    db 'No A5 build signature: the bitstream is not this design.', 13, 10, '$'
msg_wrongwin db 'The engine reports a different I/O window.', 13, 10, '$'
msg_nopll    db 'The 48 MHz PLL is not locked.', 13, 10, '$'
msg_nodev    db 'Nothing plugged in (both lines low).', 13, 10, '$'
msg_ls       db 'A LOW-speed device: this engine is full-speed only.', 13, 10, '$'
msg_enumfail db 'Enumeration failed.', 13, 10, '$'
msg_nomouse  db 'No boot-protocol mouse interface on this device.', 13, 10, '$'
msg_cfgfail  db 'SET_CONFIGURATION or SET_PROTOCOL failed.', 13, 10, '$'
msg_found    db 'Boot mouse on interface ', '$'
msg_onep     db ', endpoint ', '$'
msg_every    db ', every ', '$'
msg_msrun    db ' ms.', 13, 10, 'Move the mouse. ESC quits.', 13, 10, '$'
msg_bye      db 13, 10, 'Stopped.', 13, 10, '$'

devbuf  times 20 db 0
cfgbuf  times CFGMAX db 0
