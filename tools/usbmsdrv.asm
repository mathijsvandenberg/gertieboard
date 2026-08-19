; ============================================================================
;  usbmsdrv.asm  --  INT 33h mouse driver for a USB HID boot mouse, on IRQ2
;
;  A resident driver, so ordinary DOS software can use the mouse. usbmouse.com
;  proved the path; this makes it available to everything else.
;
;  Build:  nasm -f bin usbmsdrv.asm -o usbmsdrv.com
;  Usage:  usbmsdrv          install on port 1
;          usbmsdrv /u       uninstall
;
;  WHY IRQ2 AND NOT THE TIMER. The obvious way to poll a mouse from DOS is to
;  hook INT 08h, and it is the wrong way here: PIT channel 0 is reprogrammed by
;  any game that wants its own tick rate, so a driver hanging off it silently
;  changes rate or stops -- on exactly the software anyone would want a mouse
;  for. usb_host raises IRQ2 every 8th USB frame instead (125 Hz, CTRL bit 3),
;  a clock nothing in software can touch. IRQ2 is free on a PC/XT: it is the AT
;  that uses it as the slave-PIC cascade.
;
;  WHAT THE ISR MAY DO. It runs 125 times a second inside whatever DOS was
;  doing, so it does no DOS calls, takes no locks and never blocks: one IN
;  transaction, and NAK -- the usual answer from an idle mouse -- is taken as
;  "no news" rather than retried. See poll_in.
;
;  COORDINATES. INT 33h speaks in virtual pixels, 8 per text cell, so a driver
;  that reports cells directly puts every application's cursor in column 10.
;  Position is kept in virtual pixels (0..639, 0..199) and only divided by 8
;  when the character cell is needed.
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

O_CMD   equ 0
O_ADDR  equ 1
O_ENDP  equ 2
O_LEN   equ 3
O_DATA  equ 4
O_PTR   equ 5
O_CTRL  equ 6
O_DIAG  equ 7

BASE_P1 equ 0x00A8

OP_SETUP equ 1
OP_IN    equ 2
GO       equ 0x80
DATA1    equ 0x08

ST_BUSY  equ 0x01
ST_ACK   equ 0x02
ST_NAK   equ 0x04
ST_STALL equ 0x08
ST_TMO   equ 0x10
ST_ERR   equ 0x20
ST_RXV   equ 0x80

C_RESET  equ 0x02
C_SOFEN  equ 0x04
C_IRQEN  equ 0x08
C_LOWSP  equ 0x10

L_FS     equ 0x04
L_LS     equ 0x08
L_LOCK   equ 0x20

D_BUILD  equ 0x0F

DT_DEVICE equ 1
DT_CONFIG equ 2

PIC_CMD  equ 0x20
PIC_MSK  equ 0x21
IRQ2_BIT equ 0x04               ; mask bit for IRQ2
VEC_IRQ2 equ 0x0A               ; IRQ2 -> INT 0Ah on an XT

VIDSEG   equ 0xB800
COLS     equ 80
ROWS     equ 25
MAXVX    equ COLS*8 - 1         ; virtual pixels, 8 per cell
MAXVY    equ ROWS*8 - 1

%macro SETDX 1
        mov  dx, [cs:ubase]
        add  dl, %1
%endmacro

; ============================================================================
;  RESIDENT PART.  Everything above end_resident stays in memory.
; ============================================================================
start:
        jmp  install

; ---- resident data ---------------------------------------------------------
ubase     dw BASE_P1
; RESIDENT, not transient: it is ORed into the CTRL value the engine keeps
; running with, so it describes the port for as long as the driver is loaded.
spdbit    db 0                  ; 0 or C_LOWSP
ep0max    db 8
reqtype   db 0
mouse_ep  db 0
posx      dw (COLS*8)/2
posy      dw (ROWS*8)/2
mickx     dw 0                  ; motion counters for INT 33h AX=0Bh
micky     dw 0
btns      db 0
visible   db 0                  ; cursor drawn?
curoff    dw 0
curattr   db 0x07
drawn     db 0
inisr     db 0                  ; re-entry guard
old33_o   dw 0
old33_s   dw 0
old0a_o   dw 0
old0a_s   dw 0

