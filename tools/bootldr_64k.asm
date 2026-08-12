; bootldr_64k.asm  --  overlay bootloader, loads a FULL 64 KB BIOS to 0xF0000
;
; Same FDC/UART magic-cylinder protocol as the 8 KB loader, but pulls 128 sectors
; (64 KB) into the whole F-segment 0xF0000..0xFFFFF instead of 8 KB at 0xFE000.
; The F-segment is PSRAM-backed now, so this populates the entire 64 KB ROM area
; with real, distinct content (no mirroring) before handing off.
;
; The serial loader is tried FIRST, so a connected host always wins and BIOS
; development stays a rebuild-and-reboot away. If no host answers within a couple
; of seconds, the BIOS is instead read from the on-board SPI flash, which makes
; the machine standalone. The flash copy lives in the top 64 KB of the chip
; (0x1F0000..0x1FFFFF); the fixed disk is limited to 31 cylinders so DOS can
; never reach it.
;
;
; BEEP CODES -- the machine says out loud what it found, before anything can be
; displayed. The 7-seg needs 2 s per byte to be legible and the screen does not
; exist yet; a speaker needs neither.
;   1 short   BIOS loaded over SERIAL, image looks real, handing off
;   2 short   BIOS loaded from FLASH -- no serial host answered
;   2 long    RESERVED for "BIOS checksum fail" (needs the image to carry an
;             expected value; see docs)
;   3 long    NO BIOS: the image region is blank. Repeats forever, with the
;             computed checksum on the 7-seg between rounds.
;
; POST markers on port 0x80 (7-seg), read as a ladder:
;   1 entered / stack set   2 about to talk to FDC   3 Specify accepted
;   4 Read(128 sec) issued  5 first data byte         6 all 64 KB received
;   7 about to disable overlay + jump to loaded BIOS
;   A no serial host, falling back to flash   B 64 KB read from flash
;   EF no BIOS -- halted, beeping
;
; Assemble:  nasm -f bin bootldr_64k.asm -o bootldr.bin
;            python mkmif.py bootldr.bin bootldr.mif 1024

        BITS 16
        CPU 8086                  ; refuse anything newer. Without this NASM
                                  ; silently emits the 386 near form of a
                                  ; conditional jump whose target is out of short
                                  ; range -- and on an 8088 opcode 0F is POP CS,
                                  ; which vaporises execution unconditionally.
                                  ; That exact trap cost days in the BIOS already.
        ORG 0xF800               ; 2 KB overlay window 0xFF800..0xFFFFF

FDC_DOR    equ 0x3F2
FDC_MSR    equ 0x3F4
FDC_DATA   equ 0x3F5
OVL_CTRL   equ 0xE2
SPI_DATA   equ 0x98               ; flash.vhd byte engine
SPI_STAT   equ 0x99               ; bit 7 = BUSY
SPI_CTRL   equ 0x9A               ; bit 0 = /CS
BIOS_OFF   equ 0x1F               ; flash address 0x1F0000 = top 64 KB
BIOS_CYL   equ 0xFF
POST       equ 0x80

%macro MARK 1
        mov     al, %1
        out     POST, al
%endmacro

; ---------------------------------------------------------------------------
start:
        cli
        cld
        xor     ax, ax
        mov     ss, ax
        mov     sp, 0x7C00          ; stack is in PSRAM -- see the probe below
        MARK    1

; ---------------------------------------------------------------------------
;  PROVE MAIN MEMORY BEFORE ANY `call` DEPENDS ON IT.
;
;  0x7C00 is PSRAM, not M9K -- memmap.vhd made conventional memory uniform, and
;  the comment above said "M9K low RAM" for a long time after that stopped being
;  true. So the FIRST instruction that touches main memory is the `call fdc_wr`
;  below, pushing a return address, and if the PSRAM is not up that call hangs
;  with nothing driving READY. The machine stops with the 7-seg showing 02 and
;  no way to tell whether the FDC or the memory was at fault -- and a timeout in
;  the FDC routines cannot help, because the CPU never gets far enough to run
;  one.
;
;  This costs a dozen bytes and answers it directly, using NO stack:
;
;      stuck on 01  the write itself never completed -- nothing claimed the
;                   address, so main memory is not answering at all
;      E1           memory answers but returns the wrong data: the PSRAM is
;                   responding without being correctly in QPI mode
;      E2           main memory works, and whatever fails next is not this
; ---------------------------------------------------------------------------
        xor     ax, ax
        mov     ds, ax
        mov     word [0x7BFE], 0x55AA   ; hangs here if nothing drives READY
        mov     word [0x7BFC], 0xC33C   ; a second cell, so a stuck bus that
                                        ; reads back what it last saw is caught
        mov     bx, [0x7BFE]
        cmp     bx, 0x55AA
        jne     .mem_bad
        mov     bx, [0x7BFC]
        cmp     bx, 0xC33C
        je      .mem_ok
