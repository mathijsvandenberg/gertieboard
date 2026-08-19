; ============================================================================
;  usbfdd.asm -- read a real diskette through a USB floppy drive
;
;  First milestone of USB floppy support: enumerate the drive, run the CBI
;  transport, issue UFI commands, work out which medium is in it, and dump a
;  sector. Once sectors move reliably this moves into the BIOS as drive B:,
;  overriding the SPI flash when a drive is present.
;
;  It is a DOS tool first for the same reason usbenum and usbkbd were: a wrong
;  guess costs a re-assemble and a re-run, not a BIOS reflash and a power cycle.
;
;  WHY THIS IS NOT THE MASS-STORAGE CODE THE BIOS ALREADY HAS
;
;  The BIOS drives the fixed disk on USB0 with Bulk-Only Transport: a 31-byte
;  CBW goes out on the bulk OUT endpoint, data moves, a 13-byte CSW comes back
;  on bulk IN. Three phases, two endpoints, one clear rule.
;
;  This drive is class 08 / subclass 04 / protocol 00 -- UFI over CBI, which
;  is a different transport with the same command set underneath:
;
;    COMMAND   a CONTROL transfer, not a bulk one: bmRequestType 0x21,
;              bRequest 0x00 (ADSC, "accept device-specific command"),
;              wIndex = the interface, carrying the 12-byte command block
;    DATA      bulk IN or bulk OUT, exactly as before
;    STATUS    two bytes on an INTERRUPT IN endpoint -- not a CSW on bulk
;
;  So u_bulk_in / u_bulk_out and the READ(10) command block are reusable as
;  they stand; the wrapper around them is not. That is the whole difference,
;  and it is why this is a transport to write rather than a rewrite.
;
;  For UFI the two status bytes are ASC and ASCQ -- the same codes REQUEST
;  SENSE would give. Both zero means the command worked.
;
;  720K AND 1.44MB ARE THE SAME CODE PATH
;
;  The drive does the low-level format. It reports 512-byte blocks and a count,
;  and the count is the only thing that differs:
;
;      2880 blocks = 1.44 MB   80 cyl, 2 heads, 18 sectors
;      1440 blocks = 720 KB    80 cyl, 2 heads,  9 sectors
;
;  So there is one driver, not two, and the geometry falls out of READ CAPACITY.
;
;  A NAK IS NOT AN ERROR. It means "ask again" -- and a floppy drive is a
;  microcontroller with a motor that runs a self-test before it will talk. The
;  first attempt at this device failed on a NAK budget tuned for flash sticks.
;
;  Usage:  USBFDD [0|1] [Snnn]
;            0 / 1   which USB port (default 1)
;            Snnn    dump logical sector nnn instead of 0
; ============================================================================

        CPU 8086
        org  0x100

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

DT_DEVICE equ 1
DT_CONFIG equ 2
DT_IFACE  equ 4
DT_ENDP   equ 5

; mass storage class codes
MS_CLASS equ 0x08
MS_UFI   equ 0x04               ; subclass: floppy command set
MS_CBI   equ 0x00               ; protocol: CBI with command completion int

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
        test cx, cx
        jnz  .scan
        jmp  .parsed
.scan:
        lodsb
        cmp  al, '0'
        jne  .s1
        mov  word [ubase], BASE_P0
        jmp  short .snext
.s1:
        cmp  al, 'S'
        je   .ssec
        cmp  al, 's'
        jne  .snext
.ssec:
        ; decimal sector number follows
        xor  bx, bx
.sd_l:
        cmp  cx, 1
        jbe  .sd_done
        mov  al, [si]
        cmp  al, '0'
        jb   .sd_done
        cmp  al, '9'
        ja   .sd_done
        sub  al, '0'
        xchg ax, bx
        mov  dx, 10
        mul  dx
        xchg ax, bx
        xor  ah, ah
        add  bx, ax
        inc  si
        dec  cx
        jmp  short .sd_l
.sd_done:
        mov  [seclo], bx
.snext:
        dec  cx
        jz   .pdone
        jmp  .scan
.pdone:
.parsed:

; ---------------- bring the port up -----------------------------------------
        SETDX O_CTRL
        xor  al, al
        out  dx, al
        mov  cx, 2
        call delay_ticks

        SETDX O_CTRL
        in   al, dx
        test al, L_FS
        jnz  .isfs
        test al, L_LS
        jz   .e_nodev
        mov  dx, msg_islow
        call puts
        jmp  quit
.e_nodev:
        mov  dx, msg_nodev
        call puts
        jmp  quit
.isfs:
        SETDX O_CTRL
        mov  al, C_RESET
        out  dx, al
        mov  cx, 2
        call delay_ticks                ; >= 55 ms of SE0
        SETDX O_CTRL
        mov  al, C_SOFEN
        out  dx, al
        ; The drive runs a self-test before it will answer. Be patient here or
        ; the first descriptor request NAKs out and it looks dead.
        mov  cx, 8
        call delay_ticks

