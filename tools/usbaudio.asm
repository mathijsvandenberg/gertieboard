; ============================================================================
;  usbaudio.asm -- point a USB Audio Class device at the AdLib output
;
;  This program is NOT a driver and NOT a TSR. It enumerates the device,
;  chooses an alternate setting, tells the hardware where to send audio, and
;  exits. Sound keeps playing after it returns, and keeps playing inside a game
;  that has taken over the machine.
;
;  That is the whole reason the streamer lives in fabric. An isochronous
;  endpoint has a 1 ms deadline and no retry: miss the frame and that audio is
;  gone, there is no ACK and nothing to resend. A TSR on the timer tick cannot
;  promise 1 ms service on a machine where a game owns the interrupts and the
;  CPU is a V20 at 10 MHz -- and every miss would be an audible click. So the
;  CPU never touches a sample here. opl2_lite renders 48 kHz PCM straight into
;  usb2's double buffer and the sequencer ships one packet per frame on its
;  own; this program only sets four registers and gets out of the way.
;
;  WHY 48 kHz WHEN THE OPL2 IS 49716 Hz
;
;  A USB frame is exactly 1 ms, so the sample rate has to divide by 1000 to put
;  a whole number of samples in every frame. 49716 does not; 48000 does, at 48
;  samples. The alternative is a rate the device does not offer and a fractional
;  packet size that has to be 47 samples some frames and 48 others -- which is
;  what real sound cards do, and it needs a feedback endpoint to steer it. Here
;  the PCM tap simply renders at 48 kHz and scales its phase increments by
;  49716/48000 so the PITCH is unchanged. Nothing downstream has to adapt.
;
;  WHY STEREO FOR A MONO SYNTHESISER
;
;  Practically every UAC device on sale is 16-bit stereo and offers no mono
;  alternate setting. The hardware duplicates each sample into both channels.
;  It doubles the bytes on the wire to say the same thing twice, and it is
;  still the only thing that interoperates.
;
;  THE TRAP THIS TOOL EXISTS TO AVOID
;
;  Alternate setting 0 of an audio streaming interface is REQUIRED to have no
;  isochronous endpoint and no bandwidth -- it is the "idle" setting, so an
;  audio device that nobody is using costs the bus nothing. Enumerate, leave
;  the interface at its default alt 0, and everything looks perfect: the device
;  is configured, the descriptors are right, no error is reported anywhere, and
;  there is silence. SET_INTERFACE to a non-zero alt is what actually opens the
;  pipe, and forgetting it is the single most common way to get a UAC device
;  that enumerates beautifully and plays nothing.
;
;  Usage:  USBAUDIO [0|1] [Gn] [S]
;            0 / 1   which USB port (default 1, the hybrid port)
;            Gn      gain, n = 0..7, a right shift. 0 is loudest, default 1
;            S       stop: disable streaming and exit
; ============================================================================

        CPU 8086
        org  0x100

; ---- usb_host register window ----------------------------------------------
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

; ---- usb_audio register window ---------------------------------------------
A_BASE  equ 0x00A0
A_CTL   equ A_BASE+0            ; W [0] EN [1] CLRERR   R [0] EN [1] UNDER
A_ADDR  equ A_BASE+1
A_ENDP  equ A_BASE+2
A_NSMP  equ A_BASE+3
A_GAIN  equ A_BASE+4
A_UNDN  equ A_BASE+5            ; R underrun count

AC_EN     equ 0x01
AC_CLRERR equ 0x02
AS_UNDER  equ 0x02

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
ST_RXV   equ 0x80

C_RESET  equ 0x02
C_SOFEN  equ 0x04
C_LOWSP  equ 0x10

L_FS     equ 0x04
L_LS     equ 0x08

DT_DEVICE equ 1
DT_CONFIG equ 2
DT_IFACE  equ 4
DT_ENDP   equ 5
DT_CS_IFACE equ 0x24

; audio class codes
AC_AUDIO   equ 0x01             ; bInterfaceClass
AS_STREAM  equ 0x02             ; bInterfaceSubClass = AUDIOSTREAMING
FORMAT_TYPE equ 0x02            ; CS_INTERFACE bDescriptorSubtype

%macro SETDX 1
        mov  dx, [ubase]
        add  dl, %1
%endmacro

; ============================================================================
start:
        mov  dx, msg_hdr
        call puts