.mem_bad:
        mov     al, 0xE1
        out     0x80, al
        jmp     $
.mem_ok:
        mov     al, 0xE2
        out     0x80, al

        mov     dx, FDC_DOR
        mov     al, 0x04
        out     dx, al
        MARK    2

        mov     al, 0x03            ; Specify
        call    fdc_wr
        mov     al, 0xDF
        call    fdc_wr
        mov     al, 0x03            ; ND=1
        call    fdc_wr
        MARK    3

        mov     al, 0x46            ; Read Data
        call    fdc_wr
        mov     al, 0x00
        call    fdc_wr
        mov     al, BIOS_CYL        ; C = 0xFF
        call    fdc_wr
        mov     al, 0x00            ; H
        call    fdc_wr
        mov     al, 0x01            ; R = 1
        call    fdc_wr
        mov     al, 0x02            ; N = 2 (512-byte sectors)
        call    fdc_wr
        mov     al, 128             ; EOT = 128 sectors = 64 KB
        call    fdc_wr
        mov     al, 0x1B            ; GPL
        call    fdc_wr
        mov     al, 0xFF            ; DTL
        call    fdc_wr
        MARK    4

        mov     ax, 0xF000          ; load 64 KB at 0xF0000..0xFFFFF
        mov     es, ax
        xor     di, di

        call    fdc_rd_to           ; first byte, but do not wait forever
        jc      flash_load          ; nobody answered -> use the flash copy
        stosb
        MARK    5
        mov     cx, 0xFFFF          ; 65535 more  (+1 above = 65536 = 64 KB)
.rd:
        call    fdc_rd
        stosb
        loop    .rd
        MARK    6

.drain:
        mov     dx, FDC_MSR
        in      al, dx
        test    al, 0x10
        jz      .ser_done
        test    al, 0x80
        jz      .drain
        mov     dx, FDC_DATA
        in      al, dx
        jmp     .drain

.ser_done:
        ; DL carries the beep count into .switch, and it is set HERE rather than
        ; back at MARK 6 because .drain does `mov dx, FDC_MSR` -- which lands in
        ; DL. Set it earlier and the machine beeps 0xF4 = 244 times, about a
        ; minute of it, before booting perfectly normally.
        mov     dl, 1               ; serial boot -> one short beep

.switch:
        ; Both load paths join here, DL already set to the number of short
        ; beeps that says WHICH path got here. Checksum the CODE REGION of the
        ; image now sitting in PSRAM -- the exact bytes about to run.
        ;
        ; The range is 0xC000..0xEFFF: code only, none of the BIOS's own runtime
        ; scratch, so the value is stable across boots -- and it is BELOW the
        ; 2 KB overlay window, which matters, because reads inside that window
        ; return the boot ROM and not what was just written there.
        ;
        ; On success the checksum is NOT displayed. It used to be, for 5 s of
        ; every boot, and the beep answers the question the display was there to
        ; answer. It is still shown when there is nothing to hand off to.
        call    sum_image           ; -> BP
        cmp     bp, 0xD000          ; 0x3000 bytes of 0xFF: a blank chip
        je      no_image
        mov     bx, 1               ; short
        call    beep_n
        MARK    7
        mov     ax, 0x0060
        mov     es, ax
        xor     di, di
        push    cs
        pop     ds
        mov     si, trampoline
        mov     cx, tramp_end - trampoline
        rep     movsb
        jmp     0x0060:0x0000

trampoline:
        mov     dx, OVL_CTRL
        mov     al, 1
        out     dx, al              ; disable overlay -> F-seg now reads loaded BIOS
        jmp     0xF000:0xFFF0       ; loaded BIOS reset vector
tramp_end:

; --- read one FDC byte, giving up after roughly two seconds (CF=1) ----------
; Only the FIRST byte is read this way. If a host is there it answers at once,
; and the rest of the transfer uses the unbounded fdc_rd; if none is, we must be
; able to give up, or a standalone board would simply hang here forever.
fdc_rd_to:
        push    dx
        push    cx
        push    bx
        mov     bx, 4
.o:     xor     cx, cx
.i:     mov     dx, FDC_MSR
        in      al, dx
        and     al, 0xC0
        cmp     al, 0xC0
        je      .got
        loop    .i
        dec     bx
        jnz     .o
        stc
        jmp     short .out
.got:   mov     dx, FDC_DATA
        in      al, dx
        clc
.out:   pop     bx
        pop     cx
        pop     dx
        ret