; ---------------- enumerate --------------------------------------------------
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
        mov  al, [devbuf+7]
        test al, al
        jz   .e_desc
        mov  [ep0max], al

        mov  si, sp_setaddr
        xor  cx, cx
        call ctl_read
        jc   .e_addr
        mov  cx, 2
        call delay_ticks
        mov  al, 1
        SETDX O_ADDR
        out  dx, al

        mov  si, sp_getdev18
        mov  di, devbuf
        mov  cx, 18
        call ctl_read
        jc   .e_desc
        mov  dx, msg_vid
        call puts
        mov  ax, [devbuf+8]
        call puthex16
        mov  dl, ':'
        mov  ah, 2
        int  0x21
        mov  ax, [devbuf+10]
        call puthex16
        mov  dx, msg_ep0
        call puts
        mov  al, [ep0max]
        call putdec8
        mov  dx, msg_crlf
        call puts

        mov  si, sp_getcfg9
        mov  di, cfgbuf
        mov  cx, 9
        call ctl_read
        jc   .e_cfg
        mov  ax, [cfgbuf+2]
        cmp  ax, CFGMAX
        jbe  .cfgfits
        mov  ax, CFGMAX
.cfgfits:
        mov  [sp_getcfgn+6], ax
        mov  si, sp_getcfgn
        mov  di, cfgbuf
        mov  cx, ax
        call ctl_read
        jc   .e_cfg
        mov  [cfglen], cx

        call find_ufi
        jc   .e_noufi

        mov  dx, msg_found
        call puts
        mov  al, [ifnum]
        call puthex
        mov  dx, msg_eps
        call puts
        mov  al, [ep_in]
        call puthex
        mov  dl, '/'
        mov  ah, 2
        int  0x21
        mov  al, [ep_out]
        call puthex
        mov  dl, '/'
        mov  ah, 2
        int  0x21
        mov  al, [ep_int]
        call puthex
        mov  dx, msg_crlf
        call puts

        mov  al, [cfgbuf+5]
        mov  [sp_setcfg+2], al
        mov  si, sp_setcfg
        xor  cx, cx
        call ctl_read
        jc   .e_setcfg
        mov  cx, 2
        call delay_ticks
        ; SET_CONFIGURATION resets every endpoint's data toggle to DATA0. Ours
        ; must be reset to match or the first bulk packet is discarded.
        mov  byte [tog_in], 0
        mov  byte [tog_out], 0

; ---------------- is there a disk in it? -------------------------------------
; TEST UNIT READY is expected to FAIL the first time, and that is not a fault.
; Removable media always reports UNIT ATTENTION ("the medium may have changed")
; on the first command after power-up or a disk swap, and it stays there until
; something reads the sense data. So: ask, read the sense to clear it, ask
; again. A driver that treats the first failure as "no disk" never sees a disk.
        mov  dx, msg_tur
        call puts
        mov  si, cmd_tur
        call ufi_nodata
        pushf
        mov  dx, msg_t1
        call ufi_trace
        popf
        jnc  .ready

        call ufi_sense                  ; clears UNIT ATTENTION
        mov  dx, msg_t2
        call ufi_trace
        call dump_sense

        ; ---- spin it up, then WAIT FOR IT ----
        ; A floppy is a mechanism. The first TUR after a reset was answered in
        ; milliseconds and could not have been anything but "no": the motor had
        ; not turned yet, so the drive had not sensed a medium. Asking twice in
        ; the same tens of milliseconds and concluding the drive is empty is
        ; the same impatience that made enumeration fail an hour ago.
        ;
        ; START STOP UNIT with the START bit asks for spin-up explicitly. It is
        ; allowed to fail -- not every drive implements it, and the poll below
        ; covers the ones that spin up on their own.
        mov  si, cmd_start
        call ufi_nodata
        mov  dx, msg_spin
        call puts

        mov  word [tries], 40           ; ~2.2 s, well past a real spin-up
.poll:
        mov  si, cmd_tur
        call ufi_nodata
        jnc  .ready
        mov  dl, '.'
        mov  ah, 2
        int  0x21
        mov  cx, 2
        call delay_ticks
        dec  word [tries]
        jnz  .poll
        mov  dx, msg_crlf
        call puts

        mov  dx, msg_t3
        call ufi_trace

        ; still not ready: report what the drive actually said
        call ufi_sense
        cmp  byte [stalled], 0
        je   .nr_plain
        mov  dx, msg_refused
        call puts
        jmp  short .nr_sense
.nr_plain:
        mov  dx, msg_notready
        call puts
.nr_sense:
        mov  dx, msg_sense
        call puts
        mov  al, [senbuf+2]             ; sense key
        and  al, 0x0F
        call puthex
        mov  dl, '/'
        mov  ah, 2
        int  0x21
        mov  al, [senbuf+12]            ; ASC
        call puthex
        mov  dl, '/'
        mov  ah, 2
        int  0x21
        mov  al, [senbuf+13]            ; ASCQ
        call puthex
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_phkey
        call puts
        ; 3A is "medium not present", which is worth saying in English because
        ; it is the one failure that is not a fault at all.
        cmp  byte [senbuf+12], 0x3A
        jne  .quit2
        mov  dx, msg_nodisk
        call puts
