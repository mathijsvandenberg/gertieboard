; ============================================================================
;  usbsoak.asm  --  sustained read/write/verify soak test for drive C:
;
;  Every failure so far has been found by running FDISK or FORMAT and watching
;  where it fell over. That is a terrible instrument: one run, one data point,
;  and the failure is filtered through DOS's own retries before we see it. This
;  does the same work deliberately -- many transfers, of several sizes, over a
;  long period -- and counts what fails instead of stopping at the first one.
;
;  Each pass runs five phases, one per transfer size:
;
;      512B    1 sector per command      64 commands
;      1K      2 sectors                 32
;      4K      8 sectors                 16
;      32K     64 sectors                 8
;      63.5K   127 sectors                8
;
;  127 is not an arbitrary ceiling: it is the largest transfer this BIOS will
;  put in a single command (see .ui_rw in xtbios_src.s), because one CBW
;  carries at most 127 x 512 bytes. So a 128 KB request cannot be one command
;  on this machine -- the 63.5K phase moves 508 KB as eight back-to-back
;  commands, which is what a 128 KB read from DOS actually turns into.
;
;  Each command is written, read back, and verified against a pattern derived
;  from the sector's own LBA. That last part matters: with a constant pattern,
;  a read that returns the WRONG sector verifies perfectly. Here it does not.
;
;  The controller's event counters are sampled around every phase, so a failure
;  can be attributed -- NAKs mean the device was busy, timeouts mean nothing
;  came back, CRC errors mean the wire is corrupting data, and no counter
;  moving at all means the transfer never reached the bus.
;
;      usbsoak            one pass, read/write/verify (destroys data on C:)
;      usbsoak 10         ten passes
;      usbsoak r          read-only, no writing and no verification
;      usbsoak r 10       ten read-only passes
;
;  Press ESC at any time to stop after the current command.
;
;  Build:  nasm -f bin usbsoak.asm -o usbsoak.com
; ============================================================================

        org  0x100
        bits 16
        CPU  8086               ; mandatory: see docs/gotchas.md

U_DIAG    equ 0xEF
START_LBA equ 4096              ; stay clear of the partition table and FATs
PHASES    equ 5

start:
        mov  dx, msg_hdr
        call puts

        ; ---- did the disk enumerate? ----
        ; If not, still show the counters and leave. A dead disk plus silent
        ; counters is itself the diagnosis, and needing a working disk to read
        ; the diagnostics would be exactly backwards.
        mov  ax, 0x40
        mov  es, ax
        cmp  byte [es:0xC1], 0
        jne  .present
        mov  dx, msg_nodisk
        call puts
        call snapshot
        call show_raw
        jmp  bye
.present:
        mov  al, [es:0xCE]
        mov  ah, 0
        mov  [heads], ax
        mov  al, [es:0xCF]
        mov  ah, 0
        mov  [spt], ax
        mov  ax, [es:0xCC]
        mov  [cyls], ax

        call parse_args

        ; ---- geometry, so it is on the record next to the results ----
        mov  dx, msg_geo
        call puts
        mov  ax, [cyls]
        call putdec
        mov  dx, msg_x
        call puts
        mov  ax, [heads]
        call putdec
        mov  dx, msg_x
        call puts
        mov  ax, [spt]
        call putdec
        mov  dx, msg_crlf
        call puts

        ; ---- writing destroys the filesystem, so say so and require Y ----
        cmp  byte [rdonly], 0
        jne  .noask
        mov  dx, msg_warn
        call puts
        mov  ah, 0x01
        int  0x21
        and  al, 0xDF
        cmp  al, 'Y'
        je   .ok
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_abort
        call puts
        jmp  bye
.ok:
        mov  dx, msg_crlf
        call puts
.noask:

        ; ---- a 63.5 KB command needs a buffer this .COM has no room for ----
        ; AH=4A resizes the block ES points at, and ES is still the BDA from
        ; the enumeration check above. Pointing it at our own PSP is the whole
        ; job: a .COM starts owning all of memory, so without the shrink there
        ; is nothing left for DOS to hand back.
        push cs
        pop  es
        mov  bx, 0x1000         ; keep 64 KB for code, data and stack
        mov  ah, 0x4A
        int  0x21

        ; Ask how much is actually free rather than assuming 64 KB is. AH=48
        ; with 0xFFFF always fails and returns the largest block in BX.
        mov  bx, 0xFFFF
        mov  ah, 0x48
        int  0x21
        cmp  bx, 0x0FE0         ; 4064 paragraphs = 65024 = 127 sectors
        jb   .nomem
        cmp  bx, 0x1000
        jbe  .take
        mov  bx, 0x1000