; ============================================================================
;  INT 33h -- the driver interface.
;
;  Only the functions DOS software actually leans on. An unknown function
;  RETURNS rather than chaining: this is the driver, there is nothing behind
;  it, and passing an unknown call to whatever occupied the vector before
;  installation would be worse than ignoring it.
; ============================================================================
int33:
        sti
        cmp  ax, 0
        je   .reset
        cmp  ax, 1
        je   .show
        cmp  ax, 2
        je   .hide
        cmp  ax, 3
        je   .getpos
        cmp  ax, 4
        je   .setpos
        cmp  ax, 11
        je   .motion
        iret

.reset:
        mov  ax, 0xFFFF         ; installed
        mov  bx, 3              ; three buttons
        mov  word [cs:posx], (COLS*8)/2
        mov  word [cs:posy], (ROWS*8)/2
        mov  word [cs:mickx], 0
        mov  word [cs:micky], 0
        call cur_hide
        mov  byte [cs:visible], 0
        iret

.show:
        mov  byte [cs:visible], 1
        call cur_draw
        iret

.hide:
        call cur_hide
        mov  byte [cs:visible], 0
        iret

.getpos:
        mov  cx, [cs:posx]
        mov  dx, [cs:posy]
        mov  bl, [cs:btns]
        and  bl, 7              ; boot protocol puts L/R/M in bits 0..2, which
        xor  bh, bh             ; is already INT 33h's layout
        iret

.setpos:
        call cur_hide
        mov  [cs:posx], cx
        mov  [cs:posy], dx
        cmp  byte [cs:visible], 0
        je   .sp_out
        call cur_draw
.sp_out:
        iret

.motion:
        ; Reading the counters CLEARS them -- that is the contract, and a
        ; driver that leaves them accumulating makes every caller drift.
        mov  cx, [cs:mickx]
        mov  dx, [cs:micky]
        mov  word [cs:mickx], 0
        mov  word [cs:micky], 0
        iret

; ============================================================================
;  INT 0Ah -- IRQ2, every 8th USB frame.
; ============================================================================
irq2:
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push ds
        push es
        push cs
        pop  ds

        ; A transaction takes tens of microseconds and the interrupt is 8 ms
        ; away, so this cannot normally re-enter -- but "normally" is doing a
        ; lot of work in a driver that runs inside arbitrary software, and the
        ; cost of the guard is one byte.
        cmp  byte [cs:inisr], 0
        jne  .done
        mov  byte [cs:inisr], 1

        call poll_in
        jc   .clear

        SETDX O_LEN
        in   al, dx
        cmp  al, 3
        jb   .clear

        call setptr
        SETDX O_DATA
        in   al, dx
        mov  [cs:btns], al
        in   al, dx
        mov  bl, al             ; dx byte
        in   al, dx
        mov  bh, al             ; dy byte

        cmp  byte [cs:visible], 0
        je   .nohide
        call cur_hide
.nohide:
        mov  al, bl
        cbw                     ; SIGNED. 0xFF is -1, not +255.
        add  [cs:mickx], ax
        add  ax, [cs:posx]
        or   ax, ax
        jns  .xl
        xor  ax, ax
.xl:    cmp  ax, MAXVX
        jbe  .xk
        mov  ax, MAXVX
.xk:    mov  [cs:posx], ax

        mov  al, bh
        cbw
        add  [cs:micky], ax
        add  ax, [cs:posy]
        or   ax, ax
        jns  .yl
        xor  ax, ax
.yl:    cmp  ax, MAXVY
        jbe  .yk
        mov  ax, MAXVY
.yk:    mov  [cs:posy], ax

        cmp  byte [cs:visible], 0
        je   .clear
        call cur_draw

.clear:
        mov  byte [cs:inisr], 0
.done:
        mov  al, 0x20           ; EOI. Without it nothing else interrupts again.
        out  PIC_CMD, al
        pop  es
        pop  ds
        pop  di
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        iret

; ============================================================================
;  the software cursor -- an inverted cell in text mode
; ============================================================================
cur_draw:
        push ax
        push bx
        push cx
        push es
        cmp  byte [cs:drawn], 0
        jne  .out
        mov  ax, VIDSEG
        mov  es, ax
        call cur_off            ; -> BX
        mov  [cs:curoff], bx
        mov  al, [es:bx]
        mov  [cs:curattr], al
        mov  al, [cs:btns]
        test al, 1
        jz   .plain
        mov  al, 0x4F           ; left button held: white on red
        jmp  short .put