.quit2:
        ; DO NOT STOP HERE. TEST UNIT READY is a gate I chose, not one the
        ; drive imposed -- it may well answer READ FORMAT CAPACITIES and
        ; READ(10) perfectly well while refusing TUR. Stopping at the gate
        ; tells us nothing about the data path, and the data path is the thing
        ; being built. Carry on and let the drive refuse for itself.
        mov  dx, msg_anyway
        call puts
        jmp  short .probe
.ready:
        mov  dx, msg_ok
        call puts
.probe:

; ---------------- what does it say about the medium? -------------------------
; READ FORMAT CAPACITIES is the command that actually reports media state, and
; it is the one Windows always issues -- so it is the path these drives are
; tested on, and the one a TEAC mechanism is least likely to be odd about.
;
; The response is a 4-byte header then 8-byte descriptors. In the first
; descriptor, byte 4 bits 1:0 are the code:  01 unformatted, 10 formatted,
; 11 no cartridge. That is a direct answer, not an inference from a stall.
        mov  dx, msg_rfc
        call puts
        mov  si, cmd_rdfmt
        mov  di, fmtbuf
        mov  cx, 64
        call ufi_in
        jc   .rfc_bad
        mov  dx, msg_rfcraw
        call puts
        mov  si, fmtbuf
        mov  cx, 16
.rfc_l:
        lodsb
        call puthex
        mov  dl, ' '
        mov  ah, 2
        int  0x21
        loop .rfc_l
        mov  dx, msg_crlf
        call puts
        mov  al, [fmtbuf+8]             ; first descriptor's code byte
        and  al, 0x03
        mov  dx, msg_fmt_un
        cmp  al, 1
        je   .rfc_pr
        mov  dx, msg_fmt_fm
        cmp  al, 2
        je   .rfc_pr
        mov  dx, msg_fmt_no
        cmp  al, 3
        je   .rfc_pr
        mov  dx, msg_fmt_rs
.rfc_pr:
        call puts
        jmp  short .rfc_done
.rfc_bad:
        mov  dx, msg_rfcfail
        call puts
        call ufi_trace_bare
.rfc_done:

; ---------------- what is in it? ---------------------------------------------
        mov  si, cmd_readcap
        mov  di, capbuf
        mov  cx, 8
        call ufi_in
        jc   .e_cap

        ; READ CAPACITY returns the LAST LBA, big-endian, then the block size.
        ; Blocks = last + 1. Both fit in 16 bits for any floppy, so only the
        ; low half is used -- but the high half is checked, because a device
        ; reporting something enormous means we are talking to the wrong thing.
        mov  ax, [capbuf]               ; bytes 0,1 = high half, big-endian
        test ax, ax
        jnz  .e_cap
        mov  al, [capbuf+2]
        mov  ah, [capbuf+3]
        xchg al, ah                     ; big-endian -> little
        inc  ax
        mov  [nblocks], ax

        mov  dx, msg_blocks
        call puts
        mov  ax, [nblocks]
        call putdec16
        mov  dx, msg_x512
        call puts

        ; geometry from the block count -- the only thing that differs between
        ; the two media, and the drive has just told us which is loaded
        mov  ax, [nblocks]
        cmp  ax, 2880
        jne  .not144
        mov  byte [nsec], 18
        mov  dx, msg_144
        jmp  short .geom
.not144:
        cmp  ax, 1440
        jne  .unkgeom
        mov  byte [nsec], 9
        mov  dx, msg_720
        jmp  short .geom
.unkgeom:
        mov  byte [nsec], 18
        mov  dx, msg_unkgeom
.geom:
        call puts

; ---------------- read a sector ----------------------------------------------
        mov  dx, msg_reading
        call puts
        mov  ax, [seclo]
        call putdec16
        mov  dx, msg_crlf
        call puts

        ; READ(10): LBA and length are BIG-endian, unlike everything else the
        ; 8086 touches. Getting this backwards reads sector 0x0100 instead of 1
        ; and the result looks like a corrupted disk rather than a bad command.
        mov  ax, [seclo]
        mov  [cmd_read10+5], al         ; LBA low byte last
        mov  [cmd_read10+4], ah
        mov  word [cmd_read10+2], 0
        mov  byte [cmd_read10+7], 0
        mov  byte [cmd_read10+8], 1     ; one block

        mov  si, cmd_read10
        mov  di, secbuf
        mov  cx, 512
        call ufi_in
        jc   .e_read

        call dump
        mov  dx, msg_done
        call puts
        jmp  quit

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
.e_noufi:
        mov  dx, msg_enoufi
        call puts
        jmp  quit
.e_setcfg:
        mov  dx, msg_esetcfg
        call puts
        jmp  quit
.e_cap:
        mov  dx, msg_ecap
        call puts
        jmp  quit
