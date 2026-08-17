; ============================================================================
;  usbenum.asm  --  enumerate whatever is on a USB port and decode it
;
;  usbtest.com proves the controller works and reads a device descriptor.
;  This goes one step further and walks the CONFIGURATION descriptor, which is
;  the thing you need before you can write a driver: how many interfaces the
;  device has, what class each one is, and which endpoint to poll at what
;  interval.
;
;  Build:  nasm -f bin usbenum.asm -o usbenum.com
;  Usage:  usbenum        enumerate port 1 (the hybrid port)
;          usbenum 0      enumerate port 0 (normally the fixed disk -- this
;                         will reset it out from under DOS, so do not run it
;                         with a mounted C:)
;          usbenum 1 L    report the line state and stop. Run this with
;                         NOTHING plugged in: it is the only check on the
;                         port's pulldowns, which have to hold both lines low
;                         on a bare bus. A floating port half-enumerates,
;                         which is much worse to debug than one that fails.
;
;  WHY THE PORT IS A RUNTIME ARGUMENT
;  Each USB port now has its own engine at its own I/O window (0xE8 for port 0,
;  0xA8 for port 1), so the register addresses are not assemble-time constants
;  any more. Everything below goes through DX with the base in [ubase].
;
;  WHY DELAYS COME FROM THE BIOS TICK
;  The bus clock on this board is programmable from 5 to 16.667 MHz, so a
;  calibrated spin loop is wrong at seven of the eight speed steps -- and the
;  10 ms USB bus reset is a real minimum, not a suggestion. The tick at
;  40:6C runs from the PIT at a fixed 18.2 Hz whatever the CPU is doing, so
;  one tick is 55 ms at every step. That over-satisfies the 10 ms minimum,
;  which is the safe direction to be wrong in.
;
;  SHORT-PACKET RULE, READ THIS BEFORE COPYING THE CONTROL CODE
;  A control data stage ends when a packet arrives that is SHORTER THAN THE
;  ENDPOINT'S MAX PACKET SIZE -- not shorter than 64. bMaxPacketSize0 is 8 on
;  plenty of devices (every Logitech Unifying receiver, for one), and on those
;  a hardcoded 64 makes the FIRST full packet look short: the transfer ends
;  after 8 bytes and reports success, so an 18-byte device descriptor comes
;  back with 8 valid bytes and 10 bytes of whatever was in the buffer. This
;  reads the real value out of the device descriptor and uses it.
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

; ---- register offsets from the window base ---------------------------------
O_CMD   equ 0                   ; W command / R status
O_ADDR  equ 1                   ; W device address
O_ENDP  equ 2                   ; W endpoint / R last received PID
O_LEN   equ 3                   ; W tx length / R rx length
O_DATA  equ 4                   ; RW packet buffer, auto-increment
O_PTR   equ 5                   ; W buffer pointer
O_CTRL  equ 6                   ; W control / R line state
O_DIAG  equ 7                   ; W diag index / R selected counter

BASE_P0 equ 0x00E8
BASE_P1 equ 0x00A8

; commands
OP_SETUP equ 1
OP_IN    equ 2
OP_OUT   equ 3
GO       equ 0x80
DATA1    equ 0x08

; status bits
ST_BUSY  equ 0x01
ST_ACK   equ 0x02
ST_NAK   equ 0x04
ST_STALL equ 0x08
ST_TMO   equ 0x10
ST_ERR   equ 0x20
ST_RXD1  equ 0x40
ST_RXV   equ 0x80

; control bits
C_RESET  equ 0x02
C_SOFEN  equ 0x04
C_LOWSP  equ 0x10               ; run the port at 1.5 Mbps

; line-state bits
L_DP     equ 0x01
L_DM     equ 0x02
L_FS     equ 0x04
L_LS     equ 0x08
L_SOF    equ 0x10
L_LOCK   equ 0x20

; diagnostic indices
D_WINDOW equ 0x0E               ; low byte of this instance's IO_BASE
D_BUILD  equ 0x0F               ; 0xA5 build signature

; descriptor types
DT_DEVICE equ 1
DT_CONFIG equ 2

; ---- point DX at a register -------------------------------------------------
%macro SETDX 1
        mov  dx, [ubase]
        add  dl, %1