; --- exchange one SPI byte: AL out -> AL in --------------------------------
spi_x:
        out     SPI_DATA, al
        ; The status read must not overtake the write. flash.vhd latches the
        ; transmit on the FALLING edge of the write strobe and only then raises
        ; BUSY; an immediately following IN can sample the status BEFORE that,
        ; see BUSY=0, and hand back the PREVIOUS byte -- shifting the whole image
        ; by one and producing exactly the garbled BIOS this produced. The BIOS's
        ; own copy of this loop only works because it happens to have two
        ; instructions in between. Make the gap explicit rather than accidental.
        jmp     short $+2
        jmp     short $+2
.w:     in      al, SPI_STAT
        test    al, 0x80
        jnz     .w
        in      al, SPI_DATA
        ret

; --- load the 64 KB BIOS image from flash 0x1F0000 -> 0xF0000 --------------
; Read in 512-byte commands, NOT one 64 KB burst.
;
; This used to hold /CS low and stream the whole image in a single READ. The
; chip is specified to allow that, and it appeared to work -- the image loaded,
; the reset vector was intact, POST ran. But roughly a sixth of the bytes came
; back wrong, so the BIOS misbehaved in ways that looked like anything except a
; bad read: a signature register that would not match, a drive that reported no
; status, a screen of debris.
;
; tools/spidump.com settled it by doing the identical read both ways from DOS:
; streamed, 11256 of 65536 bytes differed; chunked into 512-byte commands, zero.
; Same port, same command, same byte-exchange, same comparison -- the only
; variable was the length of the burst.
;
; So: one command per 512 bytes, /CS released between them. The extra cost is
; four command bytes per sector, about 1.6 ms over the whole image.
flash_load:
        MARK    0xA
        mov     ax, 0xF000
        mov     es, ax
        xor     di, di
.fl_cmd:
        xor     al, al
        out     SPI_CTRL, al        ; /CS low
        mov     al, 0x03            ; READ
        call    spi_x
        mov     al, BIOS_OFF        ; addr[23:16]
        call    spi_x
        mov     ax, di
        mov     al, ah              ; addr[15:8] = DI >> 8
        call    spi_x
        xor     al, al              ; addr[7:0]: always a 512-byte boundary
        call    spi_x
        mov     cx, 512
.fl:    mov     al, 0xFF
        call    spi_x
        stosb
        loop    .fl
        mov     al, 1
        out     SPI_CTRL, al        ; /CS high
        test    di, di              ; DI wraps to 0 after exactly 64 KB
        jnz     .fl_cmd
        MARK    0xB
        ; This used to read [es:0xFFF0] and test it for a far jump. That address
        ; is INSIDE the overlay window, so with ROM_EN still set it returned the
        ; BOOT ROM's own reset vector -- which is 0xEA -- and the check passed
        ; unconditionally, whatever was in the flash. The blank test now uses
        ; the checksum in .switch, computed over a range the overlay does not
        ; shadow.
        mov     dl, 2               ; flash boot -> two short beeps
        jmp     start.switch        ; shared hand-off path

; --- nothing to hand off to ------------------------------------------------
; Three long beeps and the computed sum, over and over. A machine that cannot
; boot should say so until someone is listening.
no_image:
        MARK    0xEF
        mov     dl, 3
        mov     bx, 4               ; long
        call    beep_n
        mov     ax, bp
        xchg    al, ah              ; high byte first
        call    show_byte
        mov     ax, bp
        call    show_byte
        jmp     no_image

; --- BP = 16-bit sum of F000:C000..EFFF ------------------------------------
sum_image:
        mov     ax, 0xF000
        mov     es, ax              ; the flash path leaves ES here, the serial
        mov     si, 0xC000          ; path does not -- do not assume either
        mov     cx, 0x3000
        xor     bp, bp
        xor     ah, ah              ; AH stays 0: lodsb writes only AL
.ss:    es      lodsb
        add     bp, ax
        loop    .ss
        ret

; --- beep_n -- DL beeps at ~1 kHz. BX = on-time units, gap is always one -----
; One unit is 65536 iterations of a two-byte LOOP, about 0.13 s at the 8.333 MHz
; the loader runs at. Short = 1 unit, long = 4.
;
; The speaker is 8255 port B bit 1 ANDed with 8253 counter-2 OUT, so BOTH the
; gate (0x61 bit 0) and the data bit have to be set and the counter has to be
; making a square wave. No 8255 control word is needed: ppi8255.vhd is hard
; wired to the XT layout and takes a write to 0x61 unconditionally.
; Preserves BP, which is carrying the checksum.
beep_n:
        mov     al, 0xB6            ; ch2, lo/hi, mode 3 square wave, binary
        out     0x43, al
        mov     al, 0xA6            ; 1190 -> ~1002 Hz from the 1.1905 MHz tick
        out     0x42, al
        mov     al, 0x04
        out     0x42, al
