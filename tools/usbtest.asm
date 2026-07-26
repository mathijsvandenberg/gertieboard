; ============================================================================
;  usbtest.asm  --  exercise the USB host controller from DOS
;
;  Works upward in the order things can actually fail, and STOPS at the first
;  failure rather than reporting a cascade of consequences:
;
;    1  registers respond at all          (write/read back a scratch register)
;    2  the 48 MHz PLL is locked
;    3  line state with nothing plugged in -- both lines must read LOW
;    4  a device is detected               (D+ high = full speed)
;    5  the SOF generator runs             (frame counter advances)
;    6  bus reset, then the device is still there
;    7  GET_DESCRIPTOR(DEVICE, 8 bytes) to address 0 -- the first real transfer
;    8  SET_ADDRESS(1), then GET_DESCRIPTOR again at the new address
;    9  the full 18-byte device descriptor, decoded
;
;  Test 3 matters more than it looks. The host end of a USB port needs 15K
;  pulldowns on both lines; without them the pins float and every reading after
;  this one is noise that happens to look like data. If test 3 fails with
;  nothing plugged in, stop and check the board, not the software.
;
;  Build:  nasm -f bin usbtest.asm -o usbtest.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

; ---- controller registers --------------------------------------------------
U_CMD   equ 0xE8                ; W command / R status
U_ADDR  equ 0xE9                ; W device address
U_ENDP  equ 0xEA                ; W endpoint
U_LEN   equ 0xEB                ; W tx length / R rx length
U_DATA  equ 0xEC                ; RW packet buffer, auto-increment
U_PTR   equ 0xED                ; W buffer pointer
U_RXPID equ 0xEA                ; R  PID of the last packet received
U_CTRL  equ 0xEE                ; W control / R line state
U_FRAME equ 0xEF                ; R frame counter low byte

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
C_PORT1  equ 0x01
C_RESET  equ 0x02
C_SOFEN  equ 0x04

; line-state bits
L_DP     equ 0x01
L_DM     equ 0x02
L_FS     equ 0x04
L_LS     equ 0x08
L_SOF    equ 0x10
L_LOCK   equ 0x20

start:
        mov  dx, msg_hdr
        call puts

; ---------------- 1: do the registers respond? ------------------------------
        mov  dx, msg_t1
        call puts
        mov  al, 0x55
        out  U_ADDR, al
        in   al, U_ADDR
        cmp  al, 0x55
        jne  .t1_bad
        mov  al, 0x2A
        out  U_ADDR, al
        in   al, U_ADDR
        cmp  al, 0x2A
        jne  .t1_bad
        xor  al, al
        out  U_ADDR, al
        call pass
        jmp  short .t1b
.t1_bad:
        call fail
        mov  dx, msg_noreg
        call puts
        jmp  done

; ---------------- 1b: does the buffer pointer advance ONCE per write? -------
; The I/O write strobe is asserted for the whole bus cycle, several 5 MHz clocks
; wide, so a register that acts on the level rather than the edge fires several
; times. That is what corrupted the SETUP packet and got it STALLed: each byte
; landed in several slots and the pointer ran away. Eight writes must leave the
; pointer at exactly 8.
.t1b:
        mov  dx, msg_t1b
        call puts
        xor  al, al
        out  U_PTR, al
        mov  cx, 8
        mov  al, 0xA5
.t1b_w:
        out  U_DATA, al
        loop .t1b_w
        in   al, U_PTR
        cmp  al, 8
        jne  .t1b_bad
        call pass
        jmp  short .t2
.t1b_bad:
        call fail
        mov  dx, msg_ptr
        call puts
        call puthex
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_ptrwhy
        call puts
        jmp  done

; ---------------- 2: 48 MHz PLL locked --------------------------------------
.t2:
        mov  dx, msg_t2
        call puts
        in   al, U_CTRL
        test al, L_LOCK
        jz   .t2_bad
        call pass
        jmp  short .t3
.t2_bad:
        call fail
        mov  dx, msg_nolock
        call puts
        jmp  done

; ---------------- 3: idle line state, nothing plugged in --------------------
.t3:
        mov  dx, msg_t3
        call puts
        xor  al, al                     ; port 0, no reset, no SOF
        out  U_CTRL, al
        call delay_ms                   ; let it settle
        in   al, U_CTRL
        and  al, L_DP | L_DM
        mov  bl, al
        ; Only 03 is impossible. 00 is a bare bus, 01 is a full-speed device
        ; holding D+ up through its 1.5K, 02 the same for low speed -- all three
        ; are valid, so do not cry wolf about the pulldowns for them.
        cmp  al, 3
        je   .t3_bad
        call pass
        mov  dx, msg_lines
        call puts
        mov  al, bl
        call puthex
        mov  dx, msg_sp
        call puts
        cmp  bl, 0
        jne  .t3_dev
        mov  dx, msg_bare
        call puts
        jmp  short .t4