%endmacro

; ============================================================================
start:
        mov  dx, msg_hdr
        call puts

; ---------------- which port? -----------------------------------------------
        mov  word [ubase], BASE_P1
        mov  byte [portno], '1'
        mov  si, 0x81                   ; DOS command tail
        mov  cl, [0x80]
        xor  ch, ch
        jcxz .parsed
.scan:
        lodsb
        cmp  al, '0'
        jne  .s1
        mov  word [ubase], BASE_P0
        mov  byte [portno], '0'
        jmp  short .snext
.s1:
        cmp  al, '1'
        je   .snext
        cmp  al, 'L'
        je   .sline
        cmp  al, 'l'
        jne  .snext
.sline:
        mov  byte [lineonly], 1
.snext:
        loop .scan
.parsed:
        mov  dx, msg_port
        call puts
        mov  dl, [portno]
        mov  ah, 2
        int  0x21
        mov  dx, msg_at
        call puts
        mov  ax, [ubase]
        call puthex                     ; low byte is enough, both are 00xx
        mov  dx, msg_crlf
        call puts

; ---------------- 1: is the right engine answering? -------------------------
;  With two engines at two windows, a tool pointed at the wrong one reads
;  plausible registers and draws confident wrong conclusions. Ask the engine
;  which window it decodes and compare against the one we are driving.
        mov  dx, msg_t1
        call puts
        mov  al, D_BUILD
        SETDX O_DIAG
        out  dx, al
        in   al, dx
        cmp  al, 0xA5
        je   .t1_sig_ok
        push ax
        call fail
        mov  dx, msg_nosig
        call puts
        pop  ax
        call puthex
        mov  dx, msg_crlf
        call puts
        jmp  quit
.t1_sig_ok:
        mov  al, D_WINDOW
        SETDX O_DIAG
        out  dx, al
        in   al, dx
        mov  bl, al
        mov  ax, [ubase]
        cmp  al, bl
        je   .t1_ok
        push bx
        call fail
        mov  dx, msg_wrongwin
        call puts
        pop  ax
        call puthex
        mov  dx, msg_crlf
        call puts
        jmp  quit
.t1_ok:
        call pass

; ---------------- 2: 48 MHz PLL locked? -------------------------------------
        mov  dx, msg_t2
        call puts
        SETDX O_CTRL
        in   al, dx
        test al, L_LOCK
        jnz  .t2_ok
        call fail
        jmp  quit
.t2_ok:
        call pass

; ---------------- L mode: report the line and stop --------------------------
;  Everything below here needs a device. This does not, and that is the point:
;  with NOTHING plugged in, the line state is the only measurement of whether
;  the port's pulldowns are doing their job. Both lines must read low. A port
;  with a missing, wrong or badly soldered pulldown floats, and every reading
;  taken after that is noise that happens to look like data -- which is far
;  worse than a clean failure, because enumeration will sometimes half work.
        cmp  byte [lineonly], 0
        je   .no_lineonly
        SETDX O_CTRL
        in   al, dx
        mov  [linest], al
        call show_line
        mov  al, [linest]
        and  al, L_DP | L_DM
        jnz  .lo_dev
        mov  dx, msg_pd_ok
        call puts
        jmp  quit
.lo_dev:
        cmp  al, L_DP | L_DM
        jne  .lo_att
        ; Both lines high at once is not a bus state any device can produce.
        mov  dx, msg_pd_bad
        call puts
        jmp  quit
.lo_att:
        mov  dx, msg_pd_dev
        call puts
        jmp  quit
.no_lineonly:

; ---------------- 3: is a device attached, and at what speed? ---------------
;  The raw line byte is printed whatever the outcome. It is the only direct
;  reading of the port's electrical state, and with nothing plugged in it is
;  also the only check on the pulldowns -- see the L mode below.
        mov  dx, msg_t3
        call puts
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
        mov  [linest], al
        test al, L_FS
        jnz  .t3_fs
        test al, L_LS
        jnz  .t3_ls
        call fail
        call show_line
        mov  dx, msg_nodev
        call puts
        jmp  quit
.t3_fs:
        mov  byte [isls], 0
        mov  byte [spdbit], 0
        call pass
        call show_line
        mov  dx, msg_fs
        call puts
        jmp  short .t3_done