; ---------------- arguments -------------------------------------------------
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
        jmp  short .snext
.s1:
        cmp  al, 'S'
        je   .sstop
        cmp  al, 's'
        je   .sstop
        cmp  al, 'G'
        je   .sgain
        cmp  al, 'g'
        jne  .snext
.sgain:
        ; the digit after G, if there is one
        cmp  cx, 1
        jbe  .snext
        mov  al, [si]
        sub  al, '0'
        cmp  al, 7
        ja   .snext
        mov  [gain], al
        jmp  short .snext
.sstop:
        mov  byte [stopreq], 1
.snext:
        loop .scan
.parsed:

        cmp  byte [stopreq], 0
        je   .go
        ; ---- stop: silence is one register write ----
        mov  dx, A_CTL
        xor  al, al
        out  dx, al
        mov  dx, msg_stopped
        call puts
        jmp  quit
.go:

; ---------------- is the streamer even in this bitstream? -------------------
; A build without AUDIO=true answers the 0xA0 window with a floating bus, and
; every write below would be swallowed in silence -- which is indistinguishable
; from a device that will not play. The signature makes it distinguishable.
        mov  dx, A_CTL
        in   al, dx
        and  al, 0xF0
        cmp  al, 0xA0
        je   .haveaud
        mov  dx, msg_noaud
        call puts
        jmp  quit
.haveaud:

; ---------------- bring the port up -----------------------------------------
; CTRL persists across programs and LINE reports the engine's SWAPPED view of
; the pins once low speed is set, so a leftover bit 4 from a previous tool
; makes a full-speed device read as low speed. Clear it before believing LINE.
        SETDX O_CTRL
        xor  al, al
        out  dx, al
        call delay_tick

        SETDX O_CTRL
        in   al, dx
        mov  [line], al
        test al, L_FS
        jnz  .isfs
        test al, L_LS
        jz   .nodev
        ; A low-speed device cannot be a UAC1 audio device: 1.5 Mbps carries
        ; 187 bytes a frame at best and the class is defined as full speed.
        ; Saying so is more useful than letting it fail at SET_INTERFACE.
        mov  dx, msg_islow
        call puts
        jmp  quit
.nodev:
        mov  dx, msg_nodev
        call puts
        jmp  quit
.isfs:

        ; bus reset, held well past the 10 ms minimum
        SETDX O_CTRL
        mov  al, C_RESET
        out  dx, al
        call delay_tick
        SETDX O_CTRL
        mov  al, C_SOFEN
        out  dx, al
        call delay_tick

; ---------------- address 0: how big is EP0? --------------------------------
        mov  byte [ep0max], 8
        xor  al, al
        SETDX O_ADDR
        out  dx, al

        mov  si, sp_getdev8
        mov  di, devbuf
        mov  cx, 8
        call ctl_read
        jc   .e_desc
        cmp  cx, 8
        jb   .e_desc
        mov  al, [devbuf+7]             ; bMaxPacketSize0
        test al, al
        jz   .e_desc
        mov  [ep0max], al

; ---------------- give it an address ----------------------------------------
        mov  si, sp_setaddr
        xor  cx, cx
        call ctl_read
        jc   .e_addr
        call delay_tick
        mov  al, 1
        SETDX O_ADDR
        out  dx, al

; ---------------- configuration descriptor ----------------------------------
        mov  si, sp_getcfg9
        mov  di, cfgbuf
        mov  cx, 9
        call ctl_read
        jc   .e_cfg
        mov  ax, [cfgbuf+2]             ; wTotalLength
        cmp  ax, CFGMAX
        jbe  .cfgfits
        mov  ax, CFGMAX
.cfgfits:
        mov  [cfglen], ax
        mov  [sp_getcfgn+6], ax         ; wLength of the full request
        mov  si, sp_getcfgn
        mov  di, cfgbuf
        mov  cx, ax
        call ctl_read
        jc   .e_cfg
        mov  [cfglen], cx

; ---------------- find an audio streaming alternate setting -----------------
        call find_alt
        jc   .e_noalt

; ---------------- configure -------------------------------------------------
        mov  al, [cfgbuf+5]             ; bConfigurationValue
        mov  [sp_setcfg+2], al
        mov  si, sp_setcfg
        xor  cx, cx
        call ctl_read
        jc   .e_setcfg
        call delay_tick