.take:
        mov  ah, 0x48
        int  0x21
        jnc  .gotmem
.nomem:
        mov  dx, msg_nomem
        call puts
        mov  ax, bx             ; paragraphs DOS says are available
        call putdec
        mov  dx, msg_nomem2
        call puts
        jmp  bye
.gotmem:
        mov  [bufseg], ax

        mov  dx, msg_cols
        call puts

        ; ================= the soak itself =================
        mov  word [pass], 0
passloop:
        mov  ax, [pass]
        cmp  ax, [passes]
        jb   .run
        jmp  done
.run:

        mov  dx, msg_pass
        call puts
        mov  ax, [pass]
        inc  ax
        call putdec
        mov  dx, msg_of
        call puts
        mov  ax, [passes]
        call putdec
        mov  dx, msg_crlf
        call puts

        ; every pass walks the same region, so a sector that fails once can be
        ; seen to fail again rather than being lost in a moving target
        mov  word [lba_lo], START_LBA
        mov  word [lba_hi], 0

        mov  byte [phase], 0
phaseloop:
        mov  bl, [phase]
        cmp  bl, PHASES
        jb   .run
        jmp  phase_done
.run:
        mov  bh, 0
        mov  al, [ph_sect+bx]
        mov  [sect], al
        mov  al, [ph_ops+bx]
        mov  ah, 0
        mov  [ops], ax

        mov  word [f_write], 0
        mov  word [f_read], 0
        mov  word [f_ver], 0
        call snapshot

        ; LOOP and the conditional jumps only reach 128 bytes on an 8086 and
        ; this body is far longer, so the count lives in memory and the back
        ; edge is a near JMP.
        mov  ax, [ops]
        mov  [opleft], ax
oploop:
        cmp  word [opleft], 0
        jne  .work
        jmp  .phase_end
.work:
        ; per-command counter baseline, so a failure can say what THIS command
        ; cost rather than smearing it across the phase
        push ax
        push dx
        mov  al, 2
        out  U_DIAG, al
        in   al, U_DIAG
        mov  [c_tmo0], al
        mov  al, 3
        out  U_DIAG, al
        in   al, U_DIAG
        mov  ah, al
        mov  al, 9
        out  U_DIAG, al
        in   al, U_DIAG
        xchg al, ah
        mov  [c_nak0], ax
        pop  dx
        pop  ax
        cmp  byte [rdonly], 0
        jne  .doread

        ; ---- pattern in, write out ----
        call fill
        mov  byte [io_op], 3
        call do_io
        jnc  .doread
        inc  word [f_write]
        mov  al, 'w'
        call failline
        call note_first
        jmp  .next

.doread:
        ; poison the buffer, so a read that moves nothing cannot verify clean
        call poison
        mov  byte [io_op], 2
        call do_io
        jnc  .doverify
        inc  word [f_read]
        mov  al, 'r'
        call failline
        call note_first
        jmp  .next

.doverify:
        cmp  byte [rdonly], 0
        jne  .next
        call verify
        jnc  .next
        inc  word [f_ver]
        mov  al, 'v'
        call failline
        call note_first
        ; ---- the decisive question: is the corruption ON THE DISK, or did
        ; the read path substitute stale data? Re-read the same sector once.
        ; Same wrong data again -> the write left it there. Clean -> the disk
        ; is fine and the READ corrupted it in flight.
        call poison
        mov  byte [io_op], 2
        call do_io
        jc   .rr_err
        call verify
        jc   .rr_bad
        mov  dx, msg_rrclean
        call puts
        jmp  .next
.rr_bad:
        mov  al, '2'
        call failline
        jmp  .next
.rr_err:
        mov  dx, msg_rrerr
        call puts
        jmp  .next

.next:
        ; advance by the whole command, so phases never revisit each other
        mov  al, [sect]
        mov  ah, 0
        add  [lba_lo], ax
        adc  word [lba_hi], 0

        call chk_esc
        dec  word [opleft]
        cmp  byte [stop], 0
        je   .again
        jmp  phase_done