.e_read:
        mov  dx, msg_eread
        call puts
        call ufi_sense
        mov  dx, msg_sense
        call puts
        mov  al, [senbuf+2]
        and  al, 0x0F
        call puthex
        mov  dl, '/'
        mov  ah, 2
        int  0x21
        mov  al, [senbuf+12]
        call puthex
        mov  dl, '/'
        mov  ah, 2
        int  0x21
        mov  al, [senbuf+13]
        call puthex
        mov  dx, msg_crlf
        call puts
        jmp  quit

quit:
        mov  ah, 0x4C
        xor  al, al
        int  0x21

; ============================================================================
;  find_ufi -- locate the UFI/CBI interface and its three endpoints
;
;  CBI needs THREE endpoints, and the interrupt one is what makes it CBI:
;    bulk IN    data coming from the drive
;    bulk OUT   data going to it
;    interrupt IN   two bytes of command status, in place of a CSW
;
;  Walking by bLength rather than assuming a layout, as always -- it is what
;  makes it safe to step over blocks this program does not understand.
; ============================================================================
find_ufi:
        push ax
        push bx
        push cx
        push si
        mov  si, cfgbuf
        mov  cx, [cfglen]
        mov  byte [cand], 0
        mov  byte [ep_in], 0
        mov  byte [ep_out], 0
        mov  byte [ep_int], 0
.walk:
        cmp  cx, 2
        jb   .done
        mov  al, [si]
        test al, al
        jz   .done
        xor  ah, ah
        cmp  ax, cx
        ja   .done
        mov  bl, [si+1]

        cmp  bl, DT_IFACE
        jne  .nf_if
        mov  byte [cand], 0
        mov  al, [si+5]                 ; bInterfaceClass
        cmp  al, MS_CLASS
        jne  .next
        mov  al, [si+6]                 ; bInterfaceSubClass
        cmp  al, MS_UFI
        jne  .next
        mov  al, [si+7]                 ; bInterfaceProtocol
        cmp  al, MS_CBI
        jne  .next
        mov  al, [si+2]
        mov  [ifnum], al
        mov  byte [cand], 1
        jmp  short .next

.nf_if:
        cmp  bl, DT_ENDP
        jne  .next
        cmp  byte [cand], 0
        je   .next
        mov  bl, [si+3]                 ; bmAttributes
        and  bl, 0x03
        mov  bh, [si+2]                 ; bEndpointAddress
        cmp  bl, 0x02                   ; bulk
        jne  .nf_bulk
        test bh, 0x80
        jz   .isout
        mov  [ep_in], bh
        jmp  short .next
.isout:
        mov  [ep_out], bh
        jmp  short .next
.nf_bulk:
        cmp  bl, 0x03                   ; interrupt
        jne  .next
        test bh, 0x80
        jz   .next
        mov  [ep_int], bh
        jmp  short .next

.next:
        mov  al, [si]
        xor  ah, ah
        add  si, ax
        sub  cx, ax
        jmp  .walk

.done:
        ; all three are required -- a missing interrupt endpoint means this is
        ; not CBI after all and the status phase would hang waiting for it
        cmp  byte [ep_in], 0
        je   .none
        cmp  byte [ep_out], 0
        je   .none
        cmp  byte [ep_int], 0
        je   .none
        clc
        jmp  short .out
.none:
        stc
.out:
        pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

; ============================================================================
;  note_fail -- AL = phase code. Latches the engine's raw STATUS and RXPID.
;
;  "It failed" is not a diagnosis. RXPID says what actually came back off the
;  wire rather than how the status bits classified it, and it is what turned
;  the last dead-device mystery into a one-line fix -- a NAK reads as 5A and
;  means the device is fine and asking for more time, which is the opposite of
;  what "FAILED" suggests.
; ============================================================================
note_fail:
        push ax
        push dx
        mov  [fail_ph], al
        SETDX O_CMD
        in   al, dx
        mov  [fail_st], al
        ; A STALL on the ADSC request is the DEVICE REFUSING THE COMMAND, not
        ; the transport breaking. This drive answers TEST UNIT READY with a
        ; stall when there is no diskette in it -- the reason is then in the
        ; sense data, and REQUEST SENSE still works because that command is
        ; always answerable. Conflating "refused" with "broken" sent an hour
        ; looking at the status endpoint when the drive was simply empty.
        test al, ST_STALL
        jz   .nf_nostall
        mov  byte [stalled], 1
.nf_nostall:
        SETDX O_ENDP
        in   al, dx
        mov  [fail_pid], al
        pop  dx
        pop  ax
        ret

; show_fail -- print whatever note_fail last caught, plus the CBI status bytes
show_fail:
        push ax
        push dx
        mov  dx, msg_fph
        call puts
        mov  al, [fail_ph]
        call putdec8
        mov  dx, msg_fst
        call puts
        mov  al, [fail_st]
        call puthex
        mov  dx, msg_fpid
        call puts
        mov  al, [fail_pid]
        call puthex
        mov  dx, msg_fasc
        call puts
        mov  al, [stat_len]
        call putdec8
        mov  dx, msg_fbytes
        call puts
        mov  al, [stat_asc]
        call puthex
        mov  dl, '/'
        mov  ah, 2
        int  0x21
        mov  al, [stat_ascq]
        call puthex
        mov  dx, msg_crlf
        call puts
        pop  dx
        pop  ax
        ret

