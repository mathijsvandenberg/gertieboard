; ============================================================================
;  usbkbd.asm  --  a USB HID boot keyboard, typing into the BDA key buffer
;
;  Resident. Services the keyboard from IRQ2 at 125 Hz and pushes translated
;  keystrokes into the BIOS keyboard buffer, so DOS and every application see
;  them through INT 16h exactly as if they came from the PS/2 port.
;
;  Build:  nasm -f bin usbkbd.asm -o usbkbd.com
;  Usage:  usbkbd          install on the hybrid port
;
;  WHY INT 16h AND NOT PORT 60h. ps2_kbd_ppi owns 60h and drives IRQ1, and two
;  things feeding one port would have to arbitrate in hardware. Injecting at the
;  BUFFER means both keyboards work at once, with no hardware change and no
;  contest. The cost is that the FPGA's Ctrl+Alt+Del detector, which watches the
;  PS/2 scancode stream, cannot see this keyboard -- it is a real limitation and
;  the reset button is the answer.
;
;  A BOOT REPORT IS STATE, NOT EVENTS. Eight bytes:
;
;      byte 0    modifiers: Ctrl/Shift/Alt/GUI, left in 0..3, right in 4..7
;      byte 1    reserved
;      bytes 2-7 up to six usage codes for the keys CURRENTLY HELD, 0 = none
;
;  There is no "key went down" in that. The driver diffs each report against the
;  previous one to find new presses, and generates its own auto-repeat -- a
;  keyboard that types once and then stops while you hold a key is technically
;  correct and unusable.
;
;  CTRL WORKS HERE, which it does not on the PS/2 path: that has no Ctrl
;  translation at all, so Ctrl+C types a plain 'c'. Ctrl+letter is masked to
;  0x01..0x1A below, so Ctrl+C actually breaks a program.
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
IRQ2_BIT equ 0x04
VEC_IRQ2 equ 0x0A

BDA      equ 0x0040
KB_HEAD  equ 0x1A               ; offsets within the BDA segment
KB_TAIL  equ 0x1C
KB_BUF   equ 0x1E
KB_END   equ 0x3E
KB_FLAG  equ 0x17               ; shift/ctrl/alt state byte

; Auto-repeat, in 125 Hz interrupt ticks: ~0.5 s before the first repeat, then
; ~11/s. Close to a PC/AT's defaults, which is what fingers expect.
REP_DELAY equ 62
REP_RATE  equ 11

%macro SETDX 1
        mov  dx, [cs:ubase]
        add  dl, %1
%endmacro

; ============================================================================
;  RESIDENT
; ============================================================================
start:
        jmp  install

ubase     dw BASE_P1
spdbit    db 0
ep0max    db 8
reqtype   db 0
kbd_ep    db 0
prev      times 8 db 0          ; the last report, for the diff
lastkey   db 0                  ; usage code being repeated, 0 = none
repcnt    db 0
inisr     db 0
old09_o   dw 0
old09_s   dw 0
old0a_o   dw 0
old0a_s   dw 0

; ============================================================================
;  INT 0Ah -- IRQ2, every 8th USB frame
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

        cmp  byte [cs:inisr], 0
        jne  .done
        mov  byte [cs:inisr], 1

        call poll_in
        jc   .norep                     ; NAK: nothing new, but still repeat

        SETDX O_LEN
        in   al, dx
        cmp  al, 8
        jb   .norep                     ; not a boot report

        call setptr
        SETDX O_DATA
        mov  di, rept
        mov  cx, 8
.rd:    in   al, dx
        mov  [cs:di], al
        inc  di
        loop .rd

        call do_flags
        call do_keys
        jmp  short .clear

.norep:
        call do_repeat
.clear:
        mov  byte [cs:inisr], 0
.done:
        mov  al, 0x20
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

; ---------------------------------------------------------------------------
;  do_flags -- mirror the modifier byte into BDA 40:17.
;
;  Worth doing even though nothing here reads it back: plenty of DOS software
;  tests 40:17 directly instead of calling INT 16h AH=02, and a driver that
;  fills the buffer but leaves the flags stale makes Shift look stuck off.
; ---------------------------------------------------------------------------
do_flags:
        push ax
        push ds
        mov  al, [cs:rept]              ; HID modifier byte
        xor  ah, ah
        test al, 0x22                   ; either Shift
        jz   .nosh
        or   ah, 0x03                   ; BDA: both shift bits