.again:
        jmp  oploop
.phase_end:

        call report_phase
        inc  byte [phase]
        jmp  phaseloop

phase_done:
        cmp  byte [stop], 0
        je   .cont
        jmp  done
.cont:
        inc  word [pass]
        jmp  passloop

done:
        mov  dx, msg_crlf
        call puts
        cmp  byte [stop], 0
        je   .nostop
        mov  dx, msg_stopped
        call puts
.nostop:
        mov  dx, msg_total
        call puts
        mov  ax, [t_fail]
        call putdec
        mov  dx, msg_of2
        call puts
        mov  ax, [t_ops]
        call putdec
        mov  dx, msg_cmds
        call puts

        cmp  word [t_fail], 0
        je   .clean
        mov  dx, msg_first
        call puts
        mov  ax, [first_hi]
        call puthexw
        mov  ax, [first_lo]
        call puthexw
        mov  dx, msg_firstah
        call puts
        mov  al, [first_ah]
        call puthex
        mov  dx, msg_why
        call puts
        mov  al, [first_dd]
        call puthexsp
        mov  dx, msg_why2
        call puts
        mov  al, [first_de]
        call puthexsp
        mov  dx, msg_why3
        call puts
        mov  al, [first_df]
        call puthex
        mov  dx, msg_crlf
        call puts

        ; How the data was wrong matters more than that it was wrong: a bad
        ; stamp means the wrong sector came back, a bad payload means the right
        ; sector came back damaged, and the poison value means nothing was
        ; transferred at all while the call still reported success.
        cmp  byte [have_vf], 0
        je   .clean
        cmp  byte [v_kind], 1
        jne  .vdata
        mov  dx, msg_vstamp
        call puts
        mov  ax, [v_exp_hi]
        call puthexw
        mov  ax, [v_exp_lo]
        call puthexw
        mov  dx, msg_vgot
        call puts
        mov  ax, [v_got_hi]
        call puthexw
        mov  ax, [v_got_lo]
        call puthexw
        jmp  short .vend
.vdata:
        mov  dx, msg_vdata
        call puts
        mov  ax, [v_off]
        call putdec
        mov  dx, msg_vexp
        call puts
        mov  ax, [v_exp_lo]
        call puthexw
        mov  dx, msg_vgot
        call puts
        mov  ax, [v_got_lo]
        call puthexw
.vend:
        mov  dx, msg_crlf
        call puts
.clean:
bye:
        mov  ax, 0x4C00
        int  0x21

; ---------------------------------------------------------------------------
; report_phase -- one line: what was moved, what failed, and what the
; controller saw while it happened.
report_phase:
        push ax
        push bx
        push dx
        mov  bl, [phase]
        mov  bh, 0
        shl  bl, 1
        mov  dx, [ph_name+bx]
        call puts

        mov  ax, [ops]
        call putdec5
        mov  al, [sect]
        mov  ah, 0
        call putdec5

        mov  ax, [f_write]
        add  [t_fail], ax
        call putdec5
        mov  ax, [f_read]
        add  [t_fail], ax
        call putdec5
        mov  ax, [f_ver]
        add  [t_fail], ax
        call putdec5
        mov  ax, [ops]
        add  [t_ops], ax

        mov  dx, msg_bar
        call puts
        call delta              ; controller counters for this phase alone
        mov  dx, msg_crlf
        call puts
        pop  dx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
; do_io -- one INT 13h command. No retries: the point is to count raw
; failures, and a retry loop here would hide exactly what we are measuring.
; in:  [io_op] 2 read / 3 write, [lba_lo/hi], [sect]
; out: CF set on failure, [last_ah] = status
do_io:
        push ax
        push bx
        push cx
        push dx
        push es
        mov  ax, [lba_lo]
        mov  dx, [lba_hi]
        call lba2chs
        mov  ax, [t_cyl]
        mov  ch, al             ; CH = cylinder low 8
        mov  al, ah             ; cylinder high 2 bits ...
        mov  cl, 6
        shl  al, cl             ; ... into CL bits 7:6
        mov  cl, [t_sec]
        or   cl, al
        mov  dh, [t_head]
        mov  dl, 0x80
        mov  es, [bufseg]
        xor  bx, bx
        mov  ah, [io_op]
        mov  al, [sect]
        int  0x13
        mov  [last_ah], ah
        pop  es
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; lba2chs -- dx:ax = LBA, using the geometry the BIOS reported rather than
; assuming 16 x 63. Both divisions are safe: LBA/spt stays under 65536 for
; anything this BIOS can address.
lba2chs:
        push si
        mov  si, [spt]
        div  si                 ; ax = lba/spt, dx = lba mod spt
        inc  dl
        mov  [t_sec], dl
        xor  dx, dx
        mov  si, [heads]
        div  si                 ; ax = cylinder, dx = head
        mov  [t_cyl], ax
        mov  [t_head], dl
        pop  si
        ret