.bn:
        push    bx
        in      al, 0x61
        or      al, 0x03            ; gate 2 on + speaker data on
        out     0x61, al
        call    bdelay
        in      al, 0x61
        and     al, 0xFC            ; both off again
        out     0x61, al
        mov     bx, 1
        call    bdelay
        pop     bx
        dec     dl
        jnz     .bn
        ret

; BX x 65536 iterations. Clobbers bx, cx.
bdelay:
        xor     cx, cx
.bd:    loop    .bd
        dec     bx
        jnz     bdelay
        ret
show_byte:
        out     POST, al
        ; The 7-seg shows a byte as TWO nibbles, 1 s each (sevenseg.vhd), so a
        ; value must be held at least 2 s to be readable at all -- and a new
        ; write RESTARTS that cycle from the high nibble.
        ;
        ; This was 2, which at ~17 clocks per LOOP is 0.45 s at 5 MHz and 0.27 s
        ; at the 8.333 MHz the loader actually runs at. So the checksum below
        ; has been computed correctly on every boot since it was written, and
        ; displayed as an unreadable flicker of two high nibbles before MARK 7
        ; overwrote it. The measurement was never wrong; it was never visible.
        ; That cost two full debugging rounds on a stalling boot.
        ;
        ; 20 gives ~2.7 s at 8.333 MHz, which clears the 2 s the display needs.
        ; It costs ~5 s of boot time to see, every time, whether the image that
        ; is about to run is the image that was sent. That is a good trade.
        ; (No spare bytes to do this properly off the PIT: 11 free of 1024.)
        mov     bx, 20
.sb:    xor     cx, cx
.sd:    loop    .sd
        dec     bx
        jnz     .sb
        ret

; --- write one FDC byte, giving up after roughly two seconds ---------------
; Same bound and the same shape as fdc_rd_to, and for a stronger reason: this
; runs BEFORE it. fdc_rd_to exists so a board with nobody answering can give up
; and use the flash copy -- but every command byte goes out through HERE first,
; so while this spun forever that giving-up path could never be reached at all.
;
; It is not hypothetical. A board configured from EPCS stopped dead on MARK 2,
; every reset, with no beep and no fallback: the FDC was holding a result byte,
; so MSR read 0xC0 while this loop accepts only 0x80, and it waited for a state
; that was never going to arrive. The same bitstream loaded over JTAG was fine,
; which sent the search after the bitstream rather than after the poll.
;
; There is nothing useful to hand back to the caller. Twelve call sites would
; each have to test, in an overlay with 2 KB to spend, and every one of them
; would do the same thing -- so it does that thing itself and does not return.
; See docs/gotchas.md, "Unbounded polls, and bounded ones that nest".
fdc_wr:
        push    dx
        push    cx
        push    bx
        mov     ah, al              ; the byte; AL is about to hold MSR
        mov     bx, 4
.o:     xor     cx, cx
.i:     mov     dx, FDC_MSR
        in      al, dx
        and     al, 0xC0
        cmp     al, 0x80
        je      .go
        loop    .i
        dec     bx
        jnz     .o
        pop     bx                  ; no FDC. Unwind our own frame, drop the
        pop     cx                  ; return address, and take the flash path;
        pop     dx                  ; flash_load never comes back here.
        add     sp, 2
        jmp     flash_load
.go:    mov     dx, FDC_DATA
        mov     al, ah
        out     dx, al
        pop     bx
        pop     cx
        pop     dx
        ret

; --- read one FDC byte, bounded the same way --------------------------------
; This one carries the other 65535 bytes of the image, inside a `loop .rd` that
; counts in CX -- so it saves CX, and the timeout counts in a copy. A host that
; stops answering half way through used to hang here on MARK 5 with 60 KB
; already in place and no way to say so; now it falls back and reloads the whole
; image from flash, which is why flash_load resets ES:DI rather than resuming.
fdc_rd:
        push    dx
        push    cx
        push    bx
        mov     bx, 4
.o:     xor     cx, cx
.i:     mov     dx, FDC_MSR
        in      al, dx
        and     al, 0xC0
        cmp     al, 0xC0
        je      .got
        loop    .i
        dec     bx
        jnz     .o
        pop     bx
        pop     cx
        pop     dx
        add     sp, 2
        jmp     flash_load
.got:   mov     dx, FDC_DATA
        in      al, dx
        pop     bx
        pop     cx
        pop     dx
        ret

        times (0xFFF0 - 0xF800) - ($ - $$) db 0x90
reset_vector:
        jmp     0xF000:0xF800
        times (0x10000 - 0xFFF0) - ($ - reset_vector) db 0xFF