putdec8:
        push ax
        xor  ah, ah
        call putdec16
        pop  ax
        ret

; ============================================================================
;  cbi_send -- the command phase: 12 bytes out through a CONTROL transfer
;    DS:SI = 12-byte UFI command block
;  This is what makes CBI different from Bulk-Only. bRequest 0x00 is ADSC,
;  "accept device-specific command", and wIndex names the interface -- not an
;  endpoint, because the command is not going to one.
; ============================================================================
cbi_send:
        push ax
        push bx
        push cx
        push dx
        push si
        mov  byte [fail_ph], 0          ; 0 = got all the way through
        mov  byte [stalled], 0

        mov  al, [ifnum]
        mov  [sp_adsc+4], al

        xor  al, al
        SETDX O_ENDP
        out  dx, al

        call setptr
        push si
        mov  si, sp_adsc
        mov  cx, 8
        SETDX O_DATA
.cs_setup:
        lodsb
        out  dx, al
        loop .cs_setup
        pop  si
        mov  al, 8
        SETDX O_LEN
        out  dx, al
        mov  al, OP_SETUP | GO
        call txn
        jc   .bad1
        test al, ST_ACK
        jnz  .setup_ok
.bad1:
        mov  al, 1                      ; phase 1: ADSC SETUP
        call note_fail
        jmp  .bad
.setup_ok:

        ; ---- data stage: the 12-byte command block ----
        ; SPLIT INTO bMaxPacketSize0 CHUNKS. This drive reports an 8-byte
        ; control endpoint, so a 12-byte command has to go out as 8 then 4,
        ; with the toggle alternating DATA1, DATA0. Sending all twelve as one
        ; packet is a protocol violation -- a packet larger than the endpoint
        ; -- and the device answers it with a STALL, which is exactly what it
        ; did: phase 2, status 48, rxpid 1E.
        ;
        ; ctl_read already loops for the IN direction; this stage was written
        ; by hand and did not, which is the same 64-byte EP0 assumption the
        ; BIOS had to be fixed for. It only shows on a device whose EP0 is
        ; smaller than the payload -- an 8-byte command block would have
        ; sailed through and taught us nothing.
        mov  bx, 12                     ; bytes of command block left to send
        mov  byte [ctog], 1             ; first data packet of a control
                                        ; transfer is always DATA1
.cs_dloop:
        test bx, bx
        jz   .cmd_ok
        mov  al, [ep0max]
        xor  ah, ah
        cmp  ax, bx
        jbe  .cs_have
        mov  ax, bx
.cs_have:
        mov  cx, ax                     ; this packet's size
        push cx
        call setptr
        SETDX O_DATA
.cs_fill:
        lodsb                           ; si walks the command block
        out  dx, al
        loop .cs_fill
        pop  cx
        mov  al, cl
        SETDX O_LEN
        out  dx, al
        mov  al, OP_OUT | GO
        cmp  byte [ctog], 0
        je   .cs_t0
        or   al, DATA1
.cs_t0:
        call txn
        jc   .bad2
        test al, ST_ACK
        jnz  .cs_sent
.bad2:
        mov  al, 2                      ; phase 2: the command block
        call note_fail
        jmp  .bad
.cs_sent:
        xor  byte [ctog], 1
        sub  bx, cx
        jmp  short .cs_dloop
.cmd_ok:

        ; status stage of the CONTROL transfer -- IN, because this was a
        ; host-to-device request. Not to be confused with the CBI status,
        ; which arrives separately on the interrupt endpoint.
        call setptr
        xor  al, al
        SETDX O_LEN
        out  dx, al
        mov  al, OP_IN | GO | DATA1
        call txn
        jnc  .allok
        mov  al, 3                      ; phase 3: control status stage
        call note_fail
        jmp  short .bad
.allok:
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
;  cbi_status -- two bytes from the interrupt IN endpoint
;
;  For UFI these are ASC and ASCQ, the same codes REQUEST SENSE reports. Both
;  zero means the command succeeded. Any other transport would put a one-byte
;  type and a two-bit status here instead; UFI is the exception, and reading it
;  the generic way turns a perfectly good "medium not present" into gibberish.
;
;  Returns CF set if the status could not be read at all, or if it was non-zero.
; ============================================================================
cbi_status:
        push ax
        push cx
        push dx
        push di

        mov  al, [ep_int]
        and  al, 0x0F
        SETDX O_ENDP
        out  dx, al

        mov  byte [stat_len], 0
        mov  byte [stat_asc], 0
        mov  byte [stat_ascq], 0

        call setptr
        mov  al, OP_IN | GO
        call txn
        jc   .bad5
        test al, ST_RXV
        jnz  .gotit