; ---------------------------------------------------------------------------
; fill / verify -- the pattern is derived from each sector's own LBA, so a
; read that returns a valid sector from the WRONG place fails verification
; instead of passing silently.
fill:
        push ax
        push bx
        push cx
        push dx
        push di
        push es
        mov  es, [bufseg]
        xor  di, di
        mov  ax, [lba_lo]
        mov  dx, [lba_hi]
        mov  cl, [sect]
        mov  ch, 0
.sec:
        push cx
        call seed_of
        mov  [es:di], ax        ; word 0/1: which sector this claims to be
        mov  [es:di+2], dx
        add  di, 4
        mov  cx, 254
.w:     mov  [es:di], bx
        inc  bx
        add  di, 2
        loop .w
        add  ax, 1
        adc  dx, 0
        pop  cx
        loop .sec
        pop  es
        pop  di
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

verify:
        push ax
        push cx
        push dx
        push di
        push si
        push es
        mov  es, [bufseg]
        xor  di, di
        mov  ax, [lba_lo]
        mov  dx, [lba_hi]
        mov  cl, [sect]
        mov  ch, 0
.sec:
        push cx
        call seed_of
        cmp  [es:di], ax
        jne  .bad
        cmp  [es:di+2], dx
        jne  .bad
        add  di, 4
        mov  cx, 254
.w:     cmp  [es:di], bx
        jne  .badpop
        inc  bx
        add  di, 2
        loop .w
        add  ax, 1
        adc  dx, 0
        pop  cx
        loop .sec
        clc
        jmp  short .out
.badpop:
        ; payload wrong: the sector identified itself correctly, so the right
        ; sector came back with the wrong contents in it
        pop  cx
        cmp  byte [have_vf], 0
        jne  .out2
        mov  byte [have_vf], 1
        mov  byte [v_kind], 2
        mov  [v_off], di
        mov  [v_exp_lo], bx
        mov  cx, [es:di]
        mov  [v_got_lo], cx
        jmp  short .out2
.bad:
        ; the stamp is wrong: this is not the sector that was asked for
        pop  cx
        cmp  byte [have_vf], 0
        jne  .out2
        mov  byte [have_vf], 1
        mov  byte [v_kind], 1
        mov  [v_off], di
        mov  [v_exp_lo], ax
        mov  [v_exp_hi], dx
        mov  cx, [es:di]
        mov  [v_got_lo], cx
        mov  cx, [es:di+2]
        mov  [v_got_hi], cx
.out2:
        stc
.out:
        pop  es
        pop  si
        pop  di
        pop  dx
        pop  cx
        pop  ax
        ret

; seed_of -- bx = a value unique to the LBA in dx:ax, cheaply
seed_of:
        push ax
        push dx
        push cx
        mov  cx, ax
        mov  ax, 0x1234
        mul  cx
        add  ax, dx
        mov  bx, ax
        pop  cx
        pop  dx
        pop  ax
        ret

poison:
        push ax
        push cx
        push dx
        push di
        push es
        mov  es, [bufseg]
        xor  di, di
        mov  al, [sect]
        mov  ah, 0
        mov  cx, 256
        mul  cx                 ; ax = words to poison (sect * 256)
        mov  cx, ax
        xor  di, di
        mov  ax, 0xA5A5
.p:     mov  [es:di], ax
        add  di, 2
        loop .p
        pop  es
        pop  di
        pop  dx
        pop  cx
        pop  ax
        ret