; ---------------- THE line that makes sound come out ------------------------
        mov  al, [ifnum]
        mov  [sp_setif+4], al
        mov  al, [altnum]
        mov  [sp_setif+2], al
        mov  si, sp_setif
        xor  cx, cx
        call ctl_read
        jc   .e_setif
        call delay_tick

; ---------------- ask for 48000 Hz ------------------------------------------
; Optional: a device with exactly one supported rate need not implement the
; sampling frequency control, and answers STALL. That is legal and not fatal --
; it is already running at the only rate it has, which find_alt checked is
; 48000. So a failure here is reported and stepped over rather than fatal.
        mov  al, [epaddr]
        mov  [sp_setrate+4], al
        call set_rate
        jnc  .rateok
        mov  dx, msg_norate
        call puts
.rateok:

; ---------------- hand the endpoint to the hardware -------------------------
        mov  dx, A_ADDR
        mov  al, 1                      ; the address we assigned above
        out  dx, al
        mov  dx, A_ENDP
        mov  al, [epaddr]
        and  al, 0x0F                   ; endpoint number, without the direction
        out  dx, al
        mov  dx, A_NSMP
        mov  al, 48                     ; 48 kHz / 1000 frames
        out  dx, al
        mov  dx, A_GAIN
        mov  al, [gain]
        out  dx, al
        ; clear any stale underrun, THEN enable, so the count means this run
        mov  dx, A_CTL
        mov  al, AC_CLRERR
        out  dx, al
        mov  dx, A_CTL
        mov  al, AC_EN
        out  dx, al

; ---------------- say what happened -----------------------------------------
        mov  dx, msg_ok
        call puts
        mov  dx, msg_iface
        call puts
        mov  al, [ifnum]
        call puthex
        mov  dx, msg_alt
        call puts
        mov  al, [altnum]
        call puthex
        mov  dx, msg_ep
        call puts
        mov  al, [epaddr]
        call puthex
        mov  dx, msg_mps
        call puts
        mov  ax, [epmax]
        call puthex16
        mov  dx, msg_crlf
        call puts

        mov  dx, msg_fmt
        call puts
        mov  al, [nrch]
        call putdec
        mov  dx, msg_ch
        call puts
        mov  al, [nbits]
        call putdec
        mov  dx, msg_bits
        call puts

        ; A device that accepted everything and still underruns is reporting a
        ; wiring fault, not a marginal rate -- both clocks come from the same
        ; PLL. Give it a frame or two to prove it, then look once.
        call delay_tick
        mov  dx, A_CTL
        in   al, dx
        test al, AS_UNDER
        jz   .noerr
        mov  dx, msg_under
        call puts
.noerr:
        mov  dx, msg_playing
        call puts
        jmp  quit

; ---------------- failures --------------------------------------------------
.e_desc:
        mov  dx, msg_edesc
        call puts
        jmp  quit
.e_addr:
        mov  dx, msg_eaddr
        call puts
        jmp  quit
.e_cfg:
        mov  dx, msg_ecfg
        call puts
        jmp  quit
.e_noalt:
        mov  dx, msg_enoalt
        call puts
        jmp  quit
.e_setcfg:
        mov  dx, msg_esetcfg
        call puts
        jmp  quit
.e_setif:
        mov  dx, msg_esetif
        call puts
        jmp  quit

quit:
        mov  ah, 0x4C
        xor  al, al
        int  0x21

; ============================================================================
;  find_alt -- walk the configuration descriptor for a usable alt setting
;
;  Returns CF clear and ifnum / altnum / epaddr / epmax / nrch / nbits filled.
;
;  A configuration descriptor is a flat list of variable-length blocks, each
;  starting with its own length. Walking it by bLength rather than by looking
;  for known types is what makes it safe to skip the class-specific blocks this
;  program does not understand -- and there are a lot of them on an audio
;  device: input terminals, output terminals, feature units, selector units.
;  A parser that assumed a fixed layout would work on one dongle and nothing
;  else.
;
;  Requirements, all of which must hold on the SAME alternate setting:
;    interface class 1 subclass 2 (AUDIOSTREAMING), bAlternateSetting != 0
;    a FORMAT_TYPE block saying 2 channels, 16 bits, and 48000 Hz available
;    an ISOCHRONOUS OUT endpoint whose wMaxPacketSize can hold 192 bytes
; ============================================================================
find_alt:
        push ax
        push bx
        push cx
        push si
        mov  si, cfgbuf
        mov  cx, [cfglen]
        mov  byte [cand], 0
        mov  byte [fmtok], 0