.plain:
        mov  al, [cs:curattr]
        xor  al, 0x77           ; swap foreground and background
.put:
        mov  [es:bx], al
        mov  byte [cs:drawn], 1
.out:
        pop  es
        pop  cx
        pop  bx
        pop  ax
        ret

cur_hide:
        push ax
        push bx
        push es
        cmp  byte [cs:drawn], 0
        je   .out
        mov  ax, VIDSEG
        mov  es, ax
        mov  bx, [cs:curoff]
        mov  al, [cs:curattr]
        mov  [es:bx], al
        mov  byte [cs:drawn], 0
.out:
        pop  es
        pop  bx
        pop  ax
        ret

; cur_off: BX = offset of the ATTRIBUTE byte for the current position
cur_off:
        push ax
        push dx
        mov  ax, [cs:posy]
        mov  cl, 3
        shr  ax, cl             ; /8 -> row. Shift by CL: an immediate > 1 is
        mov  dx, COLS*2         ; 80186+, see docs/gotchas.md
        mul  dx
        mov  bx, ax
        mov  ax, [cs:posx]
        mov  cl, 3
        shr  ax, cl             ; /8 -> column
        shl  ax, 1
        add  bx, ax
        inc  bx                 ; attribute, not character
        pop  dx
        pop  ax
        ret

; ============================================================================
;  device access -- shared by the ISR and by installation
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

setptr:
        push ax
        push dx
        xor  al, al
        SETDX O_PTR
        out  dx, al
        pop  dx
        pop  ax
        ret

wait_done:
        push cx
        push dx
        ; BOUNDED, and much tighter than the standalone tools use. This runs
        ; inside the IRQ2 handler with interrupts still disabled, so a wedged
        ; engine would hold the whole machine off for as long as this loop
        ; lasts -- the diagnostic tools can afford a 65536 count because
        ; nothing else is waiting on them, and a driver cannot. A transaction
        ; needs tens of microseconds; 1024 iterations is ~50x that even at the
        ; slowest bus clock, and bounds the damage at a few milliseconds.
        mov  cx, 1024
.l:
        SETDX O_CMD
        in   al, dx
        test al, ST_BUSY
        jz   .ok
        loop .l
        stc
        jmp  short .out
.ok:
        clc
.out:
        pop  dx
        pop  cx
        ret

ctl_xfer:
        push ax
        push bx
        push dx
        push si
        push di
        push bp
        mov  bp, cx
        mov  al, [si]
        mov  [cs:reqtype], al
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
        ; short packet = shorter than THIS endpoint's max, not shorter than 64
        mov  al, [cs:ep0max]
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
        mov  al, [cs:reqtype]
        test al, 0x80
        jz   .st_in
        mov  al, 3 | GO | DATA1         ; OUT
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

txn:
        push bx
        push cx
        push dx
        mov  bl, al
        mov  bh, 3
.attempt:
        mov  cx, 8000                   ; NAK budget: a NAK is flow
                                        ; control, not an error. 400 was a
                                        ; few ms, tuned on devices that answer
                                        ; at once
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

end_resident:

; ============================================================================
;  TRANSIENT PART.  Discarded once the driver is resident.
; ============================================================================
install:
        mov  dx, msg_hdr
        call puts

        ; /u ?
        mov  si, 0x81
        mov  cl, [0x80]
        xor  ch, ch
        jcxz .noarg
.scan:
        lodsb
        cmp  al, 'u'
        je   uninstall
        cmp  al, 'U'
        je   uninstall
        loop .scan
.noarg:

        ; already installed? INT 33h AX=0 answering FFFF means someone is there
        mov  ax, 0x3533
        int  0x21
        mov  ax, es
        or   ax, bx
        jz   .not_yet
        mov  ax, 0
        int  0x33
        cmp  ax, 0xFFFF
        jne  .not_yet
        mov  dx, msg_already
        call puts
        jmp  bail
.not_yet:

        mov  al, D_BUILD
        SETDX O_DIAG
        out  dx, al
        in   al, dx
        cmp  al, 0xA5
        je   .sig_ok
        mov  dx, msg_nosig
        call puts
        jmp  bail