; failline -- one line, printed the moment a command fails, with what that
; command cost. AL = 'w'/'r'/'v'. For a verify failure the offset and the
; expected/got words follow: 'got' minus 'expected' in whole multiples of
; 0x1234 says HOW MANY sectors stale the data is, since the pattern seed
; steps by 0x1234 per LBA.
failline:
        push ax
        push bx
        push dx
        push es
        mov  [fl_ch], al
        mov  dx, msg_fl1
        call puts
        mov  dl, [fl_ch]
        mov  ah, 2
        int  0x21
        mov  dx, msg_fl2
        call puts
        mov  ax, [lba_hi]
        call puthexw
        mov  ax, [lba_lo]
        call puthexw
        mov  dx, msg_flah
        call puts
        mov  al, [last_ah]
        call puthex
        cmp  byte [fl_ch], 'v'
        je   .vdet
        cmp  byte [fl_ch], '2'
        jne  .nfo
.vdet:
        mov  dx, msg_floff
        call puts
        mov  ax, [v_off]
        call putdec
        mov  dx, msg_flexp
        call puts
        mov  ax, [v_exp_lo]
        call puthexw
        mov  dx, msg_flgot
        call puts
        mov  ax, [v_got_lo]
        call puthexw
        mov  byte [have_vf], 0        ; re-arm, so every vf reports its detail
.nfo:
        ; what this one command cost the controller
        mov  dx, msg_flnak
        call puts
        mov  al, 3
        out  U_DIAG, al
        in   al, U_DIAG
        mov  ah, al
        mov  al, 9
        out  U_DIAG, al
        in   al, U_DIAG
        xchg al, ah
        sub  ax, [c_nak0]
        call puthexw
        mov  dx, msg_fltmo
        call puts
        mov  al, 2
        out  U_DIAG, al
        in   al, U_DIAG
        sub  al, [c_tmo0]
        call puthex
        mov  dx, msg_crlf
        call puts
        pop  es
        pop  dx
        pop  bx
        pop  ax
        ret

; note_first -- remember where the first failure happened, and WHY. The BIOS
; publishes the reason in the BDA and we have been ignoring it: 0xDD is the
; point in the Bulk-Only transport that gave up, 0xDE the status the device
; returned in the CSW, 0xDF the transport status of the last transaction.
; Also stops the run once failures are clearly systematic -- every failing
; command burns its whole NAK budget, so a full five passes of failures takes
; the best part of ten minutes and tells us nothing the first eight did not.
note_first:
        push ax
        push es
        inc  word [livefail]
        cmp  word [livefail], 8
        jb   .nolimit
        mov  byte [stop], 1
.nolimit:
        cmp  byte [have_first], 0
        jne  .out
        mov  byte [have_first], 1
        mov  ax, [lba_lo]
        mov  [first_lo], ax
        mov  ax, [lba_hi]
        mov  [first_hi], ax
        mov  al, [last_ah]
        mov  [first_ah], al
        mov  ax, 0x40
        mov  es, ax
        mov  al, [es:0xDD]
        mov  [first_dd], al
        mov  al, [es:0xDE]
        mov  [first_de], al
        mov  al, [es:0xDF]
        mov  [first_df], al
.out:
        pop  es
        pop  ax
        ret

chk_esc:
        push ax
        mov  ah, 0x0B           ; check stdin without blocking
        int  0x21
        test al, al
        jz   .out
        mov  ah, 0x08
        int  0x21
        cmp  al, 27
        jne  .out
        mov  byte [stop], 1
.out:
        pop  ax
        ret

; ---------------------------------------------------------------------------
; controller counters
snapshot:
        push ax
        push bx
        push cx
        push si
        push di
        mov  si, cur
        mov  di, prev
        mov  cx, 12
.cp:    mov  al, [si]
        mov  [di], al
        inc  si
        inc  di
        loop .cp
        xor  bx, bx
        mov  cx, 12
.rd:    mov  al, bl
        out  U_DIAG, al
        in   al, U_DIAG
        mov  di, cur
        add  di, bx
        mov  [di], al
        inc  bx
        loop .rd
        pop  di
        pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