.walk:
        cmp  cx, 2
        jb   .nomatch
        mov  al, [si]                   ; bLength
        test al, al
        jz   .nomatch                   ; a zero length would loop forever
        ; Bound the block against the bytes REMAINING, 16 bits wide. Comparing
        ; against CL alone reads the low byte of the count: with 256 bytes left
        ; CL is 0 and every descriptor looks like it overruns, so the walk
        ; stopped dead at the first block. Audio configuration descriptors are
        ; routinely over 256 bytes -- terminals, feature units and a format
        ; block per alternate setting -- so this is the normal case, not an
        ; edge one.
        xor  ah, ah
        cmp  ax, cx
        ja   .nomatch                   ; runs past the end: malformed
        mov  bl, [si+1]                 ; bDescriptorType

        cmp  bl, DT_IFACE
        jne  .nf_iface
        ; a new interface ends whatever candidate was in progress
        mov  byte [cand], 0
        mov  byte [fmtok], 0
        mov  al, [si+5]                 ; bInterfaceClass
        cmp  al, AC_AUDIO
        jne  .next
        mov  al, [si+6]                 ; bInterfaceSubClass
        cmp  al, AS_STREAM
        jne  .next
        mov  al, [si+3]                 ; bAlternateSetting
        test al, al
        jz   .next                      ; alt 0 is the idle setting, never it
        mov  [altnum], al
        mov  al, [si+2]                 ; bInterfaceNumber
        mov  [ifnum], al
        mov  byte [cand], 1
        jmp  short .next

.nf_iface:
        cmp  bl, DT_CS_IFACE
        jne  .nf_cs
        cmp  byte [cand], 0
        je   .next
        cmp  al, 8                      ; FORMAT_TYPE_I is at least 8 bytes
        jb   .next
        mov  bl, [si+2]                 ; bDescriptorSubtype
        cmp  bl, FORMAT_TYPE
        jne  .next
        mov  bl, [si+4]                 ; bNrChannels
        mov  [nrch], bl
        cmp  bl, 2
        jne  .next                      ; mono alt settings are vanishingly rare
        mov  bl, [si+6]                 ; bBitResolution
        mov  [nbits], bl
        cmp  bl, 16
        jne  .next
        call has_48k
        jc   .next
        mov  byte [fmtok], 1
        jmp  short .next

.nf_cs:
        cmp  bl, DT_ENDP
        jne  .next
        cmp  byte [cand], 0
        je   .next
        cmp  byte [fmtok], 0
        je   .next
        mov  bl, [si+3]                 ; bmAttributes
        and  bl, 0x03
        cmp  bl, 0x01                   ; transfer type 01 = isochronous
        jne  .next
        mov  bl, [si+2]                 ; bEndpointAddress
        test bl, 0x80
        jnz  .next                      ; IN is a recording endpoint, not ours
        mov  [epaddr], bl
        mov  bx, [si+4]                 ; wMaxPacketSize
        and  bx, 0x07FF                 ; low 11 bits are the size
        mov  [epmax], bx
        cmp  bx, 192
        jb   .next                      ; cannot carry a 48-sample stereo frame
        clc
        jmp  short .out

.next:
        mov  al, [si]
        xor  ah, ah
        add  si, ax
        sub  cx, ax
        jmp  .walk

.nomatch:
        stc
.out:
        pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

; ============================================================================
;  has_48k -- does the FORMAT_TYPE block at DS:SI offer 48000 Hz?
;
;  bSamFreqType 0 means a continuous RANGE given as two 3-byte values, min then
;  max; anything else is that many discrete 3-byte values. Both encodings are
;  common and a parser that handles only the discrete list rejects perfectly
;  good hardware. Frequencies are 24-bit little-endian, and 48000 = 0x00BB80.
; ============================================================================
has_48k:
        push ax
        push bx
        push cx
        push si
        mov  bl, [si+7]                 ; bSamFreqType
        add  si, 8
        test bl, bl
        jnz  .discrete

        ; continuous: min <= 48000 <= max
        call rd24                       ; -> DX:AX
        cmp  dx, 0
        jne  .no                        ; a min above 65535*... is not our rate
        cmp  ax, 0xBB80
        ja   .no
        add  si, 3
        call rd24
        cmp  dx, 0
        jne  .yes                       ; max is well above 48000
        cmp  ax, 0xBB80
        jb   .no
        jmp  short .yes