.nosh:
        test al, 0x11                   ; either Ctrl
        jz   .noct
        or   ah, 0x04
.noct:
        test al, 0x44                   ; either Alt
        jz   .noal
        or   ah, 0x08
.noal:
        mov  bx, BDA
        mov  ds, bx
        mov  bl, [KB_FLAG]
        and  bl, 0xF0                   ; keep the lock bits, replace 0..3
        or   bl, ah
        mov  [KB_FLAG], bl
        pop  ds
        pop  ax
        ret

; ---------------------------------------------------------------------------
;  do_keys -- everything held now that was not held before is a new press.
; ---------------------------------------------------------------------------
do_keys:
        push ax
        push bx
        push cx
        push si
        mov  si, rept+2
        mov  cx, 6
.each:
        mov  al, [cs:si]
        or   al, al
        jz   .next                      ; empty slot
        ; was it in the previous report?
        push cx
        push si
        mov  si, prev+2
        mov  cx, 6
.look:
        cmp  al, [cs:si]
        je   .held
        inc  si
        loop .look
        pop  si
        pop  cx
        ; new press: emit it, and arm the repeat on it
        call emit
        mov  [cs:lastkey], al
        mov  byte [cs:repcnt], REP_DELAY
        jmp  short .next
.held:
        pop  si
        pop  cx
.next:
        inc  si
        loop .each

        ; If the key we were repeating is no longer held, stop repeating.
        mov  al, [cs:lastkey]
        or   al, al
        jz   .save
        push cx
        mov  si, rept+2
        mov  cx, 6
.still:
        cmp  al, [cs:si]
        je   .yes
        inc  si
        loop .still
        mov  byte [cs:lastkey], 0
.yes:
        pop  cx
.save:
        ; this report becomes the previous one
        mov  si, rept
        mov  bx, prev
        mov  cx, 8
.cp:    mov  al, [cs:si]
        mov  [cs:bx], al
        inc  si
        inc  bx
        loop .cp
        pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
;  do_repeat -- called on the ticks where the device said nothing.
;
;  A boot keyboard NAKs while nothing changes, so a held key produces exactly
;  one report and then silence. Repeat has to be generated here or holding a
;  key types once.
; ---------------------------------------------------------------------------
do_repeat:
        push ax
        mov  al, [cs:lastkey]
        or   al, al
        jz   .out
        dec  byte [cs:repcnt]
        jnz  .out
        mov  byte [cs:repcnt], REP_RATE
        call emit
.out:
        pop  ax
        ret

; ---------------------------------------------------------------------------
;  emit -- AL = HID usage code. Translate and push into the BIOS buffer.
; ---------------------------------------------------------------------------
emit:
        push ax
        push bx
        push cx
        push dx
        push ds

        cmp  al, KTAB_N
        jae  .out                       ; outside the table: no such key here
        mov  bl, al
        xor  bh, bh
        mov  ax, bx
        shl  ax, 1
        add  bx, ax                     ; bx = usage * 3
        add  bx, ktab
        mov  dh, [cs:bx]                ; scancode
        or   dh, dh
        jz   .out                       ; unmapped

        mov  al, [cs:rept]              ; modifiers
        test al, 0x22                   ; Shift?
        jz   .unshift
        mov  dl, [cs:bx+2]
        jmp  short .ctrl
.unshift:
        mov  dl, [cs:bx+1]
.ctrl:
        mov  al, [cs:rept]
        test al, 0x11                   ; Ctrl?
        jz   .push
        ; Ctrl+letter -> 0x01..0x1A. This is what makes Ctrl+C break a program
        ; rather than type a 'c', which the PS/2 path still gets wrong.
        mov  al, dl
        or   al, 0x20                   ; fold to lower case
        cmp  al, 'a'
        jb   .push
        cmp  al, 'z'
        ja   .push
        and  dl, 0x1F

.push:
        ; enqueue AH=scancode AL=ascii at 40:[tail], the standard way
        mov  ax, BDA
        mov  ds, ax
        mov  bx, [KB_TAIL]
        mov  cx, bx
        add  cx, 2
        cmp  cx, KB_END
        jb   .nowrap
        mov  cx, KB_BUF