; delta -- what the controller counted during this phase
delta:
        push ax
        push bx
        call snapshot
        mov  al, [cur+1]
        sub  al, [prev+1]
        call puthexsp           ; CRC/PID
        mov  al, [cur+2]
        sub  al, [prev+2]
        call puthexsp           ; timeouts
        mov  ah, [cur+9]
        mov  al, [cur+3]
        mov  bh, [prev+9]
        mov  bl, [prev+3]
        sub  ax, bx
        call puthexw            ; NAKs, 16-bit
        mov  dx, msg_sp
        call puts
        mov  al, [cur+4]
        sub  al, [prev+4]
        call puthexsp           ; STALLs
        mov  ah, [cur+11]
        mov  al, [cur+10]
        mov  bh, [prev+11]
        mov  bl, [prev+10]
        sub  ax, bx
        call puthexw            ; transactions accepted
        pop  bx
        pop  ax
        ret

; show_raw -- absolute counter values, for when there is no disk to test
show_raw:
        push ax
        mov  dx, msg_raw
        call puts
        mov  al, [cur+1]
        call puthexsp
        mov  al, [cur+2]
        call puthexsp
        mov  ah, [cur+9]
        mov  al, [cur+3]
        call puthexw
        mov  dx, msg_sp
        call puts
        mov  al, [cur+4]
        call puthexsp
        mov  ah, [cur+11]
        mov  al, [cur+10]
        call puthexw
        mov  dx, msg_sp
        call puts
        mov  al, [cur+0]
        call puthex
        mov  dx, msg_crlf
        call puts
        mov  dx, msg_rawkey
        call puts
        pop  ax
        ret

; ---------------------------------------------------------------------------
parse_args:
        push ax
        push bx
        push cx
        push si
        mov  word [passes], 1
        mov  al, [0x80]
        test al, al
        jz   .out
        mov  cl, al
        mov  ch, 0
        mov  si, 0x81
        xor  ax, ax             ; ax accumulates a decimal pass count
.scan:
        lodsb
        cmp  al, ' '
        je   .cont
        cmp  al, 9
        je   .cont
        mov  ah, al
        and  ah, 0xDF
        cmp  ah, 'R'
        jne  .digit
        mov  byte [rdonly], 1
        jmp  short .cont
.digit:
        cmp  al, '0'
        jb   .cont
        cmp  al, '9'
        ja   .cont
        sub  al, '0'
        mov  ah, 0
        push ax
        mov  ax, [passes2]
        mov  bx, 10
        mul  bx
        mov  [passes2], ax
        pop  ax
        add  [passes2], ax
.cont:
        loop .scan
        cmp  word [passes2], 0
        je   .out
        mov  ax, [passes2]
        mov  [passes], ax
.out:
        pop  si
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
puts:   push ax
        mov  ah, 9
        int  0x21
        pop  ax
        ret

puthexsp:
        call puthex
        push dx
        mov  dx, msg_sp
        call puts
        pop  dx
        ret

puthexw:                        ; ax in hex, 4 digits
        push ax
        push ax
        mov  al, ah
        call puthex
        pop  ax
        call puthex
        pop  ax
        ret

puthex: push ax
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
.nib:   and  al, 0x0F
        cmp  al, 10
        jb   .n0
        add  al, 'A'-10
        jmp  short .n1
.n0:    add  al, '0'
.n1:    mov  dl, al
        mov  ah, 2
        int  0x21
        ret

putdec5:                        ; ax, right-aligned in five columns
        push ax
        push bx
        push cx
        push dx
        push si
        ; The value cannot be kept in AX across the padding: INT 21h AH=02
        ; needs AH and returns the written character in AL, so after padding
        ; with spaces AX is 0x0220 -- which is why every column printed 544.
        mov  si, ax
        mov  cx, 0
        mov  bx, 10
.count: xor  dx, dx
        div  bx
        inc  cx
        test ax, ax
        jnz  .count
        mov  bx, 5
        sub  bx, cx
        jbe  .num
        mov  cx, bx
.pad:   push cx
        mov  dl, ' '
        mov  ah, 2
        int  0x21
        pop  cx
        loop .pad
.num:   mov  ax, si
        call putdec
        pop  si
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

putdec: push ax
        push bx
        push cx
        push dx
        xor  cx, cx
        mov  bx, 10
.d1:    xor  dx, dx
        div  bx
        push dx
        inc  cx
        test ax, ax
        jnz  .d1
.d2:    pop  ax
        add  al, '0'
        mov  dl, al
        mov  ah, 2
        int  0x21
        loop .d2
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret

; ---------------------------------------------------------------------------
msg_hdr   db 'USBSOAK - sustained read/write/verify test of drive C:',13,10
          db '-----------------------------------------------------',13,10,'$'
msg_nodisk db 'No USB disk enumerated at POST, so there is nothing to soak.',13,10
          db 'The controller counters are still worth reading:',13,10,'$'
msg_raw   db '  crc tmo  nak stl  txn frm',13,10,'  $'
msg_rawkey db 13,10
          db 'All zero means nothing ever reached the bus: the controller was',13,10
          db 'never given a command, or never accepted one. A non-zero frame',13,10
          db 'count with zero transactions narrows it to the command path.',13,10,'$'
msg_geo   db 'geometry : $'
msg_x     db ' x $'
msg_warn  db 13,10
          db 'This WRITES to drive C: from sector 4096 onward and will destroy',13,10
          db 'any filesystem there. Run "usbsoak r" for a read-only test.',13,10
          db 13,10,'Type Y to run the write test, anything else to abort : $'
msg_abort db 'Aborted.',13,10,'$'
msg_nomem db 'Could not allocate a buffer - DOS has only $'
msg_nomem2 db ' paragraphs free,',13,10
          db 'and a 127-sector command needs 4064.',13,10,'$'
msg_cols  db 13,10
          db '  size   cmds  sect   wf   rf   vf | crc tmo  nak stl  txn',13,10
          db '  ---------------------------------+-------------------------',13,10,'$'
msg_pass  db '  pass $'
msg_of    db ' of $'
msg_bar   db ' | $'
msg_sp    db ' $'
msg_total db 'Result: $'
msg_of2   db ' failures in $'
msg_cmds  db ' commands.',13,10,'$'
msg_first db 'First failure at LBA $'
msg_firstah db ', AH = $'
msg_stopped db 'Stopped early - the failures are systematic, not occasional.',13,10,'$'
msg_why    db 13,10,'  transport gave up at stage $'
msg_why2   db ', device CSW status $'
msg_why3   db ', last transaction $'
msg_vstamp db 'Verify: wrong sector came back - asked for LBA $'
msg_vdata  db 'Verify: right sector, wrong contents at byte $'
msg_vexp   db ', expected $'
msg_vgot   db ', got $'
msg_fl1    db '  FAIL $'
msg_fl2    db ' LBA $'
msg_flah   db ' AH $'
msg_floff  db ' off $'
msg_flexp  db ' exp $'
msg_flgot  db ' got $'
msg_flnak  db ' nak+$'
msg_fltmo  db ' tmo+$'
msg_rrclean db '       re-read: CLEAN - the disk is fine, the READ corrupted it',13,10,'$'
msg_rrerr  db '       re-read: errored out',13,10,'$'
fl_ch      db 0
c_nak0     dw 0
c_tmo0     db 0
msg_crlf  db 13,10,'$'

n_512     db '  512B $'
n_1k      db '  1K   $'
n_4k      db '  4K   $'
n_32k     db '  32K  $'
n_63k     db '  63.5K$'

ph_name   dw n_512, n_1k, n_4k, n_32k, n_63k
ph_sect   db 1, 2, 8, 64, 127
ph_ops    db 64, 32, 16, 8, 8

; ---------------------------------------------------------------------------
bufseg    dw 0
heads     dw 16
spt       dw 63
cyls      dw 0
lba_lo    dw 0
lba_hi    dw 0
sect      db 1
ops       dw 0
opleft    dw 0
io_op     db 2
last_ah   db 0
phase     db 0
pass      dw 0
passes    dw 1
passes2   dw 0
rdonly    db 0
stop      db 0
f_write   dw 0
f_read    dw 0
f_ver     dw 0
t_fail    dw 0
t_ops     dw 0
have_first db 0
livefail  dw 0
first_dd  db 0
first_de  db 0
first_df  db 0
have_vf   db 0
v_kind    db 0
v_off     dw 0
v_exp_lo  dw 0
v_exp_hi  dw 0
v_got_lo  dw 0
v_got_hi  dw 0
first_lo  dw 0
first_hi  dw 0
first_ah  db 0
t_cyl     dw 0
t_head    db 0
t_sec     db 0
prev      times 12 db 0
cur       times 12 db 0