.t3_dev:
        cmp  bl, L_DP
        jne  .t3_ls
        mov  dx, msg_idlej
        call puts
        jmp  short .t4
.t3_ls:
        mov  dx, msg_idlek
        call puts
        jmp  short .t4
.t3_bad:
        call warn
        mov  dx, msg_lines
        call puts
        mov  al, bl
        call puthex
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_pulldn
        call puts

; ---------------- 4: device present? ----------------------------------------
.t4:
        mov  dx, msg_t4
        call puts
        mov  cx, 200                    ; wait up to ~2 s for an attach
.t4_wait:
        in   al, U_CTRL
        test al, L_FS | L_LS
        jnz  .t4_got
        push cx
        call delay_ms
        pop  cx
        loop .t4_wait
        call fail
        mov  dx, msg_nodev
        call puts
        jmp  done
.t4_got:
        test al, L_LS
        jz   .t4_fs
        call fail
        mov  dx, msg_lowspd
        call puts
        jmp  done
.t4_fs:
        call pass
        mov  dx, msg_fsdev
        call puts

; ---------------- 5: SOF generator ------------------------------------------
.t5:
        mov  dx, msg_t5
        call puts
        mov  al, C_SOFEN
        out  U_CTRL, al
        in   al, U_FRAME
        mov  bl, al
        call delay_ms
        call delay_ms
        call delay_ms
        in   al, U_FRAME
        cmp  al, bl
        je   .t5_bad                    ; counter did not move in 3 ms
        call pass
        jmp  short .t6
.t5_bad:
        call fail
        mov  dx, msg_nosof
        call puts
        jmp  done

; ---------------- 6: bus reset ----------------------------------------------
.t6:
        mov  dx, msg_t6
        call puts
        mov  al, C_RESET                ; SE0, SOF off during reset
        out  U_CTRL, al
        mov  cx, 20                     ; >= 10 ms is the spec minimum
.t6_hold:
        call delay_ms
        loop .t6_hold
        mov  al, C_SOFEN                ; release, SOF on to keep it awake
        out  U_CTRL, al
        mov  cx, 50                     ; devices get 10 ms to recover; be kind
.t6_rec:
        call delay_ms
        loop .t6_rec
        in   al, U_CTRL
        test al, L_FS
        jz   .t6_bad
        call pass
        jmp  short .t7
.t6_bad:
        call fail
        mov  dx, msg_gone
        call puts
        jmp  done

; ---------------- 7: GET_DESCRIPTOR(DEVICE) to address 0 --------------------
.t7:
        mov  dx, msg_t7
        call puts
        xor  al, al
        out  U_ADDR, al                 ; still address 0
        out  U_ENDP, al
        mov  si, req_getdesc8
        call setup_xfer
        jc   .t7_setupbad
        ; data stage: IN, expect 8 bytes
        mov  al, DATA1                  ; first data IN is DATA1
        call in_xfer
        jc   .t7_inbad
        in   al, U_LEN
        test al, al
        jz   .t7_bad
        call pass
        mov  dx, msg_desc8
        call puts
        call dump_rx
        ; remember bMaxPacketSize0 (offset 7) for later
        jmp  short .t8
.t7_setupbad:
        call fail
        mov  dx, msg_stgsetup
        call puts
        call show_status
        jmp  done
.t7_inbad:
        call fail
        mov  dx, msg_stgin
        call puts
        call show_status
        jmp  done
.t7_bad:
        call fail
        mov  dx, msg_nodesc
        call puts
        call show_status
        jmp  done

; ---------------- 8: SET_ADDRESS(1) -----------------------------------------
.t8:
        mov  dx, msg_t8
        call puts
        xor  al, al
        out  U_ADDR, al
        out  U_ENDP, al
        mov  si, req_setaddr
        call setup_xfer
        jc   .t8_bad
        ; status stage: IN with zero-length data
        mov  al, DATA1
        call in_xfer
        jc   .t8_bad
        call delay_ms                   ; the device needs <=2 ms to take it
        call delay_ms
        mov  al, 1
        out  U_ADDR, al                 ; talk to it at its new address now
        call pass
        jmp  short .t9
.t8_bad:
        call fail
        mov  dx, msg_noaddr
        call puts
        call show_status
        jmp  done

; ---------------- 9: full device descriptor at the new address --------------
.t9:
        mov  dx, msg_t9
        call puts
        mov  si, req_getdesc18
        call setup_xfer
        jc   .t9_bad
        mov  al, DATA1
        call in_xfer
        jc   .t9_bad
        in   al, U_LEN
        cmp  al, 8
        jb   .t9_bad
        call pass
        call dump_rx
        call decode_desc
        jmp  done