.t3_ls:
        mov  byte [isls], 1
        mov  byte [spdbit], C_LOWSP
        call pass
        call show_line
        mov  dx, msg_ls
        call puts
.t3_done:

; ---------------- 4: bus reset ----------------------------------------------
        mov  dx, msg_t4
        call puts
        SETDX O_CTRL
        mov  al, C_RESET
        or   al, [spdbit]
        out  dx, al
        call delay_tick                 ; 55 ms of SE0, well over the 10 ms min
        SETDX O_CTRL
        mov  al, [spdbit]               ; release, keeping the speed selection
        out  dx, al
        call delay_tick                 ; and let the device come back up
        SETDX O_CTRL
        in   al, dx
        ; L_FS, at BOTH speeds, and that is not a bug. LINE reports the engine's
        ; view of the pins, and in low-speed mode those are SWAPPED at the pads
        ; -- so a low-speed device, which really holds D- high, reads here as
        ; "D+ high, idle J". The device is identified BEFORE the mode is set,
        ; on bit 3; afterwards everything speaks the engine's language.
        test al, L_FS
        jnz  .t4_ok
        call fail
        mov  dx, msg_gone
        call puts
        jmp  quit
.t4_ok:
        call pass

; ---------------- 5: start SOF ----------------------------------------------
;  Without this the device sees 3 ms of silence and suspends, and every
;  transfer after that fails in a way that looks like a dead device.
        mov  dx, msg_t5
        call puts
        SETDX O_CTRL
        mov  al, C_SOFEN
        or   al, [spdbit]
        out  dx, al
        SETDX O_DIAG
        xor  al, al
        out  dx, al                     ; index 0 = frame counter
        in   al, dx
        mov  bl, al
        call delay_tick
        SETDX O_DIAG
        in   al, dx
        cmp  al, bl
        jne  .t5_ok
        call fail
        jmp  quit
.t5_ok:
        call pass

; ---------------- 6: first descriptor read, at address 0 --------------------
;  Ask for 8 bytes only. bMaxPacketSize0 is not known yet and 8 is the one
;  size every device must support, so this is the bootstrap that tells us what
;  the real packet size is.
        mov  dx, msg_t6
        call puts
        xor  al, al
        SETDX O_ADDR
        out  dx, al                     ; talk to address 0
        mov  byte [ep0max], 8

        mov  si, sp_getdev8
        mov  di, devbuf
        push ds
        pop  es
        mov  cx, 8
        call ctl_read
        jc   .t6_bad
        cmp  cx, 8
        jb   .t6_bad
        call pass
        mov  al, [devbuf+7]             ; bMaxPacketSize0
        mov  [ep0max], al
        mov  dx, msg_ep0
        call puts
        mov  al, [ep0max]
        call putdec
        mov  dx, msg_crlf
        call puts
        jmp  short .t6_done
.t6_bad:
        call fail
        call show_status
        jmp  quit
.t6_done:

; ---------------- 7: SET_ADDRESS(1) -----------------------------------------
        mov  dx, msg_t7
        call puts
        mov  si, sp_setaddr
        mov  di, devbuf
        push ds
        pop  es
        xor  cx, cx                     ; no data stage
        call ctl_read
        jc   .t7_bad
        ; The device only adopts the new address after the status stage, so
        ; this must come after ctl_read returns, not before.
        mov  al, 1
        SETDX O_ADDR
        out  dx, al
        call delay_tick                 ; 2 ms is the spec allowance; 55 is safe
        call pass
        jmp  short .t7_done
.t7_bad:
        call fail
        call show_status
        jmp  quit
.t7_done:

; ---------------- 8: full device descriptor ---------------------------------
        mov  dx, msg_t8
        call puts
        mov  si, sp_getdev18
        mov  di, devbuf
        push ds
        pop  es
        mov  cx, 18
        call ctl_read
        jc   .t8_bad
        cmp  cx, 18
        jb   .t8_bad
        call pass
        call show_device
        jmp  short .t8_done
.t8_bad:
        call fail
        call show_status
        jmp  quit
.t8_done:

; ---------------- 9: configuration descriptor, header first -----------------
;  Two reads: 9 bytes to learn wTotalLength, then the whole thing. Asking for
;  a fixed large number instead would work on most devices and stall on the
;  pedantic ones.
        mov  dx, msg_t9
        call puts
        mov  si, sp_getcfg9
        mov  di, cfgbuf
        push ds
        pop  es
        mov  cx, 9
        call ctl_read
        jc   .t9_bad
        cmp  cx, 9
        jb   .t9_bad
        mov  ax, [cfgbuf+2]             ; wTotalLength
        mov  [cfglen], ax
        cmp  ax, CFGMAX
        jbe  .t9_fits
        mov  ax, CFGMAX                 ; clamp rather than overrun the buffer
        mov  [cfglen], ax
.t9_fits:
        mov  ax, [cfglen]
        mov  [sp_getcfgn+6], ax         ; patch wLength of the full request
        mov  si, sp_getcfgn
        mov  di, cfgbuf
        push ds
        pop  es
        mov  cx, [cfglen]
        call ctl_read
        jc   .t9_bad
        cmp  cx, [cfglen]
        jb   .t9_bad
        call pass
        call show_config
        jmp  short .t9_done
.t9_bad:
        call fail
        call show_status
        jmp  quit
.t9_done:

        mov  dx, msg_ok
        call puts
quit:
        mov  ah, 0x4C
        xor  al, al
        int  0x21

; ============================================================================
;  ctl_read -- one complete control transfer
;    DS:SI = 8-byte setup packet
;    ES:DI = destination for the data stage (ignored when CX = 0)
;    CX    = bytes wanted, 0 for no data stage
;  Returns CF set on failure, CX = bytes actually moved.
;
;  The status stage moves no data and is skipped by every first draft of this
;  routine. Leaving it out parks the device's control endpoint mid-transfer
;  and the NEXT request stalls, which looks like the second request being at
;  fault rather than the first being unfinished.
; ============================================================================
ctl_read:
        push ax
        push bx
        push dx
        push si
        push di
        push bp
        mov  bp, cx                     ; wanted
        mov  al, [si]
        mov  [reqtype], al              ; direction, for the status stage

        ; ---- control transfers always go to endpoint 0 ----
        xor  al, al
        SETDX O_ENDP
        out  dx, al

        ; ---- SETUP stage, always DATA0 ----
        call setptr
        mov  cx, 8
        SETDX O_DATA
.cr_fill:
        lodsb
        out  dx, al
        loop .cr_fill
        mov  al, 8
        SETDX O_LEN
        out  dx, al
        mov  al, OP_SETUP | GO
        call txn
        jc   .cr_bad
        test al, ST_ACK
        jz   .cr_bad

        ; ---- data stage ----
        xor  bx, bx                     ; bytes moved
        test bp, bp
        jz   .cr_status
.cr_data:
        call setptr
        mov  al, OP_IN | GO
        call txn
        jc   .cr_bad
        test al, ST_RXV
        jz   .cr_bad
        SETDX O_LEN
        in   al, dx
        xor  ah, ah
        mov  cx, ax                     ; bytes in this packet
        jcxz .cr_status                 ; a zero-length packet ends the stage
        push cx
        call setptr
        SETDX O_DATA
.cr_copy:
        in   al, dx
        stosb
        inc  bx
        loop .cr_copy
        pop  cx
        ; SHORT PACKET = shorter than the ENDPOINT's max, not shorter than 64.
        ; See the header. cx is this packet's length, [ep0max] the real size.
        mov  al, [ep0max]
        xor  ah, ah
        cmp  cx, ax
        jb   .cr_status
        cmp  bx, bp
        jb   .cr_data

.cr_status:
        push bx
        call setptr
        xor  al, al
        SETDX O_LEN
        out  dx, al                     ; zero length
        mov  al, [reqtype]
        test al, 0x80
        jz   .cr_st_in                  ; host-to-device: status is IN
        mov  al, OP_OUT | GO | DATA1    ; device-to-host: status is OUT
        jmp  short .cr_st_go
.cr_st_in:
        mov  al, OP_IN | GO | DATA1
.cr_st_go:
        call txn
        pop  bx
        jc   .cr_bad
        mov  cx, bx
        clc
        jmp  short .cr_out
.cr_bad:
        xor  cx, cx
        stc