.sig_ok:
                ; CLEAR THE SPEED BIT BEFORE LOOKING AT THE LINE.
        ; CTRL persists across programs, and LINE reports the ENGINE's view of
        ; the pins -- which low-speed mode SWAPS. So if any earlier tool left
        ; bit 4 set, a low-speed device reads back here as "D+ high, full
        ; speed", and this would then drive a 1.5 Mbps device at 12. That is a
        ; TIMEOUT on the very first descriptor request, with nothing to suggest
        ; the speed was the problem.
        SETDX O_CTRL
        xor  al, al
        out  dx, al
        SETDX O_CTRL
        in   al, dx
        test al, L_LOCK
        jnz  .pll_ok
        mov  dx, msg_nopll
        call puts
        jmp  bail
.pll_ok:
        test al, L_FS
        jnz  .dev_ok
        test al, L_LS
        jz   .nodev
        mov  byte [spdbit], C_LOWSP     ; 1.5 Mbps device
        jmp  short .dev_ok
.nodev:
        mov  dx, msg_nodev
        call puts
        jmp  bail
.dev_ok:

        ; ---- bus reset, SOF, and let frames run before addressing it -------
        SETDX O_CTRL
        mov  al, C_RESET
        or   al, [spdbit]
        out  dx, al
        ; Two edges, not one. delay_tick waits for the BIOS tick to CHANGE,
        ; so on its own it returns after whatever is LEFT of the current tick
        ; -- 55 ms if one just passed, nearly nothing if the next is due. The
        ; 10 ms minimum SE0 the spec requires was never actually guaranteed;
        ; HID devices are forgiving enough that it never showed. Two edges
        ; guarantee one whole period, so 55 ms becomes a floor.
        mov  cx, 2
        call delay_ticks
        SETDX O_CTRL
        mov  al, [spdbit]               ; release, keep the speed selection
        out  dx, al
        ; And let it come back up. A device with a microcontroller runs a
        ; self-test before it will answer, and NAKs until it is ready -- which
        ; is the device working correctly, not failing.
        mov  cx, 6
        call delay_ticks
        SETDX O_CTRL
        mov  al, C_SOFEN
        or   al, [spdbit]
        out  dx, al
        call delay_tick

        ; ---- enumerate ------------------------------------------------------
        push ds
        pop  es
        xor  al, al
        SETDX O_ADDR
        out  dx, al
        mov  byte [ep0max], 8

        mov  si, sp_getdev8
        mov  di, devbuf
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

        mov  si, sp_getdev18
        mov  di, devbuf
        mov  cx, 18
        call ctl_xfer
        jc   .enum_bad

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
        jnc  .enum_ok
.enum_bad:
        mov  dx, msg_enumfail
        call puts
        jmp  bail
.enum_ok:
        mov  al, [cfgbuf+5]
        mov  [cfgval], al

        call find_mouse
        jnc  .got
        mov  dx, msg_nomouse
        call puts
        jmp  bail
.got:

        mov  al, [cfgval]
        mov  [sp_setcfg+2], al
        mov  si, sp_setcfg
        mov  di, devbuf
        xor  cx, cx
        call ctl_xfer
        jc   .cfg_bad
        call delay_tick

        mov  al, [mouse_if]
        mov  [sp_setidle+4], al
        mov  si, sp_setidle
        mov  di, devbuf
        xor  cx, cx
        call ctl_xfer                   ; a STALL here is survivable

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
        jmp  bail
.proto_ok:

        ; ---- point the engine at the mouse endpoint -------------------------
        mov  al, [mouse_ep]
        and  al, 0x0F
        SETDX O_ENDP
        out  dx, al

        ; ---- hook the vectors ----------------------------------------------
        ; Vectors BEFORE the interrupt is enabled, or the first IRQ2 lands on
        ; whatever happened to be in the slot.
        cli
        mov  ax, 0x3533
        int  0x21
        mov  [old33_o], bx
        mov  [old33_s], es
        mov  ax, 0x3500 + VEC_IRQ2
        int  0x21
        mov  [old0a_o], bx
        mov  [old0a_s], es

        push ds
        mov  ax, cs
        mov  ds, ax
        mov  dx, int33
        mov  ax, 0x2533
        int  0x21
        mov  dx, irq2
        mov  ax, 0x2500 + VEC_IRQ2
        int  0x21
        pop  ds

        ; ---- enable the frame interrupt and unmask IRQ2 ---------------------
        SETDX O_CTRL
        mov  al, C_SOFEN | C_IRQEN
        or   al, [cs:spdbit]            ; RESIDENT: the ISR runs at this speed
        out  dx, al
        in   al, PIC_MSK
        and  al, ~IRQ2_BIT & 0xFF
        out  PIC_MSK, al
        sti

        mov  dx, msg_ok
        call puts

        ; ---- stay resident --------------------------------------------------
        mov  dx, (end_resident - start + 0x100 + 15) / 16
        mov  ax, 0x3100
        int  0x21