.t9_bad:
        call fail
        mov  dx, msg_nodesc
        call puts
        call show_status

done:
        mov  al, 0                      ; SOF off, leave the bus quiet
        out  U_CTRL, al
        mov  dx, msg_end
        call puts
        mov  ax, 0x4C00
        int  0x21

; ============================================================================
;  transaction helpers
; ============================================================================

; setup_xfer: DS:SI = 8-byte setup packet. CF set on failure.
setup_xfer:
        push ax
        push cx
        push si
        xor  al, al
        out  U_PTR, al                  ; buffer pointer to 0
        mov  cx, 8
.sx_fill:
        lodsb
        out  U_DATA, al
        loop .sx_fill
        mov  al, 8
        out  U_LEN, al
        mov  al, OP_SETUP | GO
        out  U_CMD, al
        call wait_done
        jc   .sx_out                    ; timed out waiting for BUSY to clear
        test al, ST_ACK
        jz   .sx_err
        clc
        jmp  short .sx_out
.sx_err:
        stc
.sx_out:
        pop  si
        pop  cx
        pop  ax
        ret

; in_xfer: AL = DATA1 flag (0 or DATA1). CF set on failure.
;          Retries on NAK, which is normal while a device is thinking.
in_xfer:
        push bx
        push cx
        mov  bl, al
        mov  cx, 200                    ; NAK retry budget
.ix_try:
        push cx
        xor  al, al
        out  U_PTR, al
        mov  al, OP_IN | GO
        out  U_CMD, al
        call wait_done
        pop  cx
        jc   .ix_err
        test al, ST_RXV
        jnz  .ix_ok
        test al, ST_NAK
        jz   .ix_err                    ; STALL, timeout or bad packet
        loop .ix_try
.ix_err:
        stc
        jmp  short .ix_out
.ix_ok:
        xor  al, al
        out  U_PTR, al                  ; rewind so the caller can read it
        clc
.ix_out:
        pop  cx
        pop  bx
        ret

; wait_done: poll STATUS until BUSY clears. Returns status in AL.
;            CF set if it never cleared -- that means the engine is wedged,
;            which is a different fault from the device not answering.
wait_done:
        push cx
        mov  cx, 0
.wd_l:
        in   al, U_CMD
        test al, ST_BUSY
        jz   .wd_ok
        loop .wd_l
        stc
        pop  cx
        ret
.wd_ok:
        clc
        pop  cx
        ret

; show_status: print the status byte and name the bits that are set
show_status:
        push ax
        mov  dx, msg_status
        call puts
        in   al, U_CMD
        push ax
        call puthex
        mov  dx, msg_sp
        call puts
        pop  ax
        mov  bl, al
        test bl, ST_NAK
        jz   .s1
        mov  dx, msg_nak
        call puts
.s1:    test bl, ST_STALL
        jz   .s2
        mov  dx, msg_stall
        call puts
.s2:    test bl, ST_TMO
        jz   .s3
        mov  dx, msg_tmo
        call puts
.s3:    test bl, ST_ERR
        jz   .s4
        mov  dx, msg_err
        call puts
.s4:    mov  dx, msg_rxpid
        call puts
        in   al, U_RXPID
        call puthex
        mov  dx, msg_crlf
        call puts
        pop  ax
        ret

; dump_rx: hex-dump RXLEN bytes from the receive buffer
dump_rx:
        push ax
        push cx
        in   al, U_LEN
        xor  ah, ah
        mov  cx, ax
        jcxz .dr_done
        xor  al, al
        out  U_PTR, al
        mov  dx, msg_ind
        call puts
.dr_l:
        in   al, U_DATA
        call puthex
        mov  dx, msg_sp
        call puts
        loop .dr_l
        mov  dx, msg_crlf
        call puts
.dr_done:
        pop  cx
        pop  ax
        ret

; decode_desc: print the interesting fields of a device descriptor
decode_desc:
        push ax
        xor  al, al
        out  U_PTR, al
        mov  cx, 18
        mov  di, descbuf
.dd_c:
        in   al, U_DATA
        mov  [di], al
        inc  di
        loop .dd_c

        mov  dx, msg_vid
        call puts
        mov  al, [descbuf+9]            ; idVendor high
        call puthex
        mov  al, [descbuf+8]
        call puthex
        mov  dx, msg_pid
        call puts
        mov  al, [descbuf+11]
        call puthex
        mov  al, [descbuf+10]
        call puthex
        mov  dx, msg_crlf
        call puts

        mov  dx, msg_class
        call puts
        mov  al, [descbuf+4]            ; bDeviceClass
        call puthex
        mov  dx, msg_sp
        call puts
        cmp  byte [descbuf+4], 0x08
        jne  .dd_nc
        mov  dx, msg_massst
        call puts
        jmp  short .dd_e