.cr_out:
        pop  bp
        pop  di
        pop  si
        pop  dx
        pop  bx
        pop  ax
        ret

; ============================================================================
;  txn -- issue AL as a command and wait for it to finish, returning status.
;
;  Three kinds of "no" need three different responses, and collapsing them is
;  the mistake this stack has already made once:
;    NAK      the device is busy -- reissue, many times, it is flow control
;    ERR/TMO  a packet was lost -- USB expects the HOST to retry, and with no
;             series resistors on D+/D- that is not rare on this board
;    STALL    a real refusal -- report it, retrying would be wrong
;
;  The command is kept in BL because DX is the port register for every OUT
;  below, so anything stashed in DL is gone by the second attempt.
; ============================================================================
txn:
        push bx
        push cx
        push dx
        mov  bl, al                     ; command, safe from DX
        mov  bh, 3                      ; attempts after a corrupted packet
.tx_attempt:
        mov  cx, 400                    ; NAK budget
.tx_try:
        push cx
        mov  al, bl
        SETDX O_CMD
        out  dx, al
        call wait_done
        pop  cx
        jc   .tx_wedged
        test al, ST_NAK
        jz   .tx_settled
        loop .tx_try
        jmp  short .tx_fail             ; NAKed past the budget
.tx_settled:
        test al, ST_STALL
        jnz  .tx_fail                   ; a refusal, not a glitch
        test al, ST_ERR | ST_TMO
        jz   .tx_ok
        dec  bh
        jnz  .tx_attempt                ; lost packet -- the host retries
        jmp  short .tx_fail
.tx_ok:
        clc
        jmp  short .tx_out
.tx_wedged:
.tx_fail:
        stc
.tx_out:
        pop  dx
        pop  cx
        pop  bx
        ret

; wait_done: poll STATUS until BUSY clears. Returns status in AL, CF set if it
;            never cleared -- an engine that is wedged is a different fault
;            from a device that did not answer, and they want different fixes.
wait_done:
        push cx
        push dx
        mov  cx, 0                      ; full 65536-iteration budget
.wd_l:
        SETDX O_CMD
        in   al, dx
        test al, ST_BUSY
        jz   .wd_ok
        loop .wd_l
        stc
        jmp  short .wd_out
.wd_ok:
        clc
.wd_out:
        pop  dx
        pop  cx
        ret

; setptr: rewind both buffer pointers
setptr:
        push ax
        push dx
        xor  al, al
        SETDX O_PTR
        out  dx, al
        pop  dx
        pop  ax
        ret

; delay_tick: wait for the 18.2 Hz BIOS tick to change, i.e. up to 55 ms.
;             Clock-independent, which a spin loop is not on this board.
delay_tick:
        push ax
        push bx
        push cx
        push es
        xor  ax, ax
        mov  es, ax
        mov  bx, [es:0x46C]
        mov  cx, 0                      ; give up rather than hang if the tick
.dt_l:                                  ; is not running (no PIT, no INT 8)
        mov  ax, [es:0x46C]
        cmp  ax, bx
        jne  .dt_out
        loop .dt_l
.dt_out:
        pop  es
        pop  cx
        pop  bx
        pop  ax
        ret

; ============================================================================
;  decoding
; ============================================================================
show_device:
        mov  dx, msg_dev
        call puts
        mov  dx, msg_vid
        call puts
        ; Device descriptor layout, and the two offsets that are easy to get
        ; wrong: bLength 0, bDescriptorType 1, bcdUSB 2, class/sub/proto 4/5/6,
        ; bMaxPacketSize0 7, idVendor 8, idProduct 10, bcdDevice 12.
        ; Reading these one byte late does not look like a bug -- it prints a
        ; plausible VID and PID built from the high half of one field and the
        ; low half of the next. 046D:C52B came out as 2B04:11C5, where the 11
        ; is the low byte of bcdDevice.
        mov  ax, [devbuf+8]             ; idVendor, little endian
        call puthex16
        mov  dx, msg_pid
        call puts
        mov  ax, [devbuf+10]            ; idProduct
        call puthex16
        mov  dx, msg_class
        call puts
        mov  al, [devbuf+4]             ; bDeviceClass
        call puthex
        mov  dx, msg_slash
        call puts
        mov  al, [devbuf+5]
        call puthex
        mov  dx, msg_slash
        call puts
        mov  al, [devbuf+6]
        call puthex
        mov  dx, msg_ncfg
        call puts
        mov  al, [devbuf+17]            ; bNumConfigurations
        call putdec
        mov  dx, msg_crlf
        call puts
        ; Class 0 at device level means "look at the interfaces" -- a composite
        ; device. Worth naming, because it is why one dongle can be a keyboard
        ; and a mouse at the same time.
        mov  al, [devbuf+4]
        or   al, al
        jnz  .sd_out
        mov  dx, msg_composite
        call puts