; ---------------------------------------------------------------------------
uninstall:
        ; Only safe if the vectors still point at us -- something installed
        ; afterwards would be unhooked out of the chain and left dangling.
        mov  ax, 0x3533
        int  0x21
        mov  ax, es
        mov  bx, cs
        cmp  ax, bx
        je   .mine
        mov  dx, msg_notmine
        call puts
        jmp  bail
.mine:
        mov  dx, msg_uninst
        call puts
bail:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
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
        jz   .none
        mov  bl, [si+1]
        cmp  bl, 4
        je   .iface
        cmp  bl, 5
        je   .endp
        jmp  short .next
.iface:
        mov  byte [in_mouse], 0
        cmp  byte [si+5], 3
        jne  .next
        cmp  byte [si+6], 1
        jne  .next
        cmp  byte [si+7], 2
        jne  .next
        mov  byte [in_mouse], 1
        mov  al, [si+2]
        mov  [mouse_if], al
        jmp  short .next
.endp:
        cmp  byte [in_mouse], 1
        jne  .next
        mov  al, [si+2]
        test al, 0x80
        jz   .next
        mov  [mouse_ep], al
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

; delay_ticks: wait CX tick EDGES. A single edge is only the REMAINDER of the
;              current tick, so it can be almost nothing; N edges guarantee
;              (N-1) whole periods. Use this, not delay_tick, wherever a
;              MINIMUM is required rather than a nod in its direction.
delay_ticks:
        push cx
.dts_l:
        call delay_tick
        loop .dts_l
        pop  cx
        ret

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

puts:
        push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

; ---- transient data --------------------------------------------------------
CFGMAX  equ 256

cfglen    dw 0
cfgval    db 1
mouse_if  db 0
in_mouse  db 0

sp_getdev8   db 0x80, 6, 0x00, DT_DEVICE, 0, 0, 8, 0
sp_getdev18  db 0x80, 6, 0x00, DT_DEVICE, 0, 0, 18, 0
sp_setaddr   db 0x00, 5, 1, 0, 0, 0, 0, 0
sp_getcfg9   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 9, 0
sp_getcfgn   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 0, 0
sp_setcfg    db 0x00, 9, 1, 0, 0, 0, 0, 0
sp_setidle   db 0x21, 0x0A, 0x00, 0x00, 0, 0, 0, 0
sp_setproto  db 0x21, 0x0B, 0x00, 0x00, 0, 0, 0, 0

msg_hdr      db 'USBMSDRV -- INT 33h mouse on IRQ2', 13, 10, '$'
msg_nosig    db 'No A5 build signature: wrong bitstream.', 13, 10, '$'
msg_nopll    db 'The 48 MHz PLL is not locked.', 13, 10, '$'
msg_nodev    db 'Nothing plugged into the hybrid port.', 13, 10, '$'
msg_enumfail db 'Enumeration failed -- run USBENUM for detail.', 13, 10, '$'
msg_nomouse  db 'No boot-protocol mouse on this device.', 13, 10, '$'
msg_cfgfail  db 'SET_CONFIGURATION or SET_PROTOCOL failed.', 13, 10, '$'
msg_already  db 'A mouse driver is already installed.', 13, 10, '$'
msg_notmine  db 'INT 33h no longer points here -- not unhooking.', 13, 10, '$'
msg_uninst   db 'Uninstall is not implemented yet.', 13, 10, '$'
msg_ok       db 'Installed. 125 Hz on IRQ2, INT 33h ready.', 13, 10, '$'

devbuf  times 20 db 0
cfgbuf  times CFGMAX db 0