.bad5:
        mov  al, 5                      ; phase 5: interrupt status never came
        call note_fail
        jmp  short .bad
.gotit:
        SETDX O_LEN
        in   al, dx
        xor  ah, ah
        mov  [stat_len], al
        cmp  ax, 2
        jae  .len_ok
        mov  al, 6                      ; phase 6: status shorter than 2 bytes
        call note_fail
        jmp  short .bad
.len_ok:
        call setptr
        SETDX O_DATA
        in   al, dx
        mov  [stat_asc], al
        in   al, dx
        mov  [stat_ascq], al

        ; Non-zero here is the DEVICE reporting a fault, and it is a completely
        ; different situation from not getting a status at all -- phase 7 says
        ; the transport worked and the command was refused.
        mov  al, [stat_asc]
        or   al, [stat_ascq]
        jz   .good
        mov  al, 7
        call note_fail
        jmp  short .bad
.good:
        clc
        jmp  short .out
.bad:
        stc
.out:
        pop  di
        pop  dx
        pop  cx
        pop  ax
        ret

; ============================================================================
; ufi_trace -- DX = label. One line per command: where it got to, and the
;              evidence. Printing every step rather than only the last failure,
;              because the interesting fact in the previous run was which
;              command SUCCEEDED, and that was invisible.
ufi_trace:
        push ax
        call puts
        jmp short ufi_trace_body
ufi_trace_bare:
        push ax
ufi_trace_body:
        mov  dx, msg_tph
        call puts
        mov  al, [fail_ph]
        call putdec8
        mov  dx, msg_fst
        call puts
        mov  al, [fail_st]
        call puthex
        mov  dx, msg_fpid
        call puts
        mov  al, [fail_pid]
        call puthex
        mov  dx, msg_fasc
        call puts
        mov  al, [stat_len]
        call putdec8
        mov  dx, msg_fbytes
        call puts
        mov  al, [stat_asc]
        call puthex
        mov  dl, '/'
        mov  ah, 2
        int  0x21
        mov  al, [stat_ascq]
        call puthex
        mov  dx, msg_crlf
        call puts
        pop  ax
        ret

; dump_sense -- the 14 bytes REQUEST SENSE returned, raw.
;               Byte 2 low nibble is the sense key, 12 is ASC, 13 is ASCQ.
;               Raw, because a decoded field that was never fetched is what
;               made 00/00/00 look like a measurement last time.
dump_sense:
        push ax
        push bx
        push cx
        push dx
        push si
        mov  dx, msg_senraw
        call puts
        mov  si, senbuf
        mov  cx, 14
.ds_l:
        lodsb
        call puthex
        mov  dl, ' '
        mov  ah, 2
        int  0x21
        loop .ds_l
        mov  dx, msg_crlf
        call puts
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

;  ufi_nodata -- a command with no data phase.   DS:SI = command block
;  ufi_in     -- a command that reads.  DS:SI = cmd, ES:DI = dest, CX = bytes
; ============================================================================
ufi_nodata:
        call cbi_send
        jc   .bad
        call cbi_status
        ret
.bad:
        stc
        ret

ufi_in:
        push cx
        push di
        call cbi_send
        jc   .bad
        pop  di
        pop  cx
        push cx
        push di
        call bulk_in
        jc   .bad
        call cbi_status
        pop  di
        pop  cx
        ret
.bad:
        pop  di
        pop  cx
        stc
        ret

; ufi_sense -- REQUEST SENSE into senbuf. Used to clear UNIT ATTENTION and to
;              find out why something failed. Deliberately ignores its own
;              status: asking why a command failed must not itself fail.
ufi_sense:
        push ax
        push cx
        push di
        push si
        mov  word [senbuf+2], 0
        mov  word [senbuf+12], 0
        mov  si, cmd_sense
        mov  di, senbuf
        mov  cx, 18
        call ufi_in
        pop  si
        pop  di
        pop  cx
        pop  ax
        clc
        ret

; ============================================================================
;  bulk_in -- receive CX bytes into ES:DI on the bulk IN endpoint.
;
;  The data toggle is the whole difficulty. A packet arriving with the toggle
;  we are NOT expecting is a retransmission of one already taken -- our ACK was
;  lost and the device sent it again. Counting it as new shifts the entire
;  stream by a packet, and on a 512-byte sector that is not an obvious failure,
;  it is a sector that reads as garbage. Same reasoning as u_bulk_in in the
;  BIOS, which learned it the hard way.
; ============================================================================
bulk_in:
        push ax
        push bx
        push dx
        push si
        xor  si, si                     ; duplicate counter
.bi_pkt:
        jcxz .bi_done
        push cx
        mov  al, [ep_in]
        and  al, 0x0F
        SETDX O_ENDP
        out  dx, al
        call setptr
        mov  al, OP_IN | GO
        cmp  byte [tog_in], 0
        je   .bi_t0
        or   al, DATA1