.discrete:
        xor  bh, bh
        mov  cx, bx
.dl:
        call rd24
        cmp  dx, 0
        jne  .dnext
        cmp  ax, 0xBB80
        je   .yes
.dnext:
        add  si, 3
        loop .dl
.no:
        stc
        jmp  short .out
.yes:
        clc
.out:
        pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

; rd24: 24-bit little-endian at DS:SI -> DX:AX (DX = high byte)
rd24:
        mov  ax, [si]
        mov  dl, [si+2]
        xor  dh, dh
        ret

; ============================================================================
;  set_rate -- SET_CUR on the endpoint's sampling frequency control
;
;  A class request with a three-byte OUT data stage, which is the only
;  control-write-with-data in this program; ctl_read moves data on IN only.
; ============================================================================
set_rate:
        push ax
        push bx
        push cx
        push dx
        push si

        xor  al, al
        SETDX O_ENDP
        out  dx, al

        call setptr
        mov  si, sp_setrate
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

        ; data stage: three bytes, DATA1
        call setptr
        mov  si, rate48k
        mov  cx, 3
        SETDX O_DATA
.fill2:
        lodsb
        out  dx, al
        loop .fill2
        mov  al, 3
        SETDX O_LEN
        out  dx, al
        mov  al, OP_OUT | GO | DATA1
        call txn
        jc   .bad
        test al, ST_ACK
        jz   .bad

        ; status stage is IN for a host-to-device transfer
        call setptr
        xor  al, al
        SETDX O_LEN
        out  dx, al
        mov  al, OP_IN | GO | DATA1
        call txn
        jc   .bad
        clc
        jmp  short .out
.bad:
        stc
.out:
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ============================================================================
;  ctl_read -- one complete control transfer (IN data stage, or none)
;    DS:SI = 8-byte setup packet
;    ES:DI = destination for the data stage (ignored when CX = 0)
;    CX    = bytes wanted, 0 for no data stage
;  Returns CF set on failure, CX = bytes actually moved.
; ============================================================================
ctl_read:
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

        xor  bx, bx
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
        mov  cx, ax
        jcxz .cr_status
        push cx
        call setptr
        SETDX O_DATA
.cr_copy:
        in   al, dx
        stosb
        inc  bx
        loop .cr_copy
        pop  cx
        ; SHORT PACKET is shorter than the ENDPOINT's max, not shorter than 64
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
        out  dx, al
        mov  al, [reqtype]
        test al, 0x80
        jz   .cr_st_in
        mov  al, OP_OUT | GO | DATA1
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
;  txn / wait_done / setptr / delay_tick -- as in usbenum, unchanged
; ============================================================================
txn:
        push bx
        push cx
        push dx
        mov  bl, al
        mov  bh, 3
.tx_attempt:
        mov  cx, 400
.tx_try:
        push cx
        mov  al, bl
        SETDX O_CMD
        out  dx, al
        call wait_done
        pop  cx
        jc   .tx_fail
        test al, ST_NAK
        jz   .tx_settled
        loop .tx_try
        jmp  short .tx_fail
.tx_settled:
        test al, ST_STALL
        jnz  .tx_fail
        test al, ST_ERR | ST_TMO
        jz   .tx_ok
        dec  bh
        jnz  .tx_attempt
        jmp  short .tx_fail
.tx_ok:
        clc
        jmp  short .tx_out
.tx_fail:
        stc
.tx_out:
        pop  dx
        pop  cx
        pop  bx
        ret

wait_done:
        push cx
        push dx
        mov  cx, 0
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

setptr:
        push ax
        push dx
        xor  al, al
        SETDX O_PTR
        out  dx, al
        pop  dx
        pop  ax
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
.dt_l:
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
;  output
; ============================================================================
puts:
        push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthex:
        push ax
        push cx
        push dx
        mov  cl, al
        shr  al, 1
        shr  al, 1
        shr  al, 1
        shr  al, 1
        call .nyb
        mov  al, cl
        and  al, 0x0F
        call .nyb
        pop  dx
        pop  cx
        pop  ax
        ret