.nowrap:
        cmp  cx, [KB_HEAD]
        je   .out                       ; full -- drop it, like the real BIOS
        mov  [bx], dl                   ; ASCII
        mov  [bx+1], dh                 ; scancode
        mov  [KB_TAIL], cx
.out:
        pop  ds
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ============================================================================
;  device access
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
        ; Bounded tightly: this runs inside the interrupt handler with
        ; interrupts still disabled, so a wedged engine would hold the machine
        ; off for the length of this loop.
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
        mov  al, 3 | GO | DATA1
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

rept    times 8 db 0            ; the report just received

; ---- HID usage -> scancode, unshifted ASCII, shifted ASCII -----------------
;  Three bytes per usage code, indexed directly. A zero scancode means "this
;  keyboard has a key there and this driver does not map it", which is a
;  deliberate no-op rather than a guess.
ktab:
        db 0,0,0,  0,0,0,  0,0,0,  0,0,0            ; 00-03
        db 0x1E,'a','A', 0x30,'b','B', 0x2E,'c','C', 0x20,'d','D'
        db 0x12,'e','E', 0x21,'f','F', 0x22,'g','G', 0x23,'h','H'
        db 0x17,'i','I', 0x24,'j','J', 0x25,'k','K', 0x26,'l','L'
        db 0x32,'m','M', 0x31,'n','N', 0x18,'o','O', 0x19,'p','P'
        db 0x10,'q','Q', 0x13,'r','R', 0x1F,'s','S', 0x14,'t','T'
        db 0x16,'u','U', 0x2F,'v','V', 0x11,'w','W', 0x2D,'x','X'
        db 0x15,'y','Y', 0x2C,'z','Z'                ; 04-1D
        db 0x02,'1','!', 0x03,'2','@', 0x04,'3','#', 0x05,'4','$'
        db 0x06,'5','%', 0x07,'6','^', 0x08,'7','&', 0x09,'8','*'
        db 0x0A,'9','(', 0x0B,'0',')'                ; 1E-27
        db 0x1C,13,13,   0x01,27,27,   0x0E,8,8,     0x0F,9,9
        db 0x39,' ',' '                              ; 28-2C
        db 0x0C,'-','_', 0x0D,'=','+', 0x1A,'[','{', 0x1B,']','}'
        db 0x2B,'\',124, 0x2B,'\',124, 0x27,';',':', 0x28,39,'"'
        db 0x29,'`','~', 0x33,',','<', 0x34,'.','>', 0x35,'/','?'
        db 0,0,0                                     ; 39 CapsLock: not handled
        db 0x3B,0,0, 0x3C,0,0, 0x3D,0,0, 0x3E,0,0    ; F1-F4
        db 0x3F,0,0, 0x40,0,0, 0x41,0,0, 0x42,0,0    ; F5-F8
        db 0x43,0,0, 0x44,0,0, 0x57,0,0, 0x58,0,0    ; F9-F12
        db 0,0,0, 0,0,0, 0,0,0                       ; 46-48 PrtSc/Scroll/Pause
        db 0x52,0,0, 0x47,0,0, 0x49,0,0              ; Insert, Home, PgUp
        db 0x53,0,0, 0x4F,0,0, 0x51,0,0              ; Delete, End, PgDn
        db 0x4D,0,0, 0x4B,0,0, 0x50,0,0, 0x48,0,0    ; Right Left Down Up
        ; ---- the keypad, 0x53-0x63 ----------------------------------------
        ; A numeric keypad sends NOTHING below 0x53, so a table that stops at
        ; the arrows drops every key on such a device and looks like a driver
        ; that installed and did nothing.
        ;
        ; These are the NumLock-ON meanings: digits and symbols. NumLock itself
        ; is not tracked yet, so the navigation alternates (KP 4 = Left and so
        ; on) are not reachable -- deliberate, because a numpad plugged into a
        ; DOS box is wanted for typing numbers, and guessing the other way round
        ; would make it useless for that.
        db 0x45,0,0                                  ; 53 Num Lock
        db 0x35,'/','/', 0x37,'*','*'                ; 54 55
        db 0x4A,'-','-', 0x4E,'+','+'                ; 56 57
        db 0x1C,13,13                                ; 58 KP Enter
        db 0x4F,'1','1', 0x50,'2','2', 0x51,'3','3'  ; 59 5A 5B
        db 0x4B,'4','4', 0x4C,'5','5', 0x4D,'6','6'  ; 5C 5D 5E
        db 0x47,'7','7', 0x48,'8','8', 0x49,'9','9'  ; 5F 60 61
        db 0x52,'0','0', 0x53,'.','.'                ; 62 63