.bi_t0:
        call txn
        pop  cx
        jc   .bi_bad
        test al, ST_RXV
        jz   .bi_bad

        ; which toggle did it actually carry?
        mov  bh, 0
        test al, ST_RXD1
        jz   .bi_g0
        mov  bh, 1
.bi_g0:
        mov  bl, [tog_in]
        cmp  bl, bh
        je   .bi_take
        inc  si
        cmp  si, 8                      ; a device that only repeats itself
        jae  .bi_bad                    ; must not wedge us
        jmp  short .bi_pkt              ; discard, ask again
.bi_take:
        xor  byte [tog_in], 1
        SETDX O_LEN
        in   al, dx
        xor  ah, ah
        mov  bx, ax                     ; bytes this packet actually carried
        test bx, bx
        jz   .bi_done
        mov  [pktlen], bx               ; keep it: the short-packet test below
                                        ; must use what ARRIVED, not what fitted
        ; NEVER store more than was asked for. A device answering an 8-byte
        ; request with a 64-byte packet would otherwise write straight past the
        ; end of the caller's buffer -- capbuf is 8 bytes with senbuf directly
        ; behind it, so an overrun would not crash, it would quietly corrupt
        ; the sense data we use to diagnose the failure.
        cmp  bx, cx
        jbe  .bi_fit
        mov  bx, cx
.bi_fit:
        push cx
        mov  cx, bx
        call setptr
        SETDX O_DATA
.bi_copy:
        in   al, dx
        stosb
        loop .bi_copy
        pop  cx
        sub  cx, bx
        ; A packet shorter than 64 ends the transfer, however many bytes were
        ; asked for. That is the rule for every bulk endpoint here.
        cmp  word [pktlen], 64
        jb   .bi_done
        jmp  .bi_pkt
.bi_done:
        clc
        jmp  short .bi_out
.bi_bad:
        stc
.bi_out:
        pop  si
        pop  dx
        pop  bx
        pop  ax
        ret

; ============================================================================
;  ctl_read / txn / wait_done / setptr / delay_ticks -- as in usbenum
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

txn:
        push bx
        push cx
        push dx
        mov  bl, al
        mov  bh, 3
.tx_attempt:
        mov  cx, 8000                   ; NAK budget: see the header
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

; delay_ticks: CX tick EDGES. One edge is only the REMAINDER of the current
;              tick, so N edges guarantee (N-1) whole periods.
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
;  dump -- first 128 bytes of secbuf, hex and ASCII
;
;  Enough to recognise a boot sector: the OEM name at offset 3 and the BPB
;  behind it are unmistakable, and 55 AA lives at 510. If this is right, the
;  transport is right.
; ============================================================================
dump:
        push ax
        push bx
        push cx
        push dx
        push si
        mov  si, secbuf
        mov  bx, 0
.d_row:
        mov  ax, bx
        call puthex16
        mov  dx, msg_colon
        call puts
        mov  cx, 16
        push si
.d_hex:
        lodsb
        call puthex
        mov  dl, ' '
        mov  ah, 2
        int  0x21
        loop .d_hex
        pop  si
        mov  cx, 16
.d_asc:
        lodsb
        cmp  al, 0x20
        jb   .d_dot
        cmp  al, 0x7E
        jbe  .d_pr
.d_dot:
        mov  al, '.'
.d_pr:
        mov  dl, al
        mov  ah, 2
        int  0x21
        loop .d_asc
        mov  dx, msg_crlf
        call puts
        add  bx, 16
        cmp  bx, 128
        jb   .d_row
        ; and the signature, which is the quickest yes/no on a boot sector
        mov  dx, msg_sig
        call puts
        mov  al, [secbuf+511]
        call puthex
        mov  al, [secbuf+510]
        call puthex
        mov  dx, msg_crlf
        call puts
        pop  si
        pop  dx
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
        and  al, 0x0F
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

; putdec16: AX unsigned, no leading zeros
putdec16:
        push ax
        push bx
        push cx
        push dx
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
ep0max  db 8
reqtype db 0
ifnum   db 0
ep_in   db 0
ep_out  db 0
ep_int  db 0
tog_in  db 0
tog_out db 0
cand    db 0
cfglen  dw 0
nblocks dw 0
nsec    db 18
seclo   dw 0
pktlen  dw 0
ctog    db 0
tries   dw 0
stalled db 0
fail_ph db 0
fail_st db 0
fail_pid db 0
stat_len db 0
stat_asc  db 0
stat_ascq db 0

sp_getdev8   db 0x80, 6, 0x00, DT_DEVICE, 0, 0, 8, 0
sp_getdev18  db 0x80, 6, 0x00, DT_DEVICE, 0, 0, 18, 0
sp_setaddr   db 0x00, 5, 1, 0, 0, 0, 0, 0
sp_getcfg9   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 9, 0
sp_getcfgn   db 0x80, 6, 0x00, DT_CONFIG, 0, 0, 0, 0
sp_setcfg    db 0x00, 9, 1, 0, 0, 0, 0, 0
; ADSC -- the CBI command wrapper. wIndex (offset 4) is patched with the
; interface number; wLength is 12, the UFI command block length.
sp_adsc      db 0x21, 0x00, 0, 0, 0, 0, 12, 0