.sd_out:
        ret

; show_config: walk the descriptor chain and print interfaces and endpoints.
;  Descriptors are a linked list by length, NOT a fixed layout: each starts
;  with bLength and bDescriptorType, and unknown types must be skipped by
;  their own length rather than assumed absent. HID descriptors sit between
;  an interface and its endpoints and would derail a fixed-stride walk.
show_config:
        push si
        mov  dx, msg_cfg
        call puts
        mov  al, [cfgbuf+4]             ; bNumInterfaces
        call putdec
        mov  dx, msg_iflen
        call puts
        mov  ax, [cfglen]
        call puthex16
        mov  dx, msg_crlf
        call puts

        mov  si, cfgbuf
        mov  cx, [cfglen]
.sc_walk:
        cmp  cx, 2
        jb   .sc_done
        mov  al, [si]                   ; bLength
        or   al, al
        jz   .sc_done                   ; a zero length would loop forever
        mov  bl, [si+1]                 ; bDescriptorType
        cmp  bl, 4
        je   .sc_iface
        cmp  bl, 5
        je   .sc_endp
        jmp  .sc_next
.sc_iface:
        push cx
        mov  dx, msg_if
        call puts
        mov  al, [si+2]                 ; bInterfaceNumber
        call putdec
        mov  dx, msg_ifalt
        call puts
        mov  al, [si+3]                 ; bAlternateSetting
        call putdec
        mov  dx, msg_ifcls
        call puts
        mov  al, [si+5]                 ; bInterfaceClass
        call puthex
        mov  dx, msg_slash
        call puts
        mov  al, [si+6]                 ; bInterfaceSubClass
        call puthex
        mov  dx, msg_slash
        call puts
        mov  al, [si+7]                 ; bInterfaceProtocol
        call puthex
        call name_iface
        mov  dx, msg_crlf
        call puts
        pop  cx
        jmp  .sc_next
.sc_endp:
        push cx
        mov  dx, msg_ep
        call puts
        mov  al, [si+2]                 ; bEndpointAddress
        call puthex
        mov  dx, msg_epdir
        call puts
        mov  al, [si+2]
        test al, 0x80
        jz   .se_out
        mov  dx, msg_in
        jmp  short .se_dir
.se_out:
        mov  dx, msg_out
.se_dir:
        call puts
        mov  dx, msg_eptype
        call puts
        mov  al, [si+3]                 ; bmAttributes
        and  al, 3
        cmp  al, 3
        jne  .se_t1
        mov  dx, msg_intr
        jmp  short .se_tp
.se_t1:
        cmp  al, 2
        jne  .se_t2
        mov  dx, msg_bulk
        jmp  short .se_tp
.se_t2:
        cmp  al, 1
        jne  .se_t3
        mov  dx, msg_isoc
        jmp  short .se_tp
.se_t3:
        mov  dx, msg_ctl
.se_tp:
        call puts
        mov  dx, msg_epmax
        call puts
        mov  ax, [si+4]                 ; wMaxPacketSize
        call puthex16
        mov  dx, msg_epival
        call puts
        mov  al, [si+6]                 ; bInterval, ms at full speed
        call putdec
        mov  dx, msg_ms
        call puts
        pop  cx
.sc_next:
        mov  al, [si]                   ; advance by bLength
        xor  ah, ah
        add  si, ax
        sub  cx, ax
        ja   .sc_walk
.sc_done:
        pop  si
        ret

; name_iface: put a human name on the class triple, for the ones that matter
;             here. SI still points at the interface descriptor.
name_iface:
        mov  al, [si+5]
        cmp  al, 3                      ; HID
        jne  .ni_stor
        mov  al, [si+6]
        cmp  al, 1                      ; boot subclass
        jne  .ni_hidgen
        mov  al, [si+7]
        cmp  al, 1
        jne  .ni_m
        mov  dx, msg_bootkbd
        jmp  short .ni_say