KTAB_N  equ ($ - ktab) / 3

end_resident:

; ============================================================================
;  TRANSIENT
; ============================================================================
install:
        mov  dx, msg_hdr
        call puts

        mov  ax, 0x3500 + VEC_IRQ2
        int  0x21

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
        mov  byte [spdbit], C_LOWSP
        mov  dx, msg_ls
        call puts
        jmp  short .dev_ok
.nodev:
        mov  dx, msg_nodev
        call puts
        jmp  bail
.dev_ok:

        SETDX O_CTRL
        mov  al, C_RESET
        or   al, [spdbit]
        out  dx, al
        call delay_tick
        SETDX O_CTRL
        mov  al, [spdbit]
        out  dx, al
        call delay_tick
        SETDX O_CTRL
        mov  al, C_SOFEN
        or   al, [spdbit]
        out  dx, al
        call delay_tick

        push ds
        pop  es
        xor  al, al
        SETDX O_ADDR
        out  dx, al
        mov  byte [ep0max], 8

        mov  byte [stage], 1
        mov  si, sp_getdev8
        mov  di, devbuf
        mov  cx, 8
        call ctl_xfer
        jc   .enum_bad
        mov  al, [devbuf+7]
        mov  [ep0max], al

        mov  byte [stage], 2
        mov  si, sp_setaddr
        mov  di, devbuf
        xor  cx, cx
        call ctl_xfer
        jc   .enum_bad
        mov  al, 1
        SETDX O_ADDR
        out  dx, al
        call delay_tick

        mov  byte [stage], 3
        mov  si, sp_getdev18
        mov  di, devbuf
        mov  cx, 18
        call ctl_xfer
        jc   .enum_bad

        mov  byte [stage], 4
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
        mov  byte [stage], 5
        mov  si, sp_getcfgn
        mov  di, cfgbuf
        mov  cx, [cfglen]
        call ctl_xfer
        jnc  .enum_ok
.enum_bad:
        call fail_stage
        jmp  bail
.enum_ok:
        mov  al, [cfgbuf+5]
        mov  [cfgval], al

        call find_kbd
        jnc  .got
        mov  dx, msg_nokbd
        call puts
        jmp  bail
.got:

        mov  al, [cfgval]
        mov  [sp_setcfg+2], al
        mov  byte [stage], 6
        mov  si, sp_setcfg
        mov  di, devbuf
        xor  cx, cx
        call ctl_xfer
        jc   .cfg_bad
        call delay_tick

        mov  al, [kbd_if]
        mov  [sp_setidle+4], al
        mov  byte [stage], 7
        mov  si, sp_setidle
        mov  di, devbuf
        xor  cx, cx
        call ctl_xfer                   ; STALL here is survivable

        mov  al, [kbd_if]
        mov  [sp_setproto+4], al
        mov  byte [stage], 8
        mov  si, sp_setproto
        mov  di, devbuf
        xor  cx, cx
        call ctl_xfer
        jnc  .proto_ok
.cfg_bad:
        call fail_stage
        jmp  bail
.proto_ok:

        mov  al, [kbd_ep]
        and  al, 0x0F
        SETDX O_ENDP
        out  dx, al

        cli
        mov  ax, 0x3500 + VEC_IRQ2
        int  0x21
        mov  [old0a_o], bx
        mov  [old0a_s], es
        push ds
        mov  ax, cs
        mov  ds, ax
        mov  dx, irq2
        mov  ax, 0x2500 + VEC_IRQ2
        int  0x21
        pop  ds

        SETDX O_CTRL
        mov  al, C_SOFEN | C_IRQEN
        or   al, [spdbit]
        out  dx, al
        in   al, PIC_MSK
        and  al, ~IRQ2_BIT & 0xFF
        out  PIC_MSK, al
        sti

        mov  dx, msg_ok
        call puts
        mov  dx, (end_resident - start + 0x100 + 15) / 16
        mov  ax, 0x3100
        int  0x21