; ---- UFI command blocks, all exactly 12 bytes ----
cmd_tur      db 0x00, 0,0,0,0,0, 0,0,0,0,0,0
cmd_sense    db 0x03, 0,0,0, 18, 0, 0,0,0,0,0,0
cmd_readcap  db 0x25, 0,0,0,0,0, 0,0,0,0,0,0
; START STOP UNIT: byte 4 bit 0 = START. Spins the motor so the drive can
; sense whether there is a diskette in it.
cmd_start    db 0x1B, 0, 0,0, 0x01, 0, 0,0,0,0,0,0
; READ FORMAT CAPACITIES. Allocation length is bytes 7-8, big-endian.
cmd_rdfmt    db 0x23, 0, 0,0,0,0, 0, 0x00, 0x40, 0,0,0
; READ(10): opcode, flags, LBA big-endian (4), reserved, length big-endian (2)
cmd_read10   db 0x28, 0, 0,0,0,0, 0, 0,1, 0,0,0

msg_hdr      db 'USBFDD -- read a diskette through a USB floppy drive', 13, 10, '$'
msg_nodev    db 'no device on the port', 13, 10, '$'
msg_islow    db 'low-speed device: not a floppy drive', 13, 10, '$'
msg_vid      db 'device      ', '$'
msg_ep0      db 'EP0 max     ', '$'
msg_found    db 'UFI/CBI     iface ', '$'
msg_eps      db '  ep in/out/int ', '$'
msg_tur      db 'unit ready  ', '$'
msg_ok       db 'yes', 13, 10, '$'
msg_notready db 'NO', 13, 10, '$'
msg_spin     db 'spinning up ', '$'
msg_anyway   db 'trying the data path anyway -- TUR is my gate, not the drive', 13, 10, '$'
msg_rfc      db 'format cap  ', '$'
msg_rfcraw   db 13, 10, '  raw ', '$'
msg_rfcfail  db 'REFUSED  ', '$'
msg_fmt_un   db '  -> media present, UNFORMATTED', 13, 10, '$'
msg_fmt_fm   db '  -> MEDIA PRESENT AND FORMATTED', 13, 10, '$'
msg_fmt_no   db '  -> drive says no cartridge', 13, 10, '$'
msg_fmt_rs   db '  -> reserved/unknown descriptor code', 13, 10, '$'
msg_refused  db 'refused (STALL) -- the drive said no, see the sense below', 13, 10, '$'
msg_nodisk   db '>>> NO DISKETTE IN THE DRIVE. Put one in and run this again.', 13, 10, '$'
msg_sense    db 'sense key/ASC/ASCQ = ', '$'
msg_blocks   db 'capacity    ', '$'
msg_x512     db ' blocks of 512 = ', '$'
msg_144      db '1.44 MB (80/2/18)', 13, 10, '$'
msg_720      db '720 KB (80/2/9)', 13, 10, '$'
msg_unkgeom  db 'unrecognised size -- assuming 18 sectors', 13, 10, '$'
msg_reading  db 'reading sector ', '$'
msg_done     db 'ok', 13, 10, '$'
msg_sig      db 'boot signature (510) = ', '$'
msg_colon    db ': ', '$'
msg_edesc    db 'failed reading the device descriptor', 13, 10, '$'
msg_eaddr    db 'SET_ADDRESS failed', 13, 10, '$'
msg_ecfg     db 'failed reading the configuration descriptor', 13, 10, '$'
msg_enoufi   db 'no UFI/CBI interface with bulk in, bulk out and interrupt in', 13, 10, '$'
msg_esetcfg  db 'SET_CONFIGURATION failed', 13, 10, '$'
msg_ecap     db 'READ CAPACITY failed', 13, 10, '$'
msg_eread    db 'READ(10) failed', 13, 10, '$'
msg_fph      db 'failed at phase ', '$'
msg_tph      db '  phase ', '$'
msg_t1       db '  TUR#1   ', '$'
msg_t2       db '  SENSE   ', '$'
msg_t3       db '  TUR#2   ', '$'
msg_senraw   db '  sense raw ', '$'
msg_fst      db '  status ', '$'
msg_fpid     db '  rxpid ', '$'
msg_fasc     db '  intlen ', '$'
msg_fbytes   db '  asc/ascq ', '$'
msg_phkey    db 'phases: 1 ADSC setup  2 command block  3 ctl status', 13, 10
             db '        4 data  5 no interrupt status  6 short  7 device refused', 13, 10, '$'
msg_crlf     db 13, 10, '$'

CFGMAX  equ 256
cfgbuf  times CFGMAX db 0
devbuf  times 32 db 0
capbuf  times 8 db 0
senbuf  times 20 db 0
fmtbuf  times 64 db 0
secbuf  times 512 db 0