.ni_m:
        cmp  al, 2
        jne  .ni_hidgen
        mov  dx, msg_bootmouse
        jmp  short .ni_say
.ni_hidgen:
        mov  dx, msg_hidgen
        jmp  short .ni_say
.ni_stor:
        cmp  al, 8                      ; mass storage
        jne  .ni_hub
        mov  dx, msg_storage
        jmp  short .ni_say
.ni_hub:
        cmp  al, 9                      ; hub
        jne  .ni_none
        mov  dx, msg_hub
        jmp  short .ni_say
.ni_none:
        ret
.ni_say:
        call puts
        ret

; show_line: the raw D+/D- reading and what it means. Only four values are
;            possible and each says something different, so decode it rather
;            than print a number and leave the reader to remember the table.
show_line:
        push ax
        push dx
        mov  dx, msg_line
        call puts
        mov  al, [linest]
        and  al, L_DP | L_DM
        call puthex
        mov  dx, msg_sp
        call puts
        mov  al, [linest]
        and  al, L_DP | L_DM
        jnz  .sl_1
        mov  dx, msg_line00
        jmp  short .sl_say
.sl_1:
        cmp  al, L_DP
        jne  .sl_2
        mov  dx, msg_line01
        jmp  short .sl_say
.sl_2:
        cmp  al, L_DM
        jne  .sl_3
        mov  dx, msg_line02
        jmp  short .sl_say
.sl_3:
        mov  dx, msg_line03
.sl_say:
        call puts
        pop  dx
        pop  ax
        ret

; show_status: print the raw status byte, which says what actually came back
;              rather than how this program classified it
show_status:
        push ax
        push dx
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
        pop  dx
        pop  ax
        ret

; ============================================================================
;  output helpers
; ============================================================================
puts:
        push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

; puthex MUST preserve CX -- it is called from inside counted loops, and the
; nibble shift below needs CL.
puthex:
        push ax
        push bx
        push cx
        push dx
        mov  bl, al
        mov  cl, 4
        shr  al, cl                     ; shift by CL: an immediate > 1 is 186+
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

; puthex16: AX in hex, high byte first
puthex16:
        push ax
        mov  al, ah
        call puthex
        pop  ax
        call puthex
        ret

; putdec: AL as decimal, 0..255, no leading zeros.
;
;  Divide down pushing each remainder, then pop them back off -- the digits
;  come out least significant first and the stack reverses them. The obvious
;  straight-line version does not survive here: the remainder lives in AH, and
;  printing a digit needs "mov ah, 2" for INT 21h, so every print destroys the
;  digit that was going to be printed next.
putdec:
        push ax
        push bx
        push cx
        push dx
        xor  ah, ah
        mov  bl, 10
        xor  cx, cx
.pd_div:
        xor  ah, ah
        div  bl                         ; AL = quotient, AH = remainder
        push ax                         ; stash the remainder with it
        inc  cx
        or   al, al
        jnz  .pd_div
.pd_emit:
        pop  ax
        mov  dl, ah
        add  dl, '0'
        mov  ah, 2
        int  0x21
        loop .pd_emit
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

pass:
        push dx
        mov  dx, msg_pass
        call puts
        pop  dx
        ret
fail:
        push dx
        mov  dx, msg_fail
        call puts
        pop  dx
        ret

; ============================================================================
;  data
; ============================================================================
CFGMAX  equ 256

ubase    dw BASE_P1
portno   db '1'
linest   db 0
isls     db 0
spdbit   db 0                    ; 0 or C_LOWSP, ORed into every CTRL write
lineonly db 0
ep0max  db 8
reqtype db 0
cfglen  dw 0

; setup packets. bmRequestType, bRequest, wValue, wIndex, wLength
sp_getdev8   db 0x80, 6, 0x00, DT_DEVICE, 0, 0, 8, 0
sp_getdev18  db 0x80, 6, 0x00, DT_DEVICE, 0, 0, 18, 0
sp_setaddr   db 0x00, 5, 1, 0, 0, 0, 0, 0
sp_getcfg9   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 9, 0
sp_getcfgn   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 0, 0   ; wLength patched at run time