.dd_nc:
        cmp  byte [descbuf+4], 0x00
        jne  .dd_e
        mov  dx, msg_periface
        call puts
.dd_e:
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_mps
        call puts
        mov  al, [descbuf+7]            ; bMaxPacketSize0
        call puthex
        mov  dx, msg_crlf
        call puts
        pop  ax
        ret

; delay_ms: roughly 1 ms at 5 MHz. Not precise, and it does not need to be --
; every USB delay here is a minimum with a generous margin.
delay_ms:
        push cx
        mov  cx, 300
.dm_l:
        nop
        nop
        loop .dm_l
        pop  cx
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

; puthex MUST preserve CX: dump_rx calls it from inside a loop, and the shift
; below needs CL. Clobbering it there would corrupt the byte count.
puthex:
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
warn:
        push dx
        mov  dx, msg_warn
        call puts
        pop  dx
        ret

; ============================================================================
;  data
; ============================================================================
; GET_DESCRIPTOR(DEVICE), first 8 bytes -- all any device must answer at
; address 0, because 8 bytes fit in the smallest possible endpoint 0.
req_getdesc8:
        db 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x08, 0x00
; GET_DESCRIPTOR(DEVICE), all 18 bytes
req_getdesc18:
        db 0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00
; SET_ADDRESS(1)
req_setaddr:
        db 0x00, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00

msg_hdr    db 'USBTEST - USB host controller',13,10
           db '-----------------------------',13,10,'$'
msg_t1     db '1 registers respond            : $'
msg_t1b    db '1b buffer pointer per write    : $'
msg_t2     db '2 48 MHz PLL locked            : $'
msg_t3     db '3 idle line state (unplugged)  : $'
msg_t4     db '4 device detected              : $'
msg_t5     db '5 SOF generator running        : $'
msg_t6     db '6 bus reset, device survives   : $'
msg_t7     db '7 GET_DESCRIPTOR at address 0  : $'
msg_t8     db '8 SET_ADDRESS(1)               : $'
msg_t9     db '9 full descriptor at address 1 : $'
msg_pass   db 'PASS',13,10,'$'
msg_fail   db 'FAIL',13,10,'$'
msg_warn   db 'WARN',13,10,'$'
msg_crlf   db 13,10,'$'
msg_sp     db ' $'
msg_ind    db '    $'
msg_end    db 13,10,'done.',13,10,'$'

msg_noreg  db '  Port 0xE8-0xEF does not read back. Is this bitstream built',13,10
           db '  with usb_host.vhd in the project?',13,10,'$'
msg_nolock db '  The 48 MHz PLL never locked. Nothing else can work.',13,10,'$'
msg_lines  db '  D+/D- read $'
msg_bare   db '- bus idle, pulldowns working',13,10,'$'
msg_idlej  db '- idle J: full-speed device attached',13,10,'$'
msg_idlek  db '- idle K: low-speed device attached',13,10,'$'
msg_pulldn db '  BOTH lines high is not a valid USB state. No device does that,',13,10
           db '  so suspect the 15K pulldowns or the port wiring.',13,10,'$'
msg_nodev  db '  No device seen. Plug one into USB0 and run this again.',13,10,'$'
msg_lowspd db '  Low-speed device (D- pulled up). This controller is',13,10
           db '  full-speed only -- mass storage is never low speed.',13,10,'$'
msg_fsdev  db '  full-speed device on USB0',13,10,'$'
msg_nosof  db '  Frame counter did not advance. The 48 MHz domain is not',13,10
           db '  running even though the PLL claims lock.',13,10,'$'
msg_gone   db '  Device vanished after the reset.',13,10,'$'
msg_nodesc db '  No descriptor came back.',13,10,'$'
msg_noaddr db '  SET_ADDRESS was not accepted.',13,10,'$'
msg_desc8  db '  first 8 bytes:',13,10,'$'
msg_ptr    db '  after 8 writes the pointer reads $'
msg_ptrwhy db '  Expected 8. A larger value means each write is firing more',13,10
           db '  than once, so packet data is being duplicated.',13,10,'$'
msg_status db '  status = $'
msg_rxpid  db ' last RX PID = $'
msg_stgsetup db '  The SETUP stage failed - the device rejected or ignored the',13,10
             db '  8-byte request packet.',13,10,'$'
msg_stgin    db '  The SETUP stage was ACKed, but the IN data stage failed.',13,10,'$'
msg_nak    db 'NAK $'
msg_stall  db 'STALL $'
msg_tmo    db 'TIMEOUT $'
msg_err    db 'CRC/PID-ERROR $'
msg_vid    db '  VID:PID = $'
msg_pid    db ':$'
msg_class  db '  class   = $'
msg_massst db '(mass storage)$'
msg_periface db '(per interface)$'
msg_mps    db '  ep0 max packet = $'

descbuf    times 20 db 0