bail:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
;  find_kbd -- the boot-protocol keyboard interface and ITS interrupt endpoint.
;  Same walk as the mouse driver: follow bLength, and only take an endpoint
;  while the last interface seen was the keyboard. A keyboard commonly has a
;  second HID interface for media keys, whose endpoint is not this one.
; ---------------------------------------------------------------------------
find_kbd:
        push si
        push cx
        mov  byte [in_kbd], 0
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
        mov  byte [in_kbd], 0
        cmp  byte [si+5], 3             ; HID
        jne  .next
        cmp  byte [si+6], 1             ; boot
        jne  .next
        cmp  byte [si+7], 1             ; keyboard
        jne  .next
        mov  byte [in_kbd], 1
        mov  al, [si+2]
        mov  [kbd_if], al
        jmp  short .next
.endp:
        cmp  byte [in_kbd], 1
        jne  .next
        mov  al, [si+2]
        test al, 0x80
        jz   .next
        mov  [kbd_ep], al
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

; fail_stage -- which request, and what came back. STALL is a refusal, TIMEOUT
;               is nobody home; they point at opposite halves of the problem,
;               and "Enumeration failed" said neither.
fail_stage:
        push ax
        push bx
        mov  dx, msg_failat
        call puts
        mov  al, [stage]
        add  al, '0'
        mov  dl, al
        mov  ah, 2
        int  0x21
        mov  dx, msg_dash
        call puts
        mov  bl, [stage]
        xor  bh, bh
        dec  bx
        shl  bx, 1
        mov  dx, [stagetab+bx]
        call puts
        mov  dx, msg_status
        call puts
        SETDX O_CMD
        in   al, dx
        call puthex
        mov  dx, msg_rxpid
        call puts
        SETDX O_ENDP
        in   al, dx
        call puthex
        mov  dx, msg_crlf
        call puts
        pop  bx
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

CFGMAX  equ 256
cfglen    dw 0
cfgval    db 1
kbd_if    db 0
in_kbd    db 0
stage     db 0

sp_getdev8   db 0x80, 6, 0x00, DT_DEVICE, 0, 0, 8, 0
sp_getdev18  db 0x80, 6, 0x00, DT_DEVICE, 0, 0, 18, 0
sp_setaddr   db 0x00, 5, 1, 0, 0, 0, 0, 0
sp_getcfg9   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 9, 0
sp_getcfgn   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 0, 0
sp_setcfg    db 0x00, 9, 1, 0, 0, 0, 0, 0
sp_setidle   db 0x21, 0x0A, 0x00, 0x00, 0, 0, 0, 0
sp_setproto  db 0x21, 0x0B, 0x00, 0x00, 0, 0, 0, 0

msg_hdr      db 'USBKBD -- HID boot keyboard into the BIOS key buffer', 13, 10, '$'
msg_nosig    db 'No A5 build signature: wrong bitstream.', 13, 10, '$'
msg_nopll    db 'The 48 MHz PLL is not locked.', 13, 10, '$'
msg_nodev    db 'Nothing plugged into the hybrid port.', 13, 10, '$'
msg_ls       db 'Low-speed device (1.5 Mbps).', 13, 10, '$'
msg_failat   db 'FAILED at stage ', '$'
msg_dash     db ' -- ', '$'
msg_status   db '   status ', '$'
msg_rxpid    db '  rxpid ', '$'
msg_crlf     db 13, 10, '$'
kn1 db 'GET_DESCRIPTOR(device,8) at address 0', '$'
kn2 db 'SET_ADDRESS(1)', '$'
kn3 db 'GET_DESCRIPTOR(device,18) at address 1', '$'
kn4 db 'GET_DESCRIPTOR(config,9)', '$'
kn5 db 'GET_DESCRIPTOR(config,full)', '$'
kn6 db 'SET_CONFIGURATION', '$'
kn7 db 'SET_IDLE', '$'
kn8 db 'SET_PROTOCOL(boot)', '$'
stagetab dw kn1, kn2, kn3, kn4, kn5, kn6, kn7, kn8
msg_nokbd    db 'No boot-protocol keyboard on this device.', 13, 10, '$'
msg_ok       db 'Installed. Type away.', 13, 10, '$'

devbuf  times 20 db 0
cfgbuf  times CFGMAX db 0