msg_hdr      db 'USBENUM -- enumerate and decode a USB device', 13, 10, '$'
msg_port     db 'port ', '$'
msg_at       db ' at 0x', '$'
msg_crlf     db 13, 10, '$'
msg_t1       db ' engine responds  ', '$'
msg_t2       db ' 48 MHz locked    ', '$'
msg_t3       db ' device present   ', '$'
msg_t4       db ' bus reset        ', '$'
msg_t5       db ' SOF running      ', '$'
msg_t6       db ' descriptor @ 0   ', '$'
msg_t7       db ' SET_ADDRESS(1)   ', '$'
msg_t8       db ' device descriptor', '$'
msg_t9       db ' configuration    ', '$'
msg_pass     db 'ok', 13, 10, '$'
msg_fail     db 'FAILED', 13, 10, '$'
msg_nosig    db '  build signature is not A5, read ', '$'
msg_wrongwin db '  engine reports window ', '$'
msg_nodev    db '  nothing attached -- plug the device in and run again', 13, 10, '$'
msg_sp       db ' ', '$'
msg_line     db '  D+/D- = ', '$'
msg_line00   db 'both low: bare bus, pulldowns holding SE0', 13, 10, '$'
msg_line01   db 'D+ high: full-speed device attached', 13, 10, '$'
msg_line02   db 'D- high: LOW-speed device attached', 13, 10, '$'
msg_line03   db 'BOTH HIGH -- impossible, see below', 13, 10, '$'
msg_pd_ok    db '  pulldowns OK on this port: nothing attached and both lines', 13, 10
             db '  are held low. Anything from 15K to 22K reads the same here.', 13, 10, '$'
msg_pd_bad   db '  Both lines cannot be high at once on a real bus. That reading', 13, 10
             db '  means the pins are FLOATING -- a missing, open or badly', 13, 10
             db '  soldered pulldown on D+ and D-. Fix that before trusting any', 13, 10
             db '  other USB result: a floating port half-enumerates.', 13, 10, '$'
msg_pd_dev   db '  A device is attached, so this says nothing about the', 13, 10
             db '  pulldowns. Unplug everything and run "usbenum 1 L" again.', 13, 10, '$'
msg_gone     db '  device vanished across the reset', 13, 10, '$'
msg_fs       db '  full speed (12 Mbps)', 13, 10, '$'
msg_ls       db '  LOW speed (1.5 Mbps)', 13, 10, '$'
msg_ep0      db '  EP0 max packet  ', '$'
msg_dev      db 'device:', 13, 10, '$'
msg_vid      db '  VID ', '$'
msg_pid      db '  PID ', '$'
msg_class    db '  class ', '$'
msg_slash    db '/', '$'
msg_ncfg     db '  configs ', '$'
msg_composite db '  device class 0 = composite; the interfaces carry the classes', 13, 10, '$'
msg_cfg      db 'configuration: ', '$'
msg_iflen    db ' interface(s), total length 0x', '$'
msg_if       db '  iface ', '$'
msg_ifalt    db ' alt ', '$'
msg_ifcls    db ' class ', '$'
msg_ep       db '    ep ', '$'
msg_epdir    db ' ', '$'
msg_in       db 'IN ', '$'
msg_out      db 'OUT', '$'
msg_eptype   db ' ', '$'
msg_intr     db 'interrupt', '$'
msg_bulk     db 'bulk     ', '$'
msg_isoc     db 'isoc     ', '$'
msg_ctl      db 'control  ', '$'
msg_epmax    db ' max 0x', '$'
msg_epival   db ' every ', '$'
msg_ms       db ' ms', 13, 10, '$'
msg_bootkbd  db '  (HID boot keyboard)', '$'
msg_bootmouse db '  (HID boot mouse)', '$'
msg_hidgen   db '  (HID, not boot protocol)', '$'
msg_storage  db '  (mass storage)', '$'
msg_hub      db '  (hub)', '$'
msg_status   db '  status ', '$'
msg_rxpid    db '  rxpid ', '$'
msg_ok       db 'enumeration complete', 13, 10, '$'

devbuf  times 20  db 0
cfgbuf  times CFGMAX db 0