.nyb:
        add  al, '0'
        cmp  al, '9'
        jbe  .pr
        add  al, 7
.pr:
        mov  dl, al
        mov  ah, 2
        int  0x21
        ret

puthex16:
        push ax
        mov  al, ah
        call puthex
        pop  ax
        call puthex
        ret

; putdec: AL unsigned, no leading zeros. Divide and PUSH the digits -- the
; obvious version calls INT 21h with the remainder still in AH and loses it.
putdec:
        push ax
        push bx
        push cx
        push dx
        xor  ah, ah
        mov  bx, 10
        xor  cx, cx
.pd_div:
        xor  dx, dx
        div  bx
        push dx
        inc  cx
        test ax, ax
        jnz  .pd_div
.pd_out:
        pop  dx
        add  dl, '0'
        mov  ah, 2
        int  0x21
        loop .pd_out
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ============================================================================
;  data
; ============================================================================
ubase   dw 0
line    db 0
ep0max  db 8
reqtype db 0
gain    db 1
stopreq db 0

ifnum   db 0
altnum  db 0
epaddr  db 0
epmax   dw 0
nrch    db 0
nbits   db 0
cand    db 0
fmtok   db 0
cfglen  dw 0

; ---- setup packets ----
sp_getdev8   db 0x80, 6, 0x00, DT_DEVICE, 0, 0, 8, 0
sp_setaddr   db 0x00, 5, 1, 0, 0, 0, 0, 0
sp_getcfg9   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 9, 0
sp_getcfgn   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 0, 0
sp_setcfg    db 0x00, 9, 1, 0, 0, 0, 0, 0
; SET_INTERFACE: wValue = alternate setting, wIndex = interface number
sp_setif     db 0x01, 11, 0, 0, 0, 0, 0, 0
; SET_CUR to an ENDPOINT: bmRequestType 0x22, wValue = SAMPLING_FREQ_CONTROL
; (0x0100), wIndex = endpoint address, wLength = 3
sp_setrate   db 0x22, 0x01, 0x00, 0x01, 0, 0, 3, 0
rate48k      db 0x80, 0xBB, 0x00        ; 48000, 24-bit little-endian

msg_hdr      db 'USBAUDIO -- AdLib to a USB Audio Class device', 13, 10, '$'
msg_nodev    db 'no device on the port', 13, 10, '$'
msg_islow    db 'low-speed device: USB Audio Class is full speed only', 13, 10, '$'
msg_noaud    db 'this bitstream has no audio streamer (0xA0 reads wrong)', 13, 10
             db 'rebuild with AUDIO => true on usb2', 13, 10, '$'
msg_edesc    db 'failed reading the device descriptor', 13, 10, '$'
msg_eaddr    db 'SET_ADDRESS failed', 13, 10, '$'
msg_ecfg     db 'failed reading the configuration descriptor', 13, 10, '$'
msg_enoalt   db 'no usable alternate setting: needs isochronous OUT,', 13, 10
             db '2 channels, 16 bits, 48000 Hz, 192-byte packets', 13, 10, '$'
msg_esetcfg  db 'SET_CONFIGURATION failed', 13, 10, '$'
msg_esetif   db 'SET_INTERFACE failed -- the pipe never opened', 13, 10, '$'
msg_norate   db 'note: SET_CUR rate refused; using the device default', 13, 10, '$'
msg_ok       db 'configured: ', '$'
msg_iface    db 'iface ', '$'
msg_alt      db '  alt ', '$'
msg_ep       db '  ep ', '$'
msg_mps      db '  maxpkt ', '$'
msg_fmt      db 'format:     ', '$'
msg_ch       db ' channels, ', '$'
msg_bits     db ' bits, 48000 Hz', 13, 10, '$'
msg_under    db 'WARNING: underrun flagged -- check CLK48 reaches opl2_lite', 13, 10, '$'
msg_playing  db 'streaming. AdLib output now goes to USB. USBAUDIO S stops it.', 13, 10, '$'
msg_stopped  db 'streaming disabled', 13, 10, '$'
msg_crlf     db 13, 10, '$'

CFGMAX  equ 512
cfgbuf  times CFGMAX db 0
devbuf  times 32 db 0
